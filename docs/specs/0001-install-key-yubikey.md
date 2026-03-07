# 0001 — Install key wrapped in Yubikey

- **Status:** draft
- **Implemented in:** —

---

## Background

The install process requires an age private key (the **install key**) to be
available on the target host at install time, so that the SOPS secrets bundle
can be decrypted autonomously. Storing this key in plaintext anywhere — in the
repo, on the installer USB key, or on disk — is unacceptable.

The solution is to wrap the install key using an asymmetric key held by the
Yubikey: the age private key is encrypted to the Yubikey's on-device P-256
key. The resulting **wrapped install key** (a ciphertext file) is safe to store
on the build host and embed in the installer image. Unwrapping requires the
Yubikey to be physically present; the plaintext age key is produced in RAM and
never written to disk.

---

## Yubikey slot

A PIV **retired key management slot** (0x82–0x95) is used, identified by a
self-signed certificate with `CN=<hostname>-install-key` (e.g.
`CN=killy-install-key`). This avoids conflicts with standard PIV usage (SSH
auth on 0x9a, S/MIME on 0x9d) and allows a single Yubikey to hold install
keys for multiple hosts in separate slots.

The slot is discovered at runtime by scanning retired slots for the matching
CN — no hardcoded slot number anywhere.

The key is generated with `PIN_POLICY=NEVER` and `TOUCH_POLICY=NEVER` so that
unwrapping is fully unattended. Physical presence of both the installer image
and the Yubikey is the sole protection: an attacker must steal both objects to
unwrap the install key. This trade-off is accepted for an unattended server
install context.

If the slot is later overwritten, recovery is straightforward: generate a new
age key, re-run `yk-setup.py --hostname killy`, and run `sops updatekeys`
using the operator key. No secrets are lost.

---

## Goals

1. Implement `scripts/yk-setup.py` — run once per Yubikey on the build host:
   - Scan retired slots (0x82–0x95) for `CN=<hostname>-install-key`.
   - If found and `--force` not set: reuse that slot's key.
   - If not found: pick the first free retired slot, generate a P-256 key
     with `PIN_POLICY=NEVER` and `TOUCH_POLICY=NEVER`, store a self-signed
     certificate with `CN=<hostname>-install-key`.
   - Wrap the age install key with the slot's public key.
   - Write `killy/wrapped-install-key.bin`.
2. Implement `scripts/yk-unwrap.py` — run at install time (or on the build
   host): scan retired slots for `CN=<hostname>-install-key`, unwrap without
   PIN, print the plaintext age key to stdout.
3. Demonstrate end-to-end: generate an age key, wrap it, recover it via the
   Yubikey, and use it to decrypt a SOPS file.

---

## Non-goals

- Asserting or requiring a specific certificate CN on slot 0x9d.
- PIN management or Yubikey initialization.
- Integration into the NixOS installer image (later spec).

---

## Specification

### Architecture

```
[Setup — build host, once per Yubikey]

  age-keygen → age private key (plaintext)
             → age public key (kept in .sops.yaml)

  Yubikey slot 0x9d: generate P-256 key if not present
                     export public key

  Wrap: ECDH(ephemeral_privkey, yubikey_pubkey)
      → AES-256-GCM encrypt(age private key)
      → killy/wrapped-install-key.bin   ← stored in repo / installer image

  age private key (plaintext) → shredded immediately


[Unwrap — installer image or build host, at install time]

  killy/wrapped-install-key.bin  +  Yubikey (PIN entry)
      → ECDH(yubikey_privkey, ephemeral_pubkey)   [on device]
      → AES-256-GCM decrypt
      → age private key → stdout (RAM only, never written to disk)
```

### Cryptographic mechanism

**Slot discovery:**

Scan all retired slots (0x82–0x95) for a self-signed certificate with
`CN=<hostname>-install-key`. If found, use that slot. If not found, pick the
first free retired slot and generate a P-256 key pair on-device with
`PIN_POLICY=NEVER` and `TOUCH_POLICY=NEVER`, then store a self-signed
certificate with `CN=<hostname>-install-key` as a label. The private key is
generated on-device and never exported.

**Wrap (setup):**

1. Export the P-256 public key from slot 0x9d.
2. Generate an ephemeral P-256 key pair in software.
3. Compute ECDH shared secret: `ECDH(ephemeral_privkey, yubikey_pubkey)`.
4. Derive a 32-byte key: `HKDF-SHA256(ikm=shared_secret, salt=b"", info=b"killy-install")`.
5. Encrypt the plaintext age key: `AES-256-GCM(key, nonce=random_12_bytes, plaintext)`.
6. Write wrapped file:
   `ephemeral_pubkey_uncompressed(65) || nonce(12) || ciphertext || tag(16)`.

**Unwrap (at install time):**

