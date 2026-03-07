# killy install process — design

## Glossary

| Term | Definition |
|---|---|
| **target host** | The machine being installed — killy (formerly motoko). |
| **build host** | The NixOS machine used to build the installer image and write it to the installer key. |
| **installer key** | The bootable USB key. Contains the full NixOS installer image with the target system's pre-built Nix closure. Booted on the target host at install time. |
| **Yubikey** | The physical hardware security token (Yubico). Stores the install key in a protected slot. |
| **install key** | The age private key wrapped inside the Yubikey (via `yb`). Released only when the Yubikey is present (and PIN-unlocked if configured). Added as a SOPS recipient to all secrets so the installer can decrypt them autonomously. |
| **operator key** | The operator's personal age key, stored under `~/.config/sops/age/keys.txt` on the build host. Used day-to-day to edit and re-encrypt secrets. Also a SOPS recipient on all secrets. |
| **secrets bundle** | The collection of SOPS-encrypted YAML files committed to the repo (OVH credentials, DKIM key, Restic password, S3 credentials). Each file is encrypted to multiple recipients: the target host's age key (derived from its SSH host key), the install key, and the operator key. |
| **host key** | The target host's SSH ed25519 host key, generated fresh at each install. An age public key is derived from it (`ssh-to-age`) and used as the primary SOPS recipient for the installed system. |

---

## Goal

A documented, reproducible process to:

1. Build an installer key (from the build host) containing everything needed to
   install killy from scratch.
2. Boot killy from the installer key; the install proceeds **autonomously** —
   driven by the secrets bundle, with no operator interaction beyond physical
   Yubikey presence.
3. After install: partition, configure NixOS, restore mail data from backup, and
   bring all services back online.
4. Ensure TLS certificates are always valid after reinstall (addressing the
   current certificate staleness issue).

The process must survive the total loss of the killy machine and leave no
manual undocumented steps.

**Target:** full reinstall + mail restoration within **2 hours**, single
operator (Fred).

---

## Scripting language policy

Scripts in this project are split by execution context:

| Context | Language | Rationale |
|---|---|---|
| Installer image (`install.bash`, runs on live ISO) | **bash** | Minimal runtime, easy to audit, no interpreter dependencies in the ISO |
| Build-host tooling (PKI, cert lifecycle, key management) | **Python 3** | Real logic, testable, `cryptography` library handles X.509/ECDH natively without shelling out to openssl |
| Day-to-day SOPS helpers | **bash** | Short orchestration of CLI tools |

Python tooling lives under `scripts/` in the repo and is available in the
`nix-shell` dev environment (`default.nix`). Installer bash scripts live under
`installer/`.

---

## Current state (as-is)

| Aspect | Current situation |
|---|---|
| OS install | `bootstrap.bash` run from installer machine over SSH to NixOS live ISO |
| Config | NixOS flake in `/etc/nixos/`, cloned from GitHub (`douzebis/major.git`) |
| Secrets | SOPS/age-encrypted YAML files in repo; age key derived from SSH host key |
| Mail data | `/var/spool/mail/fred` backed up nightly at 03:00 to OVH S3 via Restic |
| TLS certs | Obtained by ACME DNS-01 via OVH API; **currently stale** on the mail vhost |

### Certificate staleness (hypothesis)

The `mail.atlant.is` certificate used by Postfix and Dovecot is stale,
causing client warnings. Most likely the ACME renewal systemd service has
silently failed — either bad OVH credentials, a misconfigured service unit,
or an issue left over from a previous reinstall. Root cause to be confirmed
from live logs (`journalctl -u acme-mail.service`) when available.

The reinstall process fixes this structurally: certificate issuance is a
**hard gate** — the process does not proceed until all certs are verified
valid.

---

## Key design decision: autonomous install via install key

All secrets needed for install (OVH API credentials, S3 credentials, Restic
password, DKIM key) live in the secrets bundle, encrypted to three recipients:
the current target host's age key, the operator key, and the **install key**.

The install key is an age key whose private part is stored inside the Yubikey.
When the installer key boots on the target host and the Yubikey is plugged in,
the installer can call `yb read killy-install` to load the install key into RAM
and decrypt the entire secrets bundle — **without any SSH session or external
input from the operator**.

This means:

- The installer key is self-contained: insert USB + insert Yubikey → install
  runs to completion unattended.
- No secrets are embedded in the installer image itself. The installer key is
  safe to lose (it contains only the pre-built Nix closure and tooling).
- The Yubikey is the single physical credential required for autonomous
  operation. If PIN protection is enabled on the Yubikey slot, entering the PIN
  is the only operator interaction during install.

