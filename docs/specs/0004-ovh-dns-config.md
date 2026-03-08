# 0004 — Automated OVH DNS and reverse-DNS configuration

- **Status:** pending

---

## Background

Setting up a mail server on killy (for `douzeb.is`) and maintaining the
existing mail server on motoko (for `atlant.is`) requires a set of DNS records
and reverse-DNS (PTR) entries to be kept in sync with the NixOS configuration.
Today all of this is done manually via the OVH Manager web interface. There is
no source of truth in the repository, no validation, and no way to detect drift.

OVH provides a full REST API for DNS zone management and PTR configuration.
The Python `ovh` SDK wraps this API. The credentials needed (application key,
application secret, consumer key) are the same four values already stored
encrypted in `install-config.yaml` under `ovh.acme_creds` for ACME certificate
issuance — no new secrets need to be provisioned.

This spec defines `bin/ovh-dns-sync`, a script that reads a declarative DNS
configuration and applies it idempotently via the OVH API.

---

## Goals

1. Express the desired DNS state for `atlant.is` and `douzeb.is` as data in the
   repository (source of truth).
2. Apply that state to OVH idempotently: create missing records, update
   records whose value has changed, leave unmanaged records untouched.
3. Set PTR (reverse-DNS) records for both the IPv4 public address and killy's
   IPv6 address.
4. Validate FCrDNS (forward-confirmed reverse DNS): after setting a PTR, verify
   that the forward record resolves back to the same address.
5. Be runnable manually by the operator and as part of the killy install
   workflow.
6. Produce clear human-readable output: one line per record, CREATED / UPDATED
   / OK / ERROR status.

---

## Non-goals

- Automatic scheduling / cron — the operator runs the script explicitly.
- Managing DNS records for domains other than `atlant.is` and `douzeb.is`.
- Deleting records not listed in the config (avoid accidental destruction).
- Managing NS records or zone transfers.
- Creating a new OVH API token — the existing `ovh.acme_creds` secret is reused.

---

## Specification

### 5.1 Configuration file: `dns/desired-state.yaml`

A new plaintext YAML file in the repository declares the desired DNS state.
It is not a SOPS secret — it contains no sensitive data.

```yaml
# dns/desired-state.yaml
#
# Declarative DNS configuration for OVH-managed zones.
# Applied by: bin/ovh-dns-sync
#
# All values are the actual record values, not templates.
# TTL is in seconds; 3600 is OVH's default.

zones:
  atlant.is:
    records:
      - { subdomain: "mail",  type: A,   ttl: 3600, value: "109.190.53.206" }
      - { subdomain: "",      type: MX,  ttl: 3600, value: "10 mail.atlant.is." }
      - { subdomain: "",      type: TXT, ttl: 3600, value: "v=spf1 a mx a:mail.atlant.is -all" }
      - { subdomain: "mail._domainkey", type: TXT, ttl: 3600,
          value: "v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCx3uC6VoZpICNikgP5Cj9BB2ww/mwX1ZH3t3+qUris1lkzL8Iwdt0c6xV2eSry7t0t2GRM2A9R1lqWNpCXncgNZMQ5VrP5uOZ9tiIMlLpGSb7EgavRGBzB8Vc0aqCoX/HE89qV9qYZNVZw45rNNvbMzi/5YpKDwnQZ1p0uv4hxnQIDAQAB" }
      - { subdomain: "_dmarc", type: TXT, ttl: 3600, value: "v=DMARC1; p=none;" }

  douzeb.is:
    records:
      - { subdomain: "",      type: A,    ttl: 3600, value: "109.190.53.206" }
      - { subdomain: "mail",  type: A,    ttl: 3600, value: "109.190.53.206" }
      - { subdomain: "mail",  type: AAAA, ttl: 3600, value: "2001:41d0:fc28:400:edd:24ff:fe75:3dca" }
      - { subdomain: "",      type: MX,   ttl: 3600, value: "10 mail.douzeb.is." }
      - { subdomain: "",      type: TXT,  ttl: 3600,
          value: "v=spf1 ip4:109.190.53.206 ip6:2001:41d0:fc28:400:edd:24ff:fe75:3dca -all" }
      - { subdomain: "mail._domainkey", type: TXT, ttl: 3600,
          value: "v=DKIM1; k=rsa; p=<killy-dkim-public-key>" }  # fill in after key generation
      - { subdomain: "_dmarc", type: TXT, ttl: 3600, value: "v=DMARC1; p=quarantine;" }

ptr:
  # PTR records are set via the /ip/{ip}/reverse endpoint, not via zone records.
  # The key is the IP address (IPv6 uses /128 notation).
  # FCrDNS validation is performed after each PTR is set.
  "109.190.53.206":      mail.atlant.is.
  "2001:41d0:fc28:400:edd:24ff:fe75:3dca/128":  mail.douzeb.is.
```

