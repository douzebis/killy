#!/usr/bin/env bash
# yk-unwrap-loop.sh — unwrap age install key from Yubikey, retrying until present.
#
# Called by yk-unwrap.service at boot. Writes the plaintext age key to
# /run/age-install-key (mode 0644, tmpfs — never touches disk) and exits.
# Prints a status message to the console on each retry.

set -euo pipefail

# HOSTNAME is injected by the systemd service environment
: "${HOSTNAME:?HOSTNAME must be set by the calling service}"
WRAPPED_KEY=/etc/nixos/${HOSTNAME}/wrapped-install-key.bin
UNWRAP_SCRIPT=/etc/nixos/scripts/yk-unwrap.py
OUT=/run/age-install-key

while true; do
  python3 "$UNWRAP_SCRIPT" --hostname "$HOSTNAME" "$WRAPPED_KEY" \
    > /tmp/yk-unwrap-out 2>/tmp/yk-unwrap-err && RC=0 || RC=$?

  if [[ $RC -eq 0 ]] && [[ -s /tmp/yk-unwrap-out ]]; then
    install -m 0644 /tmp/yk-unwrap-out "$OUT"
    rm -f /tmp/yk-unwrap-out /tmp/yk-unwrap-err
    echo "yk-unwrap: age install key loaded successfully"
    exit 0
  fi

  MSG=$(grep -m1 "ERROR\|error" /tmp/yk-unwrap-err 2>/dev/null \
        || echo "unknown error")
  echo "yk-unwrap: Yubikey not ready — ${MSG}. Retrying in 2s..."
  sleep 2
done
