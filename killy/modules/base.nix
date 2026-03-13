# killy host OS — base configuration.
#
# Covers: hostname, users, SSH, networking (IPv4 static lease + IPv6 pinning),
# boot loader, sops-nix, and firewall baseline. The host OS is intentionally
# minimal — no application services run on bare metal.
#
# Part of killy/modules/ — mirrored to /etc/nixos/modules/ on the installed system.
{ config, pkgs, lib, ... }:

let
  # Python interpreter with Yubikey support for enroll-host-key.sh.
  # yubikey-manager is not in python3Packages; build from its bundled interpreter.
  unwrapPython = pkgs.yubikey-manager.pythonModule.withPackages (ps: [
    pkgs.yubikey-manager
    ps.cryptography
  ]);
in

{
  # ---------------------------------------------------------------------------
  # System identity
  # ---------------------------------------------------------------------------

  networking.hostName = "killy";

  time.timeZone = "Europe/Paris";

  console.keyMap = "fr";

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
    # secretsFile sets wpa_supplicant's ext_password_backend. Secrets are
    # referenced as ext:<key> where <key> matches a KEY=value line in the file.
    # The sops secret file contains "wifi_key=<psk>" so we reference it as
    # ext:wifi_key via pskRaw.
    secretsFile = config.sops.secrets."system/wifi_key".path;
    networks."douze-bis".pskRaw = "ext:wifi_key";
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

  # Use systemd service for secret decryption rather than activation script.
  # This allows ordering: yk-unwrap.service runs first (Yubikey unwrap),
  # then sops-install-secrets.service decrypts secrets using the install key.
  # On subsequent boots (after host key enrollment), the SSH host key suffices.
  sops.useSystemdActivation = true;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.age.keyFile      = "/run/age-install-key";
  sops.defaultSopsFile  = "/etc/nixos/install-config.yaml";
  sops.validateSopsFiles = false;

  sops.secrets."system/wifi_key" = {};

  sops.secrets."system/hashed_password" = {
    neededForUsers = true;
  };

  sops.secrets."wireguard/host_private_key" = {};

  # ---------------------------------------------------------------------------
  # Serial console — ttyUSB0 (FT232 USB-serial adapter, null-modem to killy)
  # ---------------------------------------------------------------------------

  # Route kernel output and getty to the USB-serial adapter so the build host
  # can interact with killy without a monitor.
  boot.kernelParams = [
    "console=ttyUSB0,115200"  # primary: USB-serial adapter
    "console=tty0"            # fallback: local display
  ];

  systemd.services."serial-getty@ttyUSB0" = {
    wantedBy          = [ "getty.target" ];
    overrideStrategy  = "asDropin";
    serviceConfig = {
      Restart   = "always";
      ExecStart = [
        ""  # clear the upstream default
        "${pkgs.util-linux}/bin/agetty --autologin fred 115200 ttyUSB0 vt220"
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # First-boot host key enrollment
  # ---------------------------------------------------------------------------

  # pcscd brokers access to the Yubikey CCID interface, needed by yk-unwrap.py.
  services.pcscd.enable = true;

  # yk-unwrap: run before sops-install-secrets so the install age key is
  # available at /run/age-install-key on first boot (before host key enrollment).
  systemd.services.yk-unwrap = {
    description = "Unwrap age install key from Yubikey";
    wantedBy    = [ "sysinit.target" ];
    before      = [ "sops-install-secrets.service" ];
    after       = [ "pcscd.service" ];
    wants       = [ "pcscd.service" ];
    path        = [ unwrapPython ];
    environment.HOSTNAME = "killy";
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart       = "${pkgs.bash}/bin/bash /etc/nixos/installer/yk-unwrap-loop.sh";
      StandardOutput  = "journal+console";
      StandardError   = "journal+console";
    };
  };

  # Enroll the SSH host age key as a sops recipient on first boot (idempotent).
  # Runs after sops-install-secrets so secrets are available, but the yk-unwrap
  # above provides /run/age-install-key for the first boot decryption.
  systemd.services.killy-enroll-host-key = {
    description = "Enroll SSH host age key as sops recipient";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "sops-install-secrets.service" "sshd-keygen.service" "pcscd.service" ];
    wants       = [ "pcscd.service" ];
    path        = [ pkgs.sops pkgs.ssh-to-age pkgs.age unwrapPython ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart       = "${pkgs.bash}/bin/bash /etc/nixos/enroll-host-key.sh";
    };
  };

  # ---------------------------------------------------------------------------
  # Misc
  # ---------------------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    wireguard-tools
    lsof
    psmisc       # fuser, killall
    age          # age encryption
    ssh-to-age   # derive age key from SSH ed25519 host key
    sops         # SOPS secrets management
    unwrapPython # python3 + yubikey-manager + cryptography (for enroll-host-key.sh)
  ];

  system.stateVersion = "25.05";
}
