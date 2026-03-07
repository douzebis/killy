# killy — operator user guide

This guide covers the day-to-day operations and one-time setup tasks for the
killy installation. It assumes the build host is already running NixOS with the
repo checked out and the `nix-shell` dev environment available.

---

## Prerequisites

Enter the dev shell before running any script or SOPS command:

```bash
cd ~/code/killy
nix-shell        # or: nix-shell --run bash
```

The dev shell provides: `age`, `ssh-to-age`, `sops`, `yubikey-manager`,
`yubico-piv-tool`, `python3`, `cryptography`, `ruff`, `openssl`, `jq`.

---

## Secrets management

Secrets live in `killy/install-secrets.yaml`, encrypted with SOPS/age.

Three recipients are registered in `.sops.yaml`:

| Recipient | Key | When used |
|---|---|---|
| Host key | Derived from SSH host ed25519 key via `ssh-to-age` | Runtime (on killy) |
| Operator key | `~/.config/sops/age/keys.txt` on build host | Day-to-day editing |
| Install key | Yubikey PIV slot 0x9d, unwrapped via `yk-unwrap.py` | Autonomous install |

### Decrypt a secrets file (day-to-day)

The operator key in `~/.config/sops/age/keys.txt` is picked up automatically:

```bash
sops decrypt killy/install-secrets.yaml
```

### Edit a secrets file

```bash
sops edit killy/install-secrets.yaml
```

### Decrypt using the Yubikey (install key)

Plug in the Yubikey, then:

```bash
SOPS_AGE_KEY=$(python3 scripts/yk-unwrap.py --hostname killy \
                 killy/wrapped-install-key.bin) \
  sops decrypt killy/install-secrets.yaml
```

No PIN is required — the install slot uses `PIN_POLICY=NEVER` for unattended
operation. The age private key lives only in the environment variable — in RAM,
never on disk.

---

## Yubikey scripts

### `scripts/yk-setup.py` — one-time setup per Yubikey

Run once when setting up a new Yubikey (or to rotate the install key):

```bash
# 1. Generate a fresh age install key in a private temp directory
mkdir -m 700 /tmp/yk-setup
age-keygen -o /tmp/yk-setup/install.key

# 2. Find or create the install slot and wrap the age key.
#    Prints the age public key to stdout.
python3 scripts/yk-setup.py \
  --hostname killy \
  --age-key /tmp/yk-setup/install.key \
  --out killy/wrapped-install-key.bin

# 3. Securely delete the plaintext age key
shred -u /tmp/yk-setup/install.key && rmdir /tmp/yk-setup
```

The printed age public key must be recorded in `.sops.yaml` under
`creation_rules[].age`, then `sops updatekeys` must be run on the secrets
file to add the install key as a recipient (see below).

**What it does internally:**
- Scans PIV retired slots (0x82–0x95) for `CN=killy-install-key`.
- If found and `--force` not set: reuses that slot's existing key.
- If not found: picks the first free retired slot, generates a P-256 key
  on-device with `PIN_POLICY=NEVER` and `TOUCH_POLICY=NEVER`, stores a
  self-signed certificate with `CN=killy-install-key` as a label.
- Performs ECDH between an ephemeral software key pair and the slot's public key.
- Derives a 32-byte AES key via HKDF-SHA256 (`info=b"killy-install"`).
- Encrypts the age key with AES-256-GCM and writes:
  `ephemeral_pubkey(65 bytes) || nonce(12 bytes) || ciphertext+tag`
  to `killy/wrapped-install-key.bin`.

**Trade-off:** `PIN_POLICY=NEVER` means the Yubikey will unwrap the install
key with no PIN. Physical possession of both the Yubikey and the installer
image is the sole protection. The two objects should be stored and transported
separately.

**Requirements:** Yubikey plugged in, pcscd running (managed by systemd —
do not start pcscd manually).

---

### `scripts/yk-unwrap.py` — unwrap at install time

```bash
python3 scripts/yk-unwrap.py --hostname killy killy/wrapped-install-key.bin
```

Scans retired slots for `CN=killy-install-key`, performs ECDH on-device
without PIN, and prints the plaintext age key to stdout. No TTY required —
safe to call from scripts and systemd units.

