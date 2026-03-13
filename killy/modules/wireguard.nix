# killy host OS — WireGuard management interface (spec 0007).
#
# The host exposes only UDP 51820 to the internet. SSH is bound to the
# WireGuard interface (wg0, 10.10.0.1), making the host OS invisible to
# the public internet. The operator laptop connects automatically as a
# permanent peer.
{ config, ... }:

{
  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.10.0.1/24" ];
    listenPort = 51820;
    privateKeyFile = config.sops.secrets."wireguard/host_private_key".path;

    peers = [
      {
        # Operator laptop (10.10.0.2)
        publicKey = "wHD2oVuTC58x9xjZqDfl95RiuPGk31nRSaBjo7+Hjnw=";
        allowedIPs = [ "10.10.0.2/32" ];
        persistentKeepalive = 25;
      }
      # VM peers are added here as VMs are created (spec 0007 §7.1).
      # Example:
      # {
      #   # mail VM (10.10.0.10)
      #   publicKey = "<mail-vm-pubkey>";
      #   allowedIPs = [ "10.10.0.10/32" ];
      # }
    ];
  };
}