**Record identity:** A record is identified by `(zone, subdomain, type)`. If a
record with that identity exists, its `value` and `ttl` are compared; if
different, the record is updated. If it does not exist, it is created. Multiple
records with the same identity (e.g., multiple TXT records at the same name) are
not supported by this tool — the operator must manage them manually.

### 5.2 Credentials

The script reads OVH API credentials from a file in the same format as the
existing `acme_creds` secret — a shell-style environment file:

```
OVH_ENDPOINT=ovh-eu
OVH_APPLICATION_KEY=<application-key>
OVH_APPLICATION_SECRET=<application-secret>
OVH_CONSUMER_KEY=<consumer-key>
```

The credentials file path is passed via `--creds` or read from the environment
variable `OVH_CREDS_FILE`. When run during install, the operator decrypts
`ovh.acme_creds` from `install-config.yaml` to a temp file and passes it.

The existing token (created for ACME) may not have the permissions needed for
DNS zone record management and PTR writes. The required permissions are:

| Endpoint | Method |
|---|---|
| `GET /domain/zone/*/record` | Read zone records |
| `POST /domain/zone/*/record` | Create records |
| `PUT /domain/zone/*/record/*` | Update records |
| `DELETE /domain/zone/*/record/*` | Delete records (not used, but required by PUT flow) |
| `POST /domain/zone/*/refresh` | Flush zone cache after changes |
| `GET /ip/*/reverse` | Read PTR records |
| `POST /ip/*/reverse` | Set PTR records |
| `DELETE /ip/*/reverse` | Replace PTR (delete+create) |

The existing `acme_creds` token has been verified to have only two rules:
`POST /domain/zone/*` and `DELETE /domain/zone/*` — the minimum needed by
certbot for DNS-01 challenges. It cannot read records (`GET`) or manage PTR
entries (`/ip/*`).

A new token must be created at `https://eu.api.ovh.com/createToken/` and stored
as `ovh.dns_creds` in `install-config.yaml` (same env-file format, added to
`encrypted_regex`). The `acme_creds` token is left unchanged.

### 5.3 Script: `bin/ovh-dns-sync`

**Language:** Python 3 with explicit dependencies declared at the top:

```python
# Dependencies:
#   ovh        — OVH Python SDK (pip install ovh, or pkgs.python3Packages.ovh in nix-shell)
#   pyyaml     — YAML config parsing
#   dnspython  — FCrDNS validation (dns.resolver)
```

**Interface:**

```
ovh-dns-sync [--creds FILE] [--dry-run] [--zone ZONE] dns/desired-state.yaml
```

- `--creds FILE` — path to the env-format credentials file
  (default: `$OVH_CREDS_FILE`)
- `--dry-run` — show what would be done, make no API calls
- `--zone ZONE` — limit to a single zone (can be repeated); default: all zones

**Output format** (one line per action):

```
atlant.is  mail          A     OK      (109.190.53.206, no change)
atlant.is               MX    OK      (10 mail.atlant.is., no change)
atlant.is               TXT   CREATED
atlant.is  mail._domainkey TXT UPDATED (value changed)
atlant.is  _dmarc        TXT   CREATED
douzeb.is               A     CREATED
...
PTR  109.190.53.206         OK      (mail.atlant.is., FCrDNS OK)
PTR  2001:41d0:fc28:...     CREATED (mail.douzeb.is., FCrDNS OK)
```

**Algorithm for zone records:**

1. Fetch all existing records for the zone via `GET /domain/zone/{zone}/record`.
2. For each desired record `(subdomain, type, value, ttl)`:
   a. Find existing records with matching `(subdomain, type)`.
   b. If none found: `POST` to create. Status: CREATED.
   c. If found and value+ttl match: Status: OK.
   d. If found and value or ttl differ: `PUT` to update. Status: UPDATED.
3. After any create or update, call `POST /domain/zone/{zone}/refresh` once.

