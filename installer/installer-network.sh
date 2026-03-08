#!/usr/bin/env bash
# installer-network.sh — configure WiFi using credentials from SOPS install-config.yaml.
#
# Runs after yk-unwrap.service has written the age key to /run/age-install-key.
# Decrypts the installer section from install-config.yaml and configures wpa_supplicant.

set -euo pipefail

HOSTNAME="${HOSTNAME:?HOSTNAME must be set}"
WIFI_INTERFACE="${WIFI_INTERFACE:-wlo1}"
CONFIG=/etc/nixos/${HOSTNAME}/install-config.yaml
AGE_KEY_FILE=/run/age-install-key

export SOPS_AGE_KEY
SOPS_AGE_KEY=$(cat "$AGE_KEY_FILE")

WIFI_SSID=$(sops decrypt --extract '["installer"]["wifi_ssid"]' "$CONFIG")
WIFI_KEY=$(sops decrypt --extract '["installer"]["wifi_key"]' "$CONFIG")

echo "installer-network: configuring WiFi for SSID: ${WIFI_SSID}"

wpa_passphrase "$WIFI_SSID" "$WIFI_KEY" > /run/wpa_supplicant.conf
chmod 600 /run/wpa_supplicant.conf

systemctl restart "wpa_supplicant-${WIFI_INTERFACE}.service"
echo "installer-network: WiFi configured, waiting for association..."

# Wait up to 30s for an IP address
for i in $(seq 1 15); do
    sleep 2
    if ip route | grep -q "^default"; then
        echo "installer-network: network up, default route acquired"
        exit 0
    fi
done

echo "installer-network: WARNING: no default route after 30s"
exit 1
