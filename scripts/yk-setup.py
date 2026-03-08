#!/usr/bin/env python3
"""yk-setup.py — wrap an age private key using a Yubikey PIV retired slot.

Usage:
    python3 scripts/yk-setup.py --hostname <name> --age-key <path> --out <path> [--force]

Scans all PIV retired slots (0x82-0x95) for a certificate with
CN=<hostname>-install-key. If found, uses that slot's key. If not found,
picks the first free retired slot, generates a P-256 key with
PIN_POLICY.NEVER and TOUCH_POLICY.NEVER, and stores a self-signed
certificate with CN=<hostname>-install-key.

Wraps the age private key from --age-key and writes the ciphertext to --out.
Use --force to regenerate the key even if CN=<hostname>-install-key already
exists (e.g. after Yubikey compromise).

The wrapped file format:
    ephemeral_pubkey_uncompressed(65) || nonce(12) || ciphertext+tag

The plaintext age key is never written to disk beyond the input file.
Prints the age public key to stdout so the caller can add it to .sops.yaml.
"""

import argparse
import os
import re
import sys
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives.asymmetric.ec import (
    ECDH,
    SECP256R1,
    generate_private_key,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.x509.oid import NameOID
from ykman.device import list_all_devices
from ykman.piv import generate_self_signed_certificate
from yubikit.core.smartcard import SmartCardConnection
from yubikit.piv import KEY_TYPE, PIN_POLICY, SLOT, TOUCH_POLICY, PivSession


HKDF_INFO = b"killy-install"
DEFAULT_MGMT_KEY = bytes.fromhex(
    "010203040506070801020304050607080102030405060708"
)

# Retired slots available for custom use (RETIRED1=0x82 … RETIRED20=0x95)
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


def slot_cn(piv, slot):
    """Return the CN of the certificate in slot, or None if absent."""
    try:
        cert = piv.get_certificate(slot)
        attrs = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
        return attrs[0].value if attrs else None
    except Exception:
        return None


def find_slot_by_cn(piv, cn):
    """Return the first retired slot whose certificate CN matches, or None."""
    for slot in RETIRED_SLOTS:
        if slot_cn(piv, slot) == cn:
            return slot
    return None


def find_free_slot(piv):
    """Return the first retired slot with no key/certificate, or None."""
    for slot in RETIRED_SLOTS:
        try:
            piv.get_slot_metadata(slot)
            # Slot has a key — occupied
        except Exception:
            return slot
    return None


def get_or_create_slot(piv, cn, force):
    """
    Find or create a retired slot for the given CN.

    Returns (slot, pubkey). If force=True and the CN already exists,
    the existing key is replaced.
    """
    existing = find_slot_by_cn(piv, cn)

    if existing and not force:
        print(
            f"Found CN={cn} in slot {existing.name} (0x{existing.value:02x}) — using it.",
            file=sys.stderr,
        )
        cert = piv.get_certificate(existing)
        return existing, cert.public_key()

    if existing and force:
        slot = existing
        print(
            f"--force: regenerating key in slot {slot.name} (0x{slot.value:02x}).",
            file=sys.stderr,
        )
    else:
        slot = find_free_slot(piv)
        if slot is None:
            print("ERROR: no free retired slots available (0x82-0x95 all occupied)", file=sys.stderr)
            sys.exit(1)
        print(
            f"No slot with CN={cn} found — using free slot {slot.name} (0x{slot.value:02x}).",
            file=sys.stderr,
        )

    piv.authenticate(piv.management_key_type, DEFAULT_MGMT_KEY)

    pub = piv.generate_key(
        slot,
        KEY_TYPE.ECCP256,
        pin_policy=PIN_POLICY.NEVER,
        touch_policy=TOUCH_POLICY.NEVER,
    )
    print("P-256 key generated on-device (PIN_POLICY=NEVER, TOUCH_POLICY=NEVER).", file=sys.stderr)

    now = datetime.now(timezone.utc)
    cert = generate_self_signed_certificate(
        session=piv,
        slot=slot,
        public_key=pub,
        subject_str=f"CN={cn}",
        valid_from=now,
        valid_to=now + timedelta(days=36500),  # 100 years — purely a label
        hash_algorithm=SHA256,
    )
    piv.put_certificate(slot, cert)
    print(f"Self-signed certificate stored (CN={cn}).", file=sys.stderr)

    return slot, pub


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
    m = re.search(r"#\s*public key:\s*(age1\S+)", age_key_text)
    return m.group(1) if m else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", required=True, help="target hostname (e.g. killy)")
    parser.add_argument("--age-key", required=True, help="path to age private key file")
    parser.add_argument("--out", required=True, help="path to write wrapped key file")
    parser.add_argument(
        "--force",
        action="store_true",
        help="regenerate Yubikey key even if CN=<hostname>-install-key already exists",
    )
    args = parser.parse_args()

    cn = f"{args.hostname}-install-key"
    with open(args.age_key, "rb") as f:
        age_key_bytes = f.read()

    piv = get_piv_session()
    slot, yubikey_pub = get_or_create_slot(piv, cn, args.force)

    blob = wrap(age_key_bytes, yubikey_pub)

    with open(args.out, "wb") as f:
        f.write(blob)
    os.chmod(args.out, 0o644)
    print(f"Wrapped key written to: {args.out} (slot {slot.name})", file=sys.stderr)

    age_pub = age_pubkey_from_privkey(age_key_bytes.decode())
    if age_pub:
        print(age_pub)
    else:
        print("WARNING: could not extract age public key from key file", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
