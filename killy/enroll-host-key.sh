#!/usr/bin/env bash
# enroll-host-key.sh — first-boot host age key enrollment.
#
# Runs as a systemd service on every boot. If install-config.yaml can already
# be decrypted with the SSH host key, exits immediately (no-op). Otherwise,
# uses the Yubikey install key to add the host age key as a sops recipient.
#
# Service ordering on first boot:
#   1. yk-unwrap.service writes /run/age-install-key (Yubikey unwrap).
#   2. sops-install-secrets activates using /run/age-install-key (install key).
#   3. This service runs After= sops-install-secrets, enrolls the host age key,
#      and re-encrypts install-config.yaml for the host key.
# On subsequent boots:
#   1. This service exits immediately (host key already enrolled).
#   2. sops-install-secrets activates using the SSH host key.

set -euo pipefail

SOPS_YAML=/etc/nixos/.sops.yaml
CONFIG=/etc/nixos/install-config.yaml
export SOPS_CONFIG="$SOPS_YAML"
HOST_KEY=/etc/ssh/ssh_host_ed25519_key
WRAPPED_KEY=/etc/nixos/killy/wrapped-install-key.bin
UNWRAP_SCRIPT=/etc/nixos/scripts/yk-unwrap.py
AGE_KEY_FILE=/run/age-install-key

# ---------------------------------------------------------------------------
# Check if enrollment is needed
# ---------------------------------------------------------------------------

if sops decrypt "$CONFIG" > /dev/null 2>&1; then
    echo "enroll-host-key: host key already enrolled — nothing to do"
    exit 0
fi

echo "enroll-host-key: host key not yet enrolled — starting enrollment"

# ---------------------------------------------------------------------------
# Unwrap install age key from Yubikey (retry until present)
# ---------------------------------------------------------------------------

while true; do
    python3 "$UNWRAP_SCRIPT" --hostname killy "$WRAPPED_KEY" \
        > /tmp/yk-unwrap-out 2>/tmp/yk-unwrap-err && RC=0 || RC=$?

    if [[ $RC -eq 0 ]] && [[ -s /tmp/yk-unwrap-out ]]; then
        install -m 0600 /tmp/yk-unwrap-out "$AGE_KEY_FILE"
        rm -f /tmp/yk-unwrap-out /tmp/yk-unwrap-err
        echo "enroll-host-key: install age key loaded"
        break
    fi

    MSG=$(grep -m1 "ERROR\|error" /tmp/yk-unwrap-err 2>/dev/null || echo "unknown error")
    echo "enroll-host-key: Yubikey not ready — ${MSG}. Retrying in 2s..."
    sleep 2
done

export SOPS_AGE_KEY
SOPS_AGE_KEY=$(cat "$AGE_KEY_FILE")

# ---------------------------------------------------------------------------
# Derive host age public key
# ---------------------------------------------------------------------------

HOST_AGE_PUB=$(ssh-to-age -i "${HOST_KEY}.pub")
echo "enroll-host-key: host age public key: $HOST_AGE_PUB"

# ---------------------------------------------------------------------------
# Add host key to .sops.yaml
# ---------------------------------------------------------------------------

# Insert or replace the killy host key entry. The build-host .sops.yaml does
# not carry the host key, so we always insert it here.
HOST_KEY_BLOCK=$(printf \
    '      # killy host key (derived from SSH host ed25519 key via ssh-to-age)\n      - %s\n      ' \
    "$HOST_AGE_PUB")

# If a "# killy host key" block already exists, replace the age key on the
# next non-comment line. Otherwise insert before the first recipient line.
if grep -q "# killy host key" "$SOPS_YAML"; then
    # Replace the age key on the line following the comment block
    python3 - "$SOPS_YAML" "$HOST_AGE_PUB" <<'EOF'
import re, sys
path, new_key = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(
    r'(# killy host key[^\n]*\n(?:\s*#[^\n]*\n)*\s*)- age1\S+',
    lambda m: m.group(1) + "- " + new_key,
    text, count=1
)
open(path, 'w').write(text)
EOF
else
    # Insert before the first recipient line under age:
    python3 - "$SOPS_YAML" "$HOST_KEY_BLOCK" <<'EOF'
import re, sys
path, block = sys.argv[1], sys.argv[2]
text = open(path).read()
# Find the first "      - age1..." line and insert our block before it
text = re.sub(r'(\n\s+age:\n)(\s+- age1)', r'\1' + block + r'\2', text, count=1)
open(path, 'w').write(text)
EOF
fi

# ---------------------------------------------------------------------------
# Re-encrypt install-config.yaml for the new host key
# ---------------------------------------------------------------------------

sops updatekeys --yes "$CONFIG"
echo "enroll-host-key: sops updatekeys complete"

# /run/age-install-key remains for sops-install-secrets to use on this boot
echo "enroll-host-key: enrollment complete"
