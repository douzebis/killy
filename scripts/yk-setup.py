#!/usr/bin/env python3
"""yk-setup.py — wrap an age private key using the Yubikey PIV slot 0x9d.

Usage:
    python3 scripts/yk-setup.py --age-key <path> --out <path>

Reads the age private key from --age-key, wraps it using the P-256 key in
PIV slot KEY_MANAGEMENT (0x9d), and writes the ciphertext to --out.

If slot 0x9d has no key, one is generated on-device first (requires the
default management key).

The wrapped file format:
    ephemeral_pubkey_uncompressed(65) || nonce(12) || ciphertext+tag

The plaintext age key is never written to disk beyond the input file.
Prints the age public key to stdout so the caller can add it to .sops.yaml.
"""

import argparse
import os
import re
import sys

from cryptography.hazmat.primitives.asymmetric.ec import (
    ECDH,
    SECP256R1,
    generate_private_key,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from ykman.device import list_all_devices
from yubikit.core.smartcard import SmartCardConnection
from yubikit.piv import KEY_TYPE, SLOT, PivSession


HKDF_INFO = b"killy-install"
# Default management key (3DES/AES all-zeros variant shipped on every Yubikey)
DEFAULT_MGMT_KEY = bytes.fromhex(
    "010203040506070801020304050607080102030405060708"
)


def get_piv_session():
    devs = list(list_all_devices())
    if not devs:
        print("ERROR: no Yubikey found", file=sys.stderr)
        sys.exit(1)
    dev, _ = devs[0]
    conn = dev.open_connection(SmartCardConnection)
    return PivSession(conn)


def get_or_generate_key(piv):
    """Return the P-256 public key from slot 0x9d, generating it if absent."""
    try:
        piv.get_slot_metadata(SLOT.KEY_MANAGEMENT)
        # Slot has a key — retrieve public key via certificate if present,
        # otherwise fall through to generate (should not happen in practice).
        cert = piv.get_certificate(SLOT.KEY_MANAGEMENT)
        print("Slot 0x9d already has a key — using it.", file=sys.stderr)
        return cert.public_key()
    except Exception:
        pass

    # Slot is empty — generate a new P-256 key on-device.
    print("Slot 0x9d is empty — generating P-256 key on-device...", file=sys.stderr)
    piv.authenticate(piv.management_key_type, DEFAULT_MGMT_KEY)
    pub = piv.generate_key(SLOT.KEY_MANAGEMENT, KEY_TYPE.ECCP256)
    print("Key generated in slot 0x9d.", file=sys.stderr)
    return pub


def wrap(plaintext, yubikey_pubkey):
    """Wrap plaintext using ECDH(ephemeral, yubikey) + HKDF-SHA256 + AES-256-GCM."""
    ephemeral_priv = generate_private_key(SECP256R1())
    ephemeral_pub = ephemeral_priv.public_key()

    shared_secret = ephemeral_priv.exchange(ECDH(), yubikey_pubkey)

    aes_key = HKDF(
        algorithm=SHA256(),
        length=32,
        salt=None,
        info=HKDF_INFO,
    ).derive(shared_secret)

    nonce = os.urandom(12)
    ciphertext_and_tag = AESGCM(aes_key).encrypt(nonce, plaintext, None)

    ephemeral_pub_bytes = ephemeral_pub.public_bytes(
        Encoding.X962, PublicFormat.UncompressedPoint
    )
    return ephemeral_pub_bytes + nonce + ciphertext_and_tag


def age_pubkey_from_privkey(age_key_text):
    """Extract the age public key comment line from an age private key file."""
    # age-keygen output: '# public key: age1...\nAGE-SECRET-KEY-1...\n'
    m = re.search(r"#\s*public key:\s*(age1\S+)", age_key_text)
    if m:
        return m.group(1)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--age-key", required=True, help="path to age private key file")
    parser.add_argument("--out", required=True, help="path to write wrapped key file")
    args = parser.parse_args()

    age_key_bytes = open(args.age_key, "rb").read()

    piv = get_piv_session()
    yubikey_pub = get_or_generate_key(piv)

    blob = wrap(age_key_bytes, yubikey_pub)

    with open(args.out, "wb") as f:
        f.write(blob)
    os.chmod(args.out, 0o644)
    print(f"Wrapped key written to: {args.out}", file=sys.stderr)

    age_pub = age_pubkey_from_privkey(age_key_bytes.decode())
    if age_pub:
        print(age_pub)
    else:
        print("WARNING: could not extract age public key from key file", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
