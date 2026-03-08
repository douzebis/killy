# 0006 — Killy mail server (ruget.net)

- **Status:** pending

---

## Background

Motoko currently handles mail for `atlant.is`. Killy will be a second,
independent mail server handling `ruget.net`. The two domains are separate;
killy does not relay through motoko and motoko does not relay through killy.

The mail server runs as a **KVM virtual machine** on killy's host OS, not on
bare metal. The host OS (spec 0005) forwards public mail ports to the VM;
the VM's NixOS configuration is otherwise identical to what a bare-metal mail
server would look like.

Killy's network position (host):
- LAN IPv4: static DHCP lease `192.168.42.50`, NATed behind `109.190.53.206`.
- IPv6: `2001:41d0:fc28:400:edd:24ff:fe75:3dca` (EUI-64 stable, globally
  routable, no NAT). Verified reachable from the internet (0% packet loss,
  5/5 probes).

Mail transport uses IPv6 exclusively for inbound and outbound SMTP, avoiding
IPv4 NAT port conflicts with motoko. See `docs/ipv6-email.md` and
`docs/motoko-network.md` for background.

**Prerequisites**:
- Spec 0005 (host OS install) complete.
- Spec 0007 (VM architecture and WireGuard) complete.
- VT-x and VT-d enabled in BIOS.

---

## Goals

