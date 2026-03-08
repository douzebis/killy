# killy host OS — base configuration.
#
# Covers: hostname, users, SSH, networking (IPv4 static lease + IPv6 pinning),
# boot loader, sops-nix, and firewall baseline. The host OS is intentionally
# minimal — no application services run on bare metal.
{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # System identity
  # ---------------------------------------------------------------------------

  networking.hostName = "killy";

  time.timeZone = "Europe/Paris";

  # ---------------------------------------------------------------------------
  # Boot loader
  # ---------------------------------------------------------------------------

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 7;
  boot.loader.efi.canTouchEfiVariables = true;

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------

  users.users.fred = {
    isNormalUser = true;
    extraGroups = [ "wheel" "libvirtd" ];
    hashedPasswordFile = config.sops.secrets."system/hashed_password".path;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDpqEG79KZxF2UYdK14SrXtRBJGcprD7LnGWZYi92hTd fred@atlant.is"
    ];
  };

  # No password login — key-only SSH and sudo.
  security.sudo.wheelNeedsPassword = false;

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------

  # WiFi — primary interface, static DHCP lease on router for MAC 0c:dd:24:75:3d:ca.
  # The PSK is injected at activation time by sops-nix: the secret is written
  # to /run/secrets/system/wifi_key and read by wpa_supplicant via
  # networking.wireless.secretsFile.
  networking.wireless = {
    enable = true;
    interfaces = [ "wlo1" ];
    # secretsFile must contain lines of the form KEY=value.
    # The @wifi_key@ placeholder in the network PSK is substituted from this file.
    # The secret value is stored as "wifi_key=<psk>" so it satisfies the format.
    secretsFile = config.sops.secrets."system/wifi_key".path;
    networks."douze-bis".psk = "@wifi_key@";
  };

  # Pin the EUI-64 IPv6 address — privacy extensions would rotate the address
  # and break PTR records and firewall rules.
  networking.interfaces.wlo1.ipv6.addresses = [{
    address = "2001:41d0:fc28:400:edd:24ff:fe75:3dca";
    prefixLength = 64;
  }];
  networking.tempAddresses = "disabled";

  # ---------------------------------------------------------------------------
  # SSH
  # ---------------------------------------------------------------------------

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
    # sshd binds to all interfaces (0.0.0.0 + ::). The firewall below is the
    # sole access control: SSH is only reachable on wlo1 (LAN) and wg0 (WireGuard).
  };

  # ---------------------------------------------------------------------------
  # Firewall
  # ---------------------------------------------------------------------------

  networking.firewall = {
    enable = true;
    # Only WireGuard is open to the world. All other inbound is silently dropped.
    allowedUDPPorts = [ 51820 ];
    # SSH on WireGuard and LAN interfaces only.
    interfaces.wg0.allowedTCPPorts = [ 22 ];
    interfaces.wlo1.allowedTCPPorts = [ 22 ];
  };

  # ---------------------------------------------------------------------------
  # sops-nix — secrets decryption at activation time
  # ---------------------------------------------------------------------------

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.defaultSopsFile = ../install-config.yaml;

  sops.secrets."system/wifi_key" = {};

  sops.secrets."system/hashed_password" = {
    neededForUsers = true;
  };

  sops.secrets."wireguard/host_private_key" = {};

  # ---------------------------------------------------------------------------
  # Misc
  # ---------------------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    wireguard-tools
  ];

  system.stateVersion = "25.05";
}
