#!/usr/bin/env python3
"""installer-authorized-keys.py — install SSH authorized_keys from install-config.yaml.

Reads the plaintext `installer.authorized_keys` list from the host SOPS config
file and writes them to ~nixos/.ssh/authorized_keys (mode 0600), owned by the
nixos user. Runs as root (via systemd); chowns the .ssh dir and the file so
that sshd will accept the keys.

The authorized_keys field is NOT encrypted by SOPS (it is not listed in
encrypted_regex in .sops.yaml), so this script can run before yk-unwrap.service
— no age key or Yubikey is needed.

Usage (called by installer-authorized-keys.service at boot):
    python3 installer-authorized-keys.py <config-file> <authorized_keys-file> <username>

Dependencies: pyyaml (yaml.safe_load)
"""

import argparse
import os
import pwd
import sys

import yaml


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="path to install-config.yaml")
    parser.add_argument("authorized_keys", help="path to write authorized_keys")
    parser.add_argument("username", help="user who will own the authorized_keys file")
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

    # Look up uid/gid for the target user so we can chown the files.
    # sshd requires ~/.ssh and authorized_keys to be owned by the user.
    try:
        pw = pwd.getpwnam(args.username)
    except KeyError:
        print(f"ERROR: user '{args.username}' not found", file=sys.stderr)
        sys.exit(1)
    uid, gid = pw.pw_uid, pw.pw_gid

    out_path = args.authorized_keys
    ssh_dir = os.path.dirname(out_path)

    os.makedirs(ssh_dir, exist_ok=True)
    os.chown(ssh_dir, uid, gid)
    os.chmod(ssh_dir, 0o700)

    with open(out_path, "w") as f:
        for key in keys:
            f.write(key.strip() + "\n")

    os.chown(out_path, uid, gid)
    os.chmod(out_path, 0o600)
    print(f"installer-authorized-keys: wrote {len(keys)} key(s) to {out_path} (owner: {args.username})")


if __name__ == "__main__":
    main()
