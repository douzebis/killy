#!/usr/bin/env python3
"""yk-unwrap.py — unwrap an age private key using a Yubikey PIV retired slot.

Usage:
    python3 scripts/yk-unwrap.py --hostname <name> <wrapped-key-file>

Scans all PIV retired slots (0x82-0x95) for a certificate with
CN=<hostname>-install-key, performs ECDH on-device (no PIN required —
PIN_POLICY=NEVER), and prints the plaintext age private key to stdout.

The wrapped file format:
    ephemeral_pubkey_uncompressed(65) || nonce(12) || ciphertext+tag
"""

import argparse
import sys

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric.ec import (
    EllipticCurvePublicNumbers,
    SECP256R1,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.x509.oid import NameOID
from ykman.device import list_all_devices
from yubikit.core.smartcard import SmartCardConnection
from yubikit.piv import SLOT, PivSession


HKDF_INFO = b"killy-install"
EPHEMERAL_PUBKEY_LEN = 65  # uncompressed P-256 point: 0x04 || x(32) || y(32)
NONCE_LEN = 12

RETIRED_SLOTS = [
    SLOT.RETIRED1, SLOT.RETIRED2, SLOT.RETIRED3, SLOT.RETIRED4,
    SLOT.RETIRED5, SLOT.RETIRED6, SLOT.RETIRED7, SLOT.RETIRED8,
    SLOT.RETIRED9, SLOT.RETIRED10, SLOT.RETIRED11, SLOT.RETIRED12,
    SLOT.RETIRED13, SLOT.RETIRED14, SLOT.RETIRED15, SLOT.RETIRED16,
    SLOT.RETIRED17, SLOT.RETIRED18, SLOT.RETIRED19, SLOT.RETIRED20,
]


def get_piv_session():
    devs = list(list_all_devices())
    if not devs:
        print("ERROR: no Yubikey found", file=sys.stderr)
        sys.exit(1)
    dev, _ = devs[0]
    conn = dev.open_connection(SmartCardConnection)
    return PivSession(conn)


def find_slot_by_cn(piv, cn):
    """Return the first retired slot whose certificate CN matches, or None."""
    for slot in RETIRED_SLOTS:
        try:
            cert = piv.get_certificate(slot)
            attrs = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
            if attrs and attrs[0].value == cn:
                return slot
        except Exception:
            continue
    return None


def load_ephemeral_pubkey(raw_bytes):
    """Parse a 65-byte uncompressed P-256 point into a public key object."""
    x = int.from_bytes(raw_bytes[1:33], "big")
    y = int.from_bytes(raw_bytes[33:65], "big")
    return EllipticCurvePublicNumbers(x, y, SECP256R1()).public_key(
        default_backend()
    )


def unwrap(blob, piv, slot):
    """Unwrap the blob using ECDH on the Yubikey + HKDF-SHA256 + AES-256-GCM."""
    if len(blob) < EPHEMERAL_PUBKEY_LEN + NONCE_LEN + 16:
        print("ERROR: wrapped key file is too short", file=sys.stderr)
        sys.exit(1)

    ephemeral_pub_bytes = blob[:EPHEMERAL_PUBKEY_LEN]
    nonce = blob[EPHEMERAL_PUBKEY_LEN : EPHEMERAL_PUBKEY_LEN + NONCE_LEN]
    ciphertext_and_tag = blob[EPHEMERAL_PUBKEY_LEN + NONCE_LEN :]

    ephemeral_pub = load_ephemeral_pubkey(ephemeral_pub_bytes)

    # PIN_POLICY=NEVER — no verify_pin() call needed
    shared_secret = piv.calculate_secret(slot, ephemeral_pub)

    aes_key = HKDF(
        algorithm=SHA256(),
        length=32,
        salt=None,
        info=HKDF_INFO,
    ).derive(shared_secret)

    try:
        plaintext = AESGCM(aes_key).decrypt(nonce, ciphertext_and_tag, None)
    except Exception:
        print("ERROR: decryption failed — wrong key or corrupted file", file=sys.stderr)
        sys.exit(1)

    return plaintext


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", required=True, help="target hostname (e.g. killy)")
    parser.add_argument("wrapped_key", help="path to wrapped key file")
    args = parser.parse_args()

    cn = f"{args.hostname}-install-key"

    try:
        with open(args.wrapped_key, "rb") as f:
            blob = f.read()
    except OSError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    piv = get_piv_session()

    slot = find_slot_by_cn(piv, cn)
    if slot is None:
        print(f"ERROR: no slot with CN={cn} found on Yubikey", file=sys.stderr)
        sys.exit(1)
    print(f"Using slot {slot.name} (0x{slot.value:02x}, CN={cn})", file=sys.stderr)

    plaintext = unwrap(blob, piv, slot)
    sys.stdout.buffer.write(plaintext)


if __name__ == "__main__":
    main()