**Algorithm for PTR records:**

1. `GET /ip/{ip}/reverse` — parse current PTR value.
2. If matches desired: Status: OK.
3. If differs: `DELETE /ip/{ip}/reverse/{ip}` then `POST /ip/{ip}/reverse`.
   Status: CREATED or UPDATED.
4. After setting, perform FCrDNS validation:
   - Resolve the PTR hostname to an IP (A or AAAA query).
   - Verify the resolved IP matches the original IP.
   - Append `(FCrDNS OK)` or `(FCrDNS FAIL — forward does not resolve back)`.

**Note on PTR endpoint for IPv6:** The OVH `/ip` API accepts the full `/128`
address in URL-encoded form: `POST /ip/2001%3A41d0%3Afc28%3A400%3Aedd%3A24ff%3Afe75%3A3dca%2F128/reverse`.

**Error handling:** Errors are printed inline with status ERROR and a short
message. The script continues with remaining records. Exit code is 0 if all
records are OK/CREATED/UPDATED with no ERROR; 1 if any ERROR occurred.

### 5.4 nix-shell dependency

Add `pkgs.python3Packages.ovh` and `pkgs.python3Packages.dnspython` to
`default.nix` so the script runs inside `nix-shell` without manual pip installs.

---

## External provider configuration summary

The following table lists **every piece of external provider configuration**
required for the mail setup, for reference:

| Provider | What | How set | Status |
|---|---|---|---
| OVH DNS | `mail.atlant.is A 109.190.53.206` | `ovh-dns-sync` | existing |
| OVH DNS | `atlant.is MX 10 mail.atlant.is` | `ovh-dns-sync` | existing |
| OVH DNS | `atlant.is TXT SPF` | `ovh-dns-sync` | existing |
| OVH DNS | `mail._domainkey.atlant.is TXT DKIM` | `ovh-dns-sync` | existing |
| OVH DNS | `_dmarc.atlant.is TXT` | `ovh-dns-sync` | pending |
| OVH PTR | `109.190.53.206 → mail.atlant.is` | `ovh-dns-sync` | existing |
| OVH DNS | `douzeb.is A 109.190.53.206` | `ovh-dns-sync` | pending |
| OVH DNS | `mail.douzeb.is A 109.190.53.206` | `ovh-dns-sync` | pending |
| OVH DNS | `mail.douzeb.is AAAA <killy-ipv6>` | `ovh-dns-sync` | pending |
| OVH DNS | `douzeb.is MX 10 mail.douzeb.is` | `ovh-dns-sync` | pending |
| OVH DNS | `douzeb.is TXT SPF (dual-stack)` | `ovh-dns-sync` | pending |
| OVH DNS | `mail._domainkey.douzeb.is TXT DKIM` | `ovh-dns-sync` | pending (key not generated) |
| OVH DNS | `_dmarc.douzeb.is TXT` | `ovh-dns-sync` | pending |
| OVH PTR | `<killy-ipv6>/128 → mail.douzeb.is` | `ovh-dns-sync` | pending |
| OVH Manager | ACME API token (for cert issuance) | Manual (one-time) | existing |
| OVH Manager | DNS API token (for this script) | Manual (one-time, verify/extend existing) | pending |

Items listed as "existing" are currently set but not yet managed by this script;
running `ovh-dns-sync` will adopt them (first run shows OK, future runs detect
drift).

---

## Implementation notes

- The `ovh` Python SDK is available as `pkgs.python3Packages.ovh` in nixpkgs.
- `dnspython` is `pkgs.python3Packages.dnspython`.
- URL-encoding of IPv6 addresses for the `/ip/` endpoint: replace `:` with
  `%3A` and `/` with `%2F`. The `ovh` SDK does NOT automatically percent-encode
  path components — pass the raw address as the key and let the SDK encode it,
  or use `urllib.parse.quote`.
- After `POST /domain/zone/{zone}/refresh`, DNS propagation takes up to the
  record's TTL. FCrDNS validation may fail immediately after setting a PTR if
  the forward record has not yet propagated; the script should note this rather
  than treating it as a hard error.
- The MX record value must end with a `.` (trailing dot = fully-qualified) in
  the OVH API.

---

## Open questions

1. Killy's DKIM key for `douzeb.is` has not been generated. The
   `mail._domainkey.douzeb.is` TXT record in `desired-state.yaml` will need to
   be filled in once the key is generated (separate task).
