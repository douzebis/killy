#!/usr/bin/env python3
"""yk-unwrap.py — unwrap an age private key using the Yubikey PIV slot 0x9d.

Usage:
    python3 scripts/yk-unwrap.py <wrapped-key-file>

Reads the wrapped key file produced by yk-setup.py, performs ECDH on-device
using PIV slot KEY_MANAGEMENT (0x9d), and prints the plaintext age private
key to stdout. Requires PIN entry.

The wrapped file format:
    ephemeral_pubkey_uncompressed(65) || nonce(12) || ciphertext+tag
"""

import getpass
import sys

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric.ec import (
    EllipticCurvePublicNumbers,
    SECP256R1,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from ykman.device import list_all_devices
from yubikit.core.smartcard import SmartCardConnection
from yubikit.piv import SLOT, PivSession


HKDF_INFO = b"killy-install"
EPHEMERAL_PUBKEY_LEN = 65  # uncompressed P-256 point: 0x04 || x(32) || y(32)
NONCE_LEN = 12


def get_piv_session():
    devs = list(list_all_devices())
    if not devs:
        print("ERROR: no Yubikey found", file=sys.stderr)
        sys.exit(1)
    dev, _ = devs[0]
    conn = dev.open_connection(SmartCardConnection)
    return PivSession(conn)


def load_ephemeral_pubkey(raw_bytes):
    """Parse a 65-byte uncompressed P-256 point into a public key object."""
    x = int.from_bytes(raw_bytes[1:33], "big")
    y = int.from_bytes(raw_bytes[33:65], "big")
    return EllipticCurvePublicNumbers(x, y, SECP256R1()).public_key(
        default_backend()
    )


def unwrap(blob, piv):
    """Unwrap the blob using ECDH on the Yubikey + HKDF-SHA256 + AES-256-GCM."""
    if len(blob) < EPHEMERAL_PUBKEY_LEN + NONCE_LEN + 16:
        print("ERROR: wrapped key file is too short", file=sys.stderr)
        sys.exit(1)

    ephemeral_pub_bytes = blob[:EPHEMERAL_PUBKEY_LEN]
    nonce = blob[EPHEMERAL_PUBKEY_LEN : EPHEMERAL_PUBKEY_LEN + NONCE_LEN]
    ciphertext_and_tag = blob[EPHEMERAL_PUBKEY_LEN + NONCE_LEN :]

    ephemeral_pub = load_ephemeral_pubkey(ephemeral_pub_bytes)

    pin = getpass.getpass("Enter Yubikey PIN: ")
    piv.verify_pin(pin)

    # ECDH on-device: Yubikey private key × ephemeral public key
    shared_secret = piv.calculate_secret(SLOT.KEY_MANAGEMENT, ephemeral_pub)

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
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <wrapped-key-file>", file=sys.stderr)
        sys.exit(1)

    wrapped_path = sys.argv[1]
    try:
        blob = open(wrapped_path, "rb").read()
    except OSError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    piv = get_piv_session()
    plaintext = unwrap(blob, piv)
    sys.stdout.buffer.write(plaintext)


if __name__ == "__main__":
    main()
