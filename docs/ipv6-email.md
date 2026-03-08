# IPv6 email ecosystem — findings (2025-2026)

## Summary

IPv6 is viable for email in a dual-stack configuration. IPv6-only is not.
The two hard blockers are PTR record delegation (ISP-dependent) and a handful
of major providers that do not yet accept inbound SMTP over IPv6.

---

## Inbound SMTP support at major providers

| Provider | IPv6 inbound | Notes |
|---|---|---|
| Gmail | Yes | Requires PTR + SPF + DKIM + DMARC; rejects at SMTP level since Nov 2025 |
| Outlook / Exchange Online | Yes | Rolling out since Oct 2024; requires PTR and SPF or DKIM |
| Yahoo | Yes | No documented blockers |
| Fastmail | **No** | Explicitly unsupported; no roadmap |
| ProtonMail | **No** | Requested for ~10 years; no roadmap |

Fastmail and ProtonMail are popular enough that mail sent exclusively over
IPv6 will fail to reach a meaningful fraction of users.

---

## PTR records — the key constraint

Gmail and Outlook now require a valid PTR (reverse DNS) record for the sending
IP. For IPv6 this means:

- The PTR must exist (`2001:db8::1` → `mail.example.com`)
- Forward-Confirmed reverse DNS (FCrDNS) must hold: the AAAA record for
  `mail.example.com` must resolve back to the same IPv6 address
- PTR records for an IPv6 block can only be set by whoever owns the block —
  the ISP or hosting provider

**OVH fiber:** OVH does allow customers to set PTR records for delegated IPv6
prefixes via the OVH manager (same place as the IPv4 reverse DNS). This needs
to be verified for the specific subscription, but it is a supported feature.

If OVH does not provide PTR delegation for this line, IPv6 mail is a
non-starter regardless of other configuration.

---

## SPF, DKIM, DMARC

**SPF:** The `ip6:` mechanism is universally supported. No lookup cost. Include
both `ip4:` and `ip6:` if sending over both protocols:
```
v=spf1 ip4:109.190.53.206 ip6:2001:41d0:fc28:400:edd:24ff:fe75:3dca -all
```

**DKIM:** Transport-agnostic — no IPv6-specific issues. Signing and validation
work identically over IPv4 and IPv6.

**DMARC:** No technical IPv6 issues. Enforcement is strict for IPv6 senders:
since Nov 2025 Gmail rejects (not quarantines) DMARC failures from IPv6
senders at the SMTP level. SPF, DKIM, and DMARC must all pass.

---

## Spam filtering and reputation

IPv6 reputation databases (Spamhaus ZEN, etc.) exist but are far less mature
than their IPv4 equivalents. The IPv6 address space is too large for
traditional IP-based blocklisting to be effective.

In practice, major providers have shifted to **domain-level reputation**:
spam complaint rate, engagement, authentication. A new IPv6 sender with clean
SPF/DKIM/DMARC and no complaint history will generally be treated similarly
to a new IPv4 sender — which means a warm-up period of weeks is still
advisable.

---

## ISP port 25 blocking

No specific data on IPv6 port 25 blocking policies. The safe assumption is
that the ISP treats IPv4 and IPv6 equally. If outbound port 25 works on IPv4
from this connection (it currently does for motoko), it likely works on IPv6
too. Verify empirically after deployment.

---

## Cons of IPv6 for email

1. **PTR delegation is ISP-dependent.** Without it, Gmail and Outlook reject.
   Must be verified with OVH before proceeding.

2. **Fastmail and ProtonMail don't accept IPv6 inbound.** A dual-stack
   fallback (motoko IPv4 relay) is needed for full deliverability.

3. **Warm-up period.** A new sender IP (regardless of version) needs time to
   build domain reputation. Expect soft rejections or spam placement for the
   first few weeks.

4. **Stricter authentication enforcement.** All three of SPF, DKIM, DMARC
   must pass simultaneously. On IPv4 a DMARC softfail often still delivers to
   spam; on IPv6 Gmail rejects outright.

5. **Stable address required.** Privacy-extension addresses (temporary,
   rotating) must not be used for mail. The EUI-64 stable address must be
   pinned in the NixOS config.

---

## Recommended approach for killy mail

1. **Verify OVH PTR delegation** for `2001:41d0:fc28:400:edd:24ff:fe75:3dca`.
   This is the go/no-go gate.

2. **Pin killy's IPv6 address** in NixOS (`networking.interfaces.wlo1.ipv6.addresses`)
   using the EUI-64 stable address, not a privacy-extension address.

3. **Configure Postfix for dual-stack** (`inet_protocols = all`). Killy sends
   outbound over IPv6 directly; receives inbound on its IPv6 address.

4. **Keep motoko as IPv4 relay fallback.** Add `transport_maps` on motoko to
   relay `douzeb.is` inbound over IPv4 for senders that don't support IPv6
   (Fastmail, ProtonMail, etc.).

5. **Set DNS at OVH:**
   - `mail.douzeb.is AAAA <killy-ipv6>`
   - `mail.douzeb.is A 109.190.53.206` (for IPv4 relay path)
   - `douzeb.is MX 10 mail.douzeb.is`
   - `douzeb.is TXT "v=spf1 ip4:109.190.53.206 ip6:<killy-ipv6> -all"`
   - PTR for `<killy-ipv6>` → `mail.douzeb.is`
   - `mail._domainkey.douzeb.is TXT` — killy's own DKIM public key
   - `_dmarc.douzeb.is TXT "v=DMARC1; p=quarantine;"` (start relaxed, tighten later)

6. **Warm up** by sending low volumes first and monitoring Gmail Postmaster
   Tools for domain reputation signals.