The install key is the only long-lived install-time secret. The target host's
age key changes on each reinstall (derived from the freshly generated SSH host
key); the secrets bundle is re-encrypted to the new host key as part of the
install script, and the install key is removed as a recipient once the
installed system is self-sufficient.

---

## Proposed process (to-be)

### Install flow

```
[Build host]                              [killy — booted from installer key]
      |                                                |
1. nix build .#installer-iso                          |
2. dd ISO to installer key                            |
3. Boot killy from installer key -------------------+ |
      |   (sshd starts — optional, for monitoring)  | |
      |                                              | |
      |   [Yubikey plugged in to killy]              | |
      |                                              | |
4. Install script runs automatically ---------------+ |
      |   a. Load install key from Yubikey to RAM    | |
      |   b. Decrypt secrets bundle                  | |
      |   c. Partition + format NVMe                 | |
      |   d. Clone repo from GitHub                  | |
      |   e. Generate bootstrap.nix                  | |
      |   f. Derive new host age pubkey from host key| |
      |   g. Re-encrypt secrets bundle to new host key|
      |   h. Remove install key from SOPS recipients | |
      |   i. Push updated secrets to repo            | |
      |   j. nixos-install (closure from installer key)
      |   k. Reboot                                  | |
      |                                              | |
      |   [killy reboots into installed system]      | |
      |                                              | |
5. nixos-rebuild switch ---------------------------+ |
      |   (fast — closure already in Nix store)     | |
      |                                              | |
6. Force ACME cert issuance — HARD GATE -----------+ |
      |   Fail and stop if any cert invalid          | |
      |                                              | |
7. Restore mail from Restic backup ----------------+ |
      |                                              | |
8. Smoke tests ------------------------------------+ |
```

---

### Phase 1 — Build the installer key

On the build host:

```bash
nix build .#installer-iso
dd if=result/iso/nixos-installer-*.iso of=/dev/sdX bs=4M status=progress
```

The ISO is a NixOS flake output containing:

- All install tooling: `git`, `parted`, `age`, `ssh-to-age`, `sops`,
  `restic`, `awscli2`, `openssh`, `yb`, `nix` with flakes enabled.
- **The pre-built Nix closure for the full killy system configuration**,
  stored in the ISO's Nix store. This is what makes the 2-hour window
  achievable: `nixos-install` copies from the installer key rather than
  downloading from cache.nixos.org. The ISO is large (~several GiB) but
  avoids network download time during install.
- Wired DHCP enabled.
- The operator's SSH public key pre-authorized for the `nixos` live user
  (optional — for monitoring only; the install does not require SSH).
- **No secrets.** The install key arrives at runtime from the Yubikey.

The ISO is built fresh whenever killy's flake changes materially (nixpkgs
bump, new module). `flake.lock` pins all inputs so builds are reproducible.

### Phase 2 — Boot and autonomous install

Insert the installer key and the Yubikey into killy and power on.

The installer image runs `install.bash` automatically on first boot. The
script loads the install key from the Yubikey:

```bash
yb read killy-install > /tmp/install.key
chmod 0400 /tmp/install.key
```

`/tmp` on the live system is a tmpfs (RAM-only). The install key never
touches disk. From this point the script runs fully autonomously.

The operator may optionally connect for monitoring:

```bash
ssh nixos@192.168.42.42
```

### Phase 3 — Install script

`install.bash` (committed to the repo):

1. Loads the install key from the Yubikey into `/tmp/install.key` (RAM only).
2. Partitions `/dev/nvme0n1`: GPT, 512 MiB EFI (FAT32) + rest ext4, no swap.
3. Formats and mounts at `/mnt`.
4. Clones the killy repo from GitHub into `/mnt/etc/nixos/`.
5. Generates `bootstrap.nix` from `bootstrap.tpl.nix`.
6. Derives the new host age public key from the freshly generated SSH host key:
   ```bash
   NEW_AGE_PUB=$(ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub)
   ```
7. Re-encrypts all secrets bundle files to add the new host age key as recipient:
   ```bash
   SOPS_AGE_KEY_FILE=/tmp/install.key \
     sops updatekeys --yes killy/acme/ovh-creds.yaml
   # ... repeated for all secrets files
   ```
8. Removes the install key from SOPS recipients (so the installed system is
   self-sufficient without Yubikey).
9. Pushes the re-encrypted secrets bundle back to the repo.
10. Runs `nixos-install --no-root-passwd` — closure served from the installer
    key's Nix store, so this is fast.
11. Reboots into the installed system.

### Phase 4 — Apply full configuration

