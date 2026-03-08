# Motoko — network configuration and killy routing analysis

## Current topology

```
Internet
    │
    │ fiber  (IPv4: 109.190.53.206 — public, NATed)
    │        (IPv6: 2001:41d0:fc28:400::/64 — prefix delegated to LAN, no NAT)
    ▼
fiber router  192.168.42.1 / fe80::127c:61ff:fe42:cc50
    │
    │ LAN 192.168.42.0/24  +  2001:41d0:fc28:400::/64
    ├── motoko   192.168.42.43   eno1   (NixOS server)
    ├── killy    192.168.42.xx   wlo1   (target machine, DHCP)
    └── cibo     192.168.42.2
```

**IPv4:** Motoko sits behind the router's NAT. The router forwards specific
ports (80, 443, 25, 587, 993 …) to motoko's LAN IP. Only one LAN host can
receive each forwarded port.

**IPv6:** The router advertises `2001:41d0:fc28:400::/64` via RA. Every host
on the LAN — motoko, killy, and others — receives a globally-routable `/128`
address directly, with **no NAT and no port forwarding**. Each host is
independently reachable from the internet on all ports.

---

## How HTTPS traffic reaches motoko today

Inbound HTTPS (TCP 443) hits the router, which forwards it to
`192.168.42.42:443` (motoko). Motoko's nginx handles it in two layers:

### Layer 1 — TCP stream proxy (SNI routing)

`nginx.streamConfig` listens on TCP 443 with `ssl_preread on`. It reads the
TLS SNI hostname *without decrypting the connection* and forwards the raw TCP
stream to the appropriate backend:

```
ssl_preread_server_name        → upstream
─────────────────────────────────────────────────────
jellyfin.atlant.is             → 192.168.42.42:443  (motoko itself, different vhost)
keycloak.atlant.is             → 192.168.42.42:443  (motoko itself)
(anything else)                → 127.0.0.1:444      (motoko nginx HTTP layer)
```

The stream proxy passes the raw TLS bytes — it does **not** terminate TLS.
The upstream at 192.168.42.42:443 or 127.0.0.1:444 must be a TLS endpoint.

### Layer 2 — nginx HTTP virtual hosts (TLS terminated)

The default stream target `127.0.0.1:444` reaches nginx's HTTP engine, which
terminates TLS and dispatches by `Host:` header:

```
Host:                  → handler
───────────────────────────────────────────────────
www.atlant.is          → /var/nginx/www/ (static)
atlant.is              → /var/nginx/root/ (static) + HTTP→HTTPS redirect
immich.atlant.is       → http://127.0.0.1:2283 (reverse proxy to Immich)
```

TLS certificates are issued via ACME (OVH DNS challenge) and stored under
`/var/lib/acme/<cert-name>/`.

---

## Mail infrastructure on motoko

Mail for `atlant.is` is handled entirely on motoko:

| Component | Service       | Port(s)         | Note |
|-----------|---------------|-----------------|------|
| SMTP      | Postfix       | 25, 465, 587    | TLS via `/var/lib/acme/mail/` |
| IMAP      | Dovecot       | 143, 993        | Auth via /etc/shadow |
| DKIM      | OpenDKIM      | unix socket     | Selector: mail, domain: atlant.is |
| Cert      | ACME          | DNS/OVH         | mail.atlant.is |

Virtual mailboxes: `admin@atlant.is → admin`, `fred@atlant.is → fred`.

DNS records required (set at OVH):
- `mail.atlant.is A 109.190.53.206`
- `atlant.is MX 10 mail.atlant.is`
- `atlant.is TXT "v=spf1 a mx a:mail.atlant.is -all"`
- `mail._domainkey TXT "v=DKIM1;…"` (key in `killy/install-config.yaml`)
- Reverse DNS: 109.190.53.206 → mail.atlant.is

---

## Routing a new domain to killy

### Mechanism: stream proxy with a new SNI entry

To route `*.douzeb.is` (or any specific hostname like `mail.douzeb.is`) to
killy, add an entry to the stream map in `nginx.nix`:

```nix
streamConfig = ''
  map $ssl_preread_server_name $upstreamaddr {
    hostnames;
    default 127.0.0.1:444;
    jellyfin.atlant.is  ${bootstrap.hostLocalIp}:443;
    keycloak.atlant.is  ${bootstrap.hostLocalIp}:443;

    # Route all *.douzeb.is to killy
    .douzeb.is          192.168.42.xx:443;   # killy's LAN IP
  }
  ...
'';
```

The leading `.` in `.douzeb.is` matches any subdomain (nginx stream `hostnames`
map directive). The raw TLS stream is forwarded to killy port 443 — killy
must terminate its own TLS there.

**Requirements on killy's side:**
1. nginx (or another TLS server) listening on 443.
2. A valid TLS certificate for the relevant hostnames. Since killy is on the
   LAN it cannot use HTTP challenges; it must use DNS challenges (OVH) —
   the same mechanism motoko already uses.
3. Port 443 open in killy's firewall.
4. Killy's LAN IP must be stable (static DHCP lease or configured statically).