1. Read `killy/wrapped-install-key.bin`.
2. Parse: `ephemeral_pubkey(65) || nonce(12) || ciphertext+tag`.
3. Scan retired slots for `CN=<hostname>-install-key` to find the slot.
4. Call `PivSession.calculate_secret(slot, ephemeral_pubkey)` — the Yubikey
   performs ECDH on-device. No PIN required (`PIN_POLICY=NEVER`).
5. Derive the AES key with HKDF-SHA256 and same parameters.
6. Decrypt with AES-256-GCM (authentication tag verified — detects tampering).
7. Print plaintext age key to stdout.

### Script interfaces

```
# One-time setup (build host)
python3 scripts/yk-setup.py --hostname killy \
                             --age-key /path/to/install.key \
                             --out killy/wrapped-install-key.bin

# Re-run after key compromise (forces regeneration)
python3 scripts/yk-setup.py --hostname killy --force \
                             --age-key /path/to/new-install.key \
                             --out killy/wrapped-install-key.bin

# Unwrap (build host or installer image — no PIN, no TTY required)
python3 scripts/yk-unwrap.py --hostname killy killy/wrapped-install-key.bin
```

Both scripts use `PivSession` from the `ykman` Python library directly (no
subprocess calls to `ykman` or `yubico-piv-tool`).

### SOPS integration

The age public key is extracted once during setup and added to `.sops.yaml` as
a recipient. It can be re-derived at any time from the wrapped file using the
Yubikey:

```bash
python3 scripts/yk-unwrap.py --hostname killy killy/wrapped-install-key.bin \
  | age-keygen -y
```

To decrypt a SOPS file at install time (no TTY required):

```bash
SOPS_AGE_KEY=$(python3 scripts/yk-unwrap.py --hostname killy \
                 killy/wrapped-install-key.bin) \
  sops decrypt killy/install-secrets.yaml
```

The plaintext key lives only in the environment variable — in RAM, never on disk.

---

## Recovery procedure (if the install slot is lost or compromised)

1. Generate a new age key in a private temp directory:
   ```bash
   mkdir -m 700 /tmp/yk-setup
   age-keygen -o /tmp/yk-setup/install.key
   ```
2. Re-run setup (`--force` regenerates the on-device key if the CN is still
   present; omit `--force` if the slot was cleared externally):
   ```bash
   python3 scripts/yk-setup.py --hostname killy --force \
     --age-key /tmp/yk-setup/install.key \
     --out killy/wrapped-install-key.bin
   shred -u /tmp/yk-setup/install.key && rmdir /tmp/yk-setup
   ```
3. Update `.sops.yaml` with the new age public key (replace the old one).
4. Update SOPS recipients (operator key authorizes this — no Yubikey needed):
   ```bash
   sops updatekeys killy/install-secrets.yaml
   ```
5. Commit `killy/wrapped-install-key.bin`, `.sops.yaml`, updated secrets files.

No secrets are lost: all secrets bundle files remain decryptable via the
operator key throughout.

---

## Validation steps

Run on the build host with the Yubikey plugged in:

```bash
# 1. Generate a test age key
mkdir -m 700 /tmp/yk-test
age-keygen -o /tmp/yk-test/install.key
AGE_PUB=$(grep 'public key' /tmp/yk-test/install.key | awk '{print $NF}')

# 2. Setup: find or create slot with CN=killy-install-key, wrap the age key
python3 scripts/yk-setup.py \
  --hostname killy \
  --age-key /tmp/yk-test/install.key \
  --out /tmp/yk-test/wrapped.bin
shred -u /tmp/yk-test/install.key

# 3. Create a test SOPS secret encrypted to the install key
echo '{"test": "hello killy"}' | \
  sops --encrypt --age "$AGE_PUB" \
       --input-type json --output-type json /dev/stdin \
  > /tmp/yk-test/secret.yaml

# 4. Decrypt using the Yubikey (no PIN required)
SOPS_AGE_KEY=$(python3 scripts/yk-unwrap.py --hostname killy /tmp/yk-test/wrapped.bin) \
  sops --decrypt /tmp/yk-test/secret.yaml

# Expected output: {"test": "hello killy"}
rm -rf /tmp/yk-test
```

---

## Files introduced

| Path | Description |
|---|---|
| `scripts/yk-setup.py` | One-time: initialize slot 0x9d if needed, wrap age key, write wrapped file |
| `scripts/yk-unwrap.py` | At install time: ECDH unwrap via Yubikey, print age key to stdout |
| `killy/wrapped-install-key.bin` | Ciphertext — safe to commit and embed in installer image |

---

## Open questions

1. **Management key**: `yk-setup.py` currently assumes the default 3DES
   management key. If the Yubikey has a custom management key, the script will
   fail at key generation. Out of scope for this spec.

2. **Multiple Yubikeys**: the design supports multiple Yubikeys (each gets its
   own slot with `CN=killy-install-key`), but `killy/wrapped-install-key.bin`
   stores only one wrapped blob — the one produced by the most recent
   `yk-setup.py` run. Supporting multiple Yubikeys would require storing one
   wrapped blob per device. Out of scope for this spec.
