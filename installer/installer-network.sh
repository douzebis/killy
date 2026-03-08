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

# Add a new network block to the running wpa_supplicant daemon.
#
# NixOS writes wpa_supplicant's config to a Nix store path at startup, so we
# cannot replace or modify it. Instead we use wpa_cli to add a network block
# at runtime. wpa_cli communicates with the already-running daemon via its
# control socket (/var/run/wpa_supplicant/<iface>).
#
# The ssid and psk values must be passed with an extra layer of shell quoting
# so that wpa_cli receives them surrounded by double quotes, as required by
# the wpa_supplicant protocol. The '"'"..."'"' construct produces: "value"
NETID=$(wpa_cli -i "${WIFI_INTERFACE}" add_network)
wpa_cli -i "${WIFI_INTERFACE}" set_network "${NETID}" ssid '"'"${WIFI_SSID}"'"'
wpa_cli -i "${WIFI_INTERFACE}" set_network "${NETID}" psk '"'"${WIFI_KEY}"'"'
wpa_cli -i "${WIFI_INTERFACE}" enable_network "${NETID}"
wpa_cli -i "${WIFI_INTERFACE}" select_network "${NETID}"

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