After reboot, SSH in and run:

```bash
nixos-rebuild switch --flake /etc/nixos#killy
```

sops-nix decrypts all secrets using the age key derived from the new host key.
The Nix closure is already local, so this is fast.

### Phase 5 — Force TLS certificate issuance (hard gate)

Trigger ACME renewal for all four certificates explicitly:

```bash
for cert in mail www root immich; do
  systemctl start acme-${cert}.service
  systemctl is-active acme-${cert}.service || { echo "FAILED: $cert"; exit 1; }
  openssl x509 -in /var/lib/acme/${cert}/fullchain.pem -noout -dates
done
```

The process **stops here** if any certificate fails. Failure means OVH API
credentials are wrong, DNS propagation has not completed, or the ACME service
is misconfigured — all of which must be fixed before mail can work.

This gate is the structural fix for the current certificate staleness: instead
of relying on a background renewal job that can silently fail, the reinstall
process asserts certificate validity as a precondition for going live.

### Phase 6 — Restore mail from backup

```bash
. /run/secrets/ovh/s3_creds
. /run/secrets/restic/mail_creds
restic snapshots                   # confirm latest snapshot timestamp
restic restore latest --target / --include /var/spool/mail/fred
chown -R fred:mail /var/spool/mail/fred
systemctl restart postfix dovecot2
```

### Phase 7 — Smoke tests

| Test | Command |
|---|---|
| SMTP STARTTLS | `swaks --to fred@atlant.is --from admin@atlant.is --server mail.atlant.is -p 587 --tls --auth-user admin` |
| SMTPS | `swaks --to fred@atlant.is --server mail.atlant.is -p 465 --tlsc --auth-user admin` |
| IMAP TLS | `openssl s_client -connect mail.atlant.is:993` |
| HTTPS | `curl -sv https://atlant.is` |
| DKIM + spam score | send test mail, check at `https://www.mail-tester.com/` |

---

## Secret custody model

| Secret | Storage | How accessed at install |
|---|---|---|
| Install key | Yubikey (`yb slot killy-install`) | `yb read killy-install` → `/tmp` (RAM only) |
| Operator key | `~/.config/sops/age/keys.txt` on build host | Used to edit secrets day-to-day; not needed at install time |
| OVH API key (ACME) | Secrets bundle (SOPS in repo) | Decrypted at install time via install key; at runtime via host key |
| OVH S3 credentials | Secrets bundle (SOPS in repo) | Decrypted at install time via install key; at runtime via host key |
| Restic password | Secrets bundle (SOPS in repo) | Decrypted at install time via install key; at runtime via host key |
| DKIM private key | Secrets bundle (SOPS in repo) | Decrypted at install time via install key; at runtime via host key |
| Host key | Generated fresh at each install | Age key derived from it; secrets bundle re-encrypted to it |

Each secrets bundle file has three SOPS recipients:
- the current target host's age key (derived from SSH host key),
- the install key (age pubkey from Yubikey),
- the operator key.

After install the install key is removed as recipient; only the host key
and operator key remain.

---

## One-time setup (first time only)

Before the first install, the following must be done once on the build host:

1. Generate the install key and store it in the Yubikey:
   ```bash
   age-keygen -o /tmp/killy-install.key
   yb write killy-install < /tmp/killy-install.key
   shred -u /tmp/killy-install.key
   ```
2. Extract the install key's age public key:
   ```bash
   yb pubkey killy-install
   ```
3. Add the install key and the operator key as recipients in all secrets bundle
   files (`.sops.yaml` creation key list + `sops updatekeys` on each file).

This is a one-time operation. Subsequent installs require no changes to the
secrets bundle structure.

---

## Open questions

1. **Yubikey PIN**: is PIN protection enabled on the Yubikey slot used for the
   install key? If so, the operator must enter the PIN at the killy console
   (or over serial) at the start of the install. This is the only interactive
   step in the otherwise autonomous process.

2. **Auto-run mechanism**: how does `install.bash` run automatically on first
   boot of the installer key? Options: a systemd oneshot service in the ISO
   image, or a getty autologin that executes the script. To be decided during
   implementation.

3. **Wifi**: is killy always on wired Ethernet (`eno1`)? If so, wifi support
   in the ISO can be omitted.

4. **Certificate staleness root cause**: to be diagnosed from
   `journalctl -u acme-mail.service` on the live server when accessible.
   Does not block the process design, but informs whether a config fix is also
   needed alongside the forced renewal gate.

5. **Bootstrap key existence**: does the install key already exist on the
   Yubikey, or does it need to be created as part of this work? See
   one-time setup section above.