**DNS for `douzeb.is`:**
- `douzeb.is A 109.190.53.206` (same public IP as atlant.is)
- `*.douzeb.is A 109.190.53.206` (or per-subdomain records)
- The router forwards port 443 to motoko, which routes by SNI to killy.

---

## Could this work for a mail server on killy?

### HTTPS / web traffic — yes, via SNI proxy on motoko

Adding `.douzeb.is` to motoko's stream map is a one-liner. Killy terminates
its own TLS (nginx + ACME with OVH DNS challenge). No IPv6 dependency.

### SMTP/IMAP on IPv4 — the port-forwarding conflict

Mail ports (25, 587, 993) are not handled by the nginx stream proxy — there
is no SNI equivalent for SMTP. The router can forward each port to only one
LAN host. Currently they all go to motoko.

If killy also runs a mail server for `douzeb.is`, the options on IPv4 are:

**Option A — motoko relays inbound SMTP to killy**
Motoko keeps port 25. It relays mail for `douzeb.is` to killy's LAN IP via
Postfix `transport_maps`:
```
douzeb.is   smtp:[192.168.42.xx]:25
```
Inbound works. Outbound from killy goes directly to remote MTAs (assuming the
router allows outbound port 25 — check if motoko's current outbound works).
Problem: both domains share the single public IPv4 PTR record. Only one PTR
is possible per IP; you'd pick either `mail.atlant.is` or `mail.douzeb.is`.
PTR is not a hard requirement for delivery but affects spam scoring.

**Option B — consolidate both domains on one machine**
Run motoko (or killy) as the mail server for both `atlant.is` and `douzeb.is`.
No port conflicts, clean PTR. Simpler operationally but couples the two
domains to one machine.

**Option C — second public IPv4**
OVH fiber can provide additional IPs. Each server gets its own IP and PTR.
Cleanest IPv4 solution but requires ISP provisioning.

### SMTP/IMAP on IPv6 — the clean solution

Killy already has a globally-routable IPv6 address: `2001:41d0:fc28:400:edd:24ff:fe75:3dca/64`
(the EUI-64 stable address, derived from the MAC). This address is reachable
from the internet directly — no NAT, no port forwarding, no conflict with
motoko whatsoever.

With IPv6:
- Motoko handles `atlant.is` mail on its own IPv6 address → its own PTR
- Killy handles `douzeb.is` mail on its own IPv6 address → its own PTR
- No relay needed, no port conflicts, full independence

**Requirements:**
1. Killy's IPv6 address must be stable. The EUI-64 address
   (`2001:41d0:fc28:400:edd:24ff:fe75:3dca`) is derived from the MAC and
   stable across reboots, unlike the privacy-extension temporary addresses.
   Pin it in the NixOS config with `networking.interfaces.wlo1.ipv6.addresses`.
2. DNS for `douzeb.is`:
   - `mail.douzeb.is AAAA 2001:41d0:fc28:400:edd:24ff:fe75:3dca`
   - `douzeb.is MX 10 mail.douzeb.is`
   - `douzeb.is TXT "v=spf1 ip6:2001:41d0:fc28:400:edd:24ff:fe75:3dca -all"`
   - PTR for `2001:41d0:fc28:400:edd:24ff:fe75:3dca` → `mail.douzeb.is`
     (set at OVH, same place as the IPv4 reverse DNS)
3. Postfix on killy configured for `inet_protocols = ipv6` (or `all`).
4. Firewall on killy opens port 25, 587, 993 for IPv6.

**Caveat:** Some sending MTAs and spam filters still prefer IPv4. Configuring
both IPv4 (via motoko relay, Option A) and IPv6 (direct) is possible — Postfix
will prefer the direct IPv6 path when both are available.

### DKIM and SPF for `douzeb.is`

Independent of routing, killy needs its own DKIM key pair for `douzeb.is`
(separate from motoko's `atlant.is` key). SPF should reference killy's IPv6
address (and optionally motoko's IPv4 if using the relay fallback).

---

## Summary

| Traffic type | IPv4 path | IPv6 path |
|---|---|---|
| HTTPS `*.douzeb.is` | motoko SNI stream proxy → killy:443 | same (IPv4 only today) |
| SMTP inbound port 25 | motoko relay via `transport_maps` | direct to killy — no conflict |
| SMTP outbound port 25 | direct from killy (ISP permitting) | direct from killy |
| IMAP port 993 | conflicts with motoko | direct to killy — no conflict |
| PTR record | shared with motoko (one per IPv4) | independent per IPv6 address |

**Recommended path for a killy mail server:**

1. **HTTPS first:** add `.douzeb.is` to motoko's nginx stream map; deploy
   nginx + ACME on killy (OVH DNS challenge).
2. **Mail via IPv6:** pin killy's EUI-64 IPv6 address in its NixOS config,
   set DNS (`AAAA`, `MX`, `SPF`, `PTR`) at OVH, configure Postfix for IPv6.
   This gives full independence with no changes needed on motoko for mail.
3. **IPv4 relay as fallback (optional):** add a `transport_maps` entry on
   motoko to relay `douzeb.is` inbound over IPv4 for senders that don't
   support IPv6.
