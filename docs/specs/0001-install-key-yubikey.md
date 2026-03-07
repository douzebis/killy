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

The PIV **Key Management slot (0x9d)** is used. This is the standard slot
designed for asymmetric key unwrapping (originally for S/MIME session key
decryption) and is present on every PIV-capable Yubikey.

Using 0x9d means the workflow works with any Yubikey without requiring a
dedicated device or a dedicated slot. If the slot is later overwritten (e.g.
for S/MIME or VPN use), recovery is straightforward: generate a new age key,
re-wrap it, and run `sops updatekeys` using the operator key. No secrets are
lost because the secrets bundle is always decryptable via the operator key.

The current Yubikey (serial 32283437) has slot 0x9d empty — a key will be
generated during setup.

---

## Goals

1. Implement `scripts/yk-setup.py` — run once per Yubikey on the build host:
   - If slot 0x9d has no key: generate a P-256 key pair on-device.
   - Wrap the age install key with the 0x9d public key.
   - Write `killy/wrapped-install-key.bin`.
2. Implement `scripts/yk-unwrap.py` — run at install time (or on the build
   host): unwrap using slot 0x9d, print the plaintext age key to stdout.
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

**Key generation (if slot 0x9d is empty):**

Generate a P-256 key pair inside Yubikey PIV slot 0x9d. The private key is
generated on-device and never exported. No certificate is required; the public
key is exported directly with `PivSession.get_certificate` or, if no
certificate exists, via `ykman piv keys export`.

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
3. Call `PivSession.calculate_secret(SLOT.KEY_MANAGEMENT, ephemeral_pubkey)` —
   the Yubikey performs ECDH on-device. Requires PIN.
4. Derive the AES key with HKDF-SHA256 and same parameters.
5. Decrypt with AES-256-GCM (authentication tag verified — detects tampering).
6. Print plaintext age key to stdout.

### Script interfaces

```
# One-time setup (build host)
python3 scripts/yk-setup.py --age-key /path/to/install.key \
                             --out killy/wrapped-install-key.bin

# Unwrap (build host or installer image)
python3 scripts/yk-unwrap.py killy/wrapped-install-key.bin
```

Both scripts use `PivSession` from the `ykman` Python library directly (no
subprocess calls to `ykman` or `yubico-piv-tool`).

### SOPS integration

The age public key is extracted once during setup and added to `.sops.yaml` as
a recipient. It can be re-derived at any time from the wrapped file using the
Yubikey:

```bash
python3 scripts/yk-unwrap.py killy/wrapped-install-key.bin | age-keygen -y
```

To decrypt a SOPS file at install time:

```bash
SOPS_AGE_KEY=$(python3 scripts/yk-unwrap.py killy/wrapped-install-key.bin) \
  sops decrypt killy/acme/ovh-creds.yaml
```

The plaintext key lives only in the environment variable — in RAM, never on disk.

---

## Recovery procedure (if slot 0x9d is overwritten)

1. Generate a new age key:
   ```bash
   age-keygen -o /tmp/new-install.key
   AGE_PUB=$(age-keygen -y /tmp/new-install.key)
   ```
2. Re-run setup with the new Yubikey state:
   ```bash
   python3 scripts/yk-setup.py --age-key /tmp/new-install.key \
                                --out killy/wrapped-install-key.bin
   shred -u /tmp/new-install.key
   ```
3. Update SOPS recipients (operator key authorizes this):
   ```bash
   sops updatekeys killy/acme/ovh-creds.yaml
   # ... repeated for all secrets files
   ```
4. Update `.sops.yaml` with the new age public key, commit.

No secrets are lost: all secrets bundle files remain decryptable via the
operator key throughout.

---

## Validation steps

Run on the build host with the Yubikey plugged in:

```bash
# 1. Generate a test age key
age-keygen -o /tmp/test-install.key
AGE_PUB=$(age-keygen -y /tmp/test-install.key)

# 2. Setup: initialize slot 0x9d if needed, wrap the age key
python3 scripts/yk-setup.py \
  --age-key /tmp/test-install.key \
  --out /tmp/wrapped-install-key.bin
shred -u /tmp/test-install.key

# 3. Create a test SOPS secret encrypted to the install key
echo '{"test": "hello killy"}' | \
  sops --encrypt --age "$AGE_PUB" \
       --input-type json --output-type json /dev/stdin \
  > /tmp/test-secret.yaml

# 4. Decrypt using the Yubikey (PIN prompted)
SOPS_AGE_KEY=$(python3 scripts/yk-unwrap.py /tmp/wrapped-install-key.bin) \
  sops --decrypt /tmp/test-secret.yaml

# Expected output: {"test": "hello killy"}
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

1. **Existing slot 0x9d content**: if a future Yubikey already has a key in
   slot 0x9d (from prior PIV use), `yk-setup.py` must use it as-is rather than
   overwriting it. The script should detect this and skip key generation.

2. **PIN requirement**: the Yubikey is currently using the **default PIN
   (123456)**. This must be changed before production use. Out of scope for
   this spec.