**Typical use — decrypt a SOPS file:**

```bash
SOPS_AGE_KEY=$(python3 scripts/yk-unwrap.py --hostname killy \
                 killy/wrapped-install-key.bin) \
  sops decrypt killy/install-secrets.yaml
```

**Re-derive the install key's age public key** (e.g. after losing track of it):

```bash
python3 scripts/yk-unwrap.py --hostname killy \
  killy/wrapped-install-key.bin | age-keygen -y
```

---

## Adding a new Yubikey (or replacing the install key)

If the Yubikey is lost, replaced, or the install slot is compromised:

1. Run `yk-setup.py --force` to regenerate the on-device key and wrap a new
   age key (see the script section above).
2. Update `.sops.yaml` with the new age public key (replace the old one under
   `# install key`).
3. Re-encrypt the secrets file for the new recipient (operator key authorizes
   this — no Yubikey needed):
   ```bash
   sops updatekeys killy/install-secrets.yaml
   ```
4. Commit `killy/wrapped-install-key.bin`, `.sops.yaml`, and the updated
   secrets file.

No secrets are lost: the secrets file remains decryptable via the operator key
throughout.

---

## Yubikey troubleshooting

### "No YubiKey detected" from ykman

First check that pcscd is not holding stale processes:

```bash
pgrep -a pcscd     # should show at most one process, or none
ykman list         # triggers socket-activated pcscd
```

If multiple pcscd processes are running (leftover from manual debugging):

```bash
sudo kill $(pgrep pcscd)
sleep 1
sudo rm -f /run/pcscd/pcscd.comm
ykman list
```

Never start pcscd manually. The systemd unit manages it correctly via socket
activation with `--auto-exit`. See `docs/yubikey-vm-passthrough.md` for full
diagnosis notes (VM-specific, but the pcscd section applies generally).

### PIN

The install slot uses `PIN_POLICY=NEVER` — no PIN is required for unwrapping.
The PIV PIN is not used by `yk-unwrap.py`.

If you use other PIV slots on the same Yubikey (e.g. for SSH auth), the
default PIN is `123456` and should be changed:

```bash
ykman piv access change-pin
```

---

## Operator key setup (build host, one-time)

The operator key enables day-to-day secrets editing without the Yubikey. It
is derived from the build host's SSH host key:

```bash
# Derive the age key from the SSH host key
sudo ssh-to-age -private-key \
  < /etc/ssh/ssh_host_ed25519_key \
  >> ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Verify that SOPS can decrypt:

```bash
sops decrypt killy/install-secrets.yaml | head -3
```

---

## Installation process overview

> Full detail in `docs/design/killy-install.md`. This is a summary.

### What is not yet implemented

The full autonomous install is a future milestone. The following pieces are
still to be built:

- `installer/install.bash` — the install script that runs on the live ISO
- The NixOS installer ISO flake output (`.#installer-iso`)
- Automated `nixos-install` integration

### What is already in place

- `killy/install-secrets.yaml` — all secrets encrypted, three recipients
- `killy/wrapped-install-key.bin` — install key wrapped in Yubikey serial
  32283437, slot 0x9d
- `.sops.yaml` — creation rules with all three recipients registered
- `scripts/yk-setup.py` / `scripts/yk-unwrap.py` — Yubikey wrap/unwrap scripts

### Intended install flow (when complete)

1. Build host: `nix build .#installer-iso` → write ISO to USB key.
2. Insert USB installer key + Yubikey into killy, power on.
3. `install.bash` runs automatically:
   - Loads install key from Yubikey into RAM (PIN prompt at console).
   - Decrypts secrets bundle.
   - Partitions NVMe, clones repo, generates `bootstrap.nix`.
   - Derives new host age key, re-encrypts secrets to new host key.
   - Removes install key from SOPS recipients, pushes to repo.
   - Runs `nixos-install`, reboots.
4. After reboot: `nixos-rebuild switch --flake /etc/nixos#killy`.
5. Force TLS certificate issuance (hard gate — stops if any cert fails).
6. Restore mail from Restic backup.
7. Smoke tests (SMTP, IMAP, HTTPS, DKIM).
