#!/usr/bin/env python3
"""installer-authorized-keys.py — install SSH authorized_keys from install-config.yaml.

Reads the plaintext `installer.authorized_keys` list from the host SOPS config
file and writes them to ~nixos/.ssh/authorized_keys (mode 0600).

The authorized_keys field is NOT encrypted by SOPS (it is not listed in
encrypted_regex in .sops.yaml), so this script can run before yk-unwrap.service
— no age key or Yubikey is needed.

Usage (called by installer-authorized-keys.service at boot):
    python3 installer-authorized-keys.py <config-file> <authorized_keys-file>

Dependencies: pyyaml (yaml.safe_load)
"""

import argparse
import os
import sys

import yaml


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="path to install-config.yaml")
    parser.add_argument("authorized_keys", help="path to write authorized_keys")
    args = parser.parse_args()

    with open(args.config) as f:
        config = yaml.safe_load(f)

    try:
        keys = config["installer"]["authorized_keys"]
    except KeyError as e:
        print(f"ERROR: missing key in config: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(keys, list) or not keys:
        print("ERROR: installer.authorized_keys must be a non-empty list", file=sys.stderr)
        sys.exit(1)

    # Validate that every entry looks like a public key (non-empty string)
    for i, key in enumerate(keys):
        if not isinstance(key, str) or not key.strip():
            print(f"ERROR: authorized_keys[{i}] is not a valid string", file=sys.stderr)
            sys.exit(1)

    out_path = args.authorized_keys
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    with open(out_path, "w") as f:
        for key in keys:
            f.write(key.strip() + "\n")

    os.chmod(out_path, 0o600)
    print(f"installer-authorized-keys: wrote {len(keys)} key(s) to {out_path}")


if __name__ == "__main__":
    main()