1. Killy accepts inbound SMTP for `ruget.net` on IPv6 (port 25).
2. Killy accepts mail submission from authenticated users (port 587).
3. Killy serves IMAP to authenticated users (port 993, TLS).
4. Outbound mail is signed with DKIM and passes SPF and DMARC checks.
5. TLS certificates for `mail.ruget.net` are obtained and auto-renewed via
   ACME (Let's Encrypt, OVH DNS-01 challenge).
6. All required DNS records for `ruget.net` are declared in
   `dns/desired-state.yaml` and applied via `bin/ovh-dns-sync` (spec 0004).
7. The IPv6 PTR record for killy resolves to `mail.ruget.net` (FCrDNS).
8. Mail is backed up to OVH Object Storage via Restic (same approach as
   motoko's `atlant.is` backup).

---

## Non-goals

- Webmail (Roundcube, Sieve management UI) — can be added later.
- Spam filtering (rspamd, SpamAssassin) — can be added later.
- Mailing lists.
- Handling mail for `atlant.is` — that remains on motoko.
- IPv4 inbound SMTP — killy has no dedicated IPv4; inbound IPv4 goes to
  motoko. Killy is IPv6-only for inbound. Outbound may use IPv4 or IPv6
  depending on the remote MX.

---

## Specification

### 6.1 DNS records (`dns/desired-state.yaml`)

Replace all `douzeb.is` references with `ruget.net`. The existing `ruget.net`
records (pointing to `109.190.53.206` for motoko's services like `keycloak`,
`gitea`, `woodpecker`) are left unchanged — only mail-related records are
managed by this spec.

Records to add/update in `ruget.net`:

| Subdomain | Type | Value | Notes |
|---|---|---|---|
| `mail` | A | `109.190.53.206` | For client config docs; actual mail flows over IPv6 |
| `mail` | AAAA | `2001:41d0:fc28:400:edd:24ff:fe75:3dca` | Primary mail address |
| `@` | MX | `10 mail.ruget.net.` | Already set; verify/leave |
| `@` | TXT | `v=spf1 ip6:2001:41d0:fc28:400:edd:24ff:fe75:3dca ~all` | Replace existing SPF |
| `mail._domainkey` | TXT | `v=DKIM1; k=rsa; p=<killy-key>` | New key (see §6.2) |
| `_dmarc` | TXT | `v=DMARC1; p=quarantine; rua=mailto:postmaster@ruget.net;` | Start at quarantine |

PTR record (via `/ip` API):

| IP | PTR |
|---|---|
| `2001:41d0:fc28:400:edd:24ff:fe75:3dca/128` | `mail.ruget.net.` |

The existing `ruget.net` DKIM record uses motoko's key (selector `mail`). It
is replaced by killy's key using the same selector. Since `ruget.net` mail was
not previously active on killy, there is no risk of breaking existing signed
mail in transit.

### 6.2 DKIM key generation

Generate a new RSA-2048 DKIM key pair for killy:

```bash
openssl genrsa -out /tmp/ruget-dkim.private 2048
openssl rsa -in /tmp/ruget-dkim.private -pubout -out /tmp/ruget-dkim.pub
```

Store the private key encrypted in `install-config.yaml`:

```yaml
dkim:
  ruget.private: <private key>   # added to encrypted_regex
```

Extract the public key value (strip PEM headers, join lines) for the DNS TXT
record and insert into `dns/desired-state.yaml`.

### 6.3 NixOS modules: `killy/system/`

Three new modules, modelled on motoko's equivalents:

#### `killy/system/postfix.nix`

```nix
services.postfix = {
  enable = true;
  domain = "ruget.net";
  hostname = "mail.ruget.net";
  origin = "ruget.net";

  # Accept mail for ruget.net
  destination = [ "ruget.net" "mail.ruget.net" "localhost" ];

  # IPv6-first, dual-stack outbound
  config = {
    inet_protocols = "all";
    smtp_address_preference = "ipv6";

    # TLS inbound (port 25)
    smtpd_tls_cert_file = "/var/lib/acme/mail.ruget.net/cert.pem";
    smtpd_tls_key_file  = "/var/lib/acme/mail.ruget.net/key.pem";
    smtpd_tls_security_level = "may";

    # TLS outbound
    smtp_tls_security_level = "may";

    # DKIM milter
    smtpd_milters = "unix:/run/opendkim/opendkim.sock";
    non_smtpd_milters = "unix:/run/opendkim/opendkim.sock";

    # SASL (Dovecot)
    smtpd_sasl_type = "dovecot";
    smtpd_sasl_path = "private/auth";
    smtpd_sasl_auth_enable = "yes";
  };

  # Submission port (587)
  submissionOptions = {
    smtpd_tls_security_level = "encrypt";
    smtpd_sasl_auth_enable = "yes";
  };
};

networking.firewall.allowedTCPPorts = [ 25 587 ];
```

#### `killy/system/dovecot.nix`

```nix
services.dovecot2 = {
  enable = true;
  enableImap = true;
  enablePop3 = false;

  sslServerCert = "/var/lib/acme/mail.ruget.net/cert.pem";
  sslServerKey  = "/var/lib/acme/mail.ruget.net/key.pem";

  # SASL socket for Postfix
  extraConfig = ''
    service auth {
      unix_listener /var/lib/postfix/queue/private/auth {
        mode = 0660
        user = postfix
        group = postfix
      }
    }
  '';
};

networking.firewall.allowedTCPPorts = [ 993 ];
```

#### `killy/system/dkim.nix`

```nix
services.opendkim = {
  enable = true;
  selector = "mail";
  domain = "ruget.net";
  keyFile = config.sops.secrets."dkim/ruget.private".path;
  socket = "local:/run/opendkim/opendkim.sock";
  user = "postfix";
};

sops.secrets."dkim/ruget.private" = {
  owner = "postfix";
  mode = "0400";
};
```

#### `killy/system/acme.nix`

```nix
security.acme = {
  acceptTerms = true;
  defaults.email = "postmaster@ruget.net";
};

security.acme.certs."mail.ruget.net" = {
  dnsProvider = "ovh";
  credentialsFile = config.sops.secrets."ovh/acme_creds".path;
  dnsPropagationCheck = true;
  group = "postfix";
};

sops.secrets."ovh/acme_creds" = {};
```

#### `killy/system/backup.nix`

Daily Restic backup of `/var/spool/mail` to the `atlantis` S3 bucket:

```nix
services.cron = {
  enable = true;
  cronFiles = [ (pkgs.writeText "cron-mail" ''
    0 3 * * * root ${backupScript}
  '') ];
};
```

Using the existing `ovh.s3_creds` and `restic.mail_creds` from
`install-config.yaml`.

### 6.4 Firewall summary

Ports opened on killy for mail:

| Port | Protocol | Service |
|---|---|---|
| 25 | TCP | SMTP inbound (IPv6) |
| 587 | TCP | Submission (authenticated clients) |
| 993 | TCP | IMAPS |

### 6.5 Client configuration

Mail clients connect to:

- **IMAP**: `mail.ruget.net` port 993, TLS, username = Linux username on killy
- **SMTP**: `mail.ruget.net` port 587, STARTTLS, same credentials

Note: `mail.ruget.net` resolves to both an A record (`109.190.53.206`) and an
AAAA record (killy's IPv6). Clients on the LAN or with IPv6 reach killy
directly. Clients on IPv4-only networks reach killy's IPv6 via the AAAA
record if their ISP supports IPv6, or need a workaround (e.g. motoko port
forwarding of 993/587 to killy's LAN IP) for pure-IPv4 clients. This is
acceptable for a personal mail server with known clients.

---

## Implementation order

1. Generate DKIM key pair, store private key in `install-config.yaml`,
   insert public key into `dns/desired-state.yaml`.
2. Run `ovh-dns-sync` to apply all `ruget.net` DNS changes and set the IPv6
   PTR record.
3. Verify DNS propagation: `dig MX ruget.net`, `dig AAAA mail.ruget.net`,
   `dig -x 2001:41d0:fc28:400:edd:24ff:fe75:3dca`.
4. Complete spec 0005 (disk install).
5. Deploy `postfix.nix`, `dovecot.nix`, `dkim.nix`, `acme.nix` to the
   installed system via `nixos-rebuild switch`.
6. Wait for ACME cert issuance (DNS-01, up to a few minutes).
7. Send a test message from an external account; verify delivery, DKIM
   signature, and SPF/DMARC pass in the received headers.
8. Set up Restic backup (`backup.nix`); verify first snapshot.

---

## Open questions

1. **IPv4-only clients**: clients that cannot reach `mail.ruget.net` over
   IPv6 need a workaround. Options: (a) add port forwarding on the router for
   587/993 to killy's LAN IPv4, sharing with motoko's 25 (different ports so
   no conflict); (b) use motoko as a proxy. Decision deferred.

2. **Mail users**: killy will have Linux user accounts corresponding to mail
   recipients. How users and passwords are managed (PAM, separate auth DB) is
   deferred to implementation.

3. **SPF dual-stack**: the SPF record above uses only `ip6:`. If killy ever
   sends outbound via IPv4 (e.g. via motoko relay), the SPF record must be
   extended with `ip4:109.190.53.206`. Start with IPv6-only and extend if
   needed.
