{ config, pkgs, lib, modulesPath, ... }:

# Shared installer ISO base module.
# Import this from a host-specific iso.nix and set installer.hostname,
# installer.wrappedKey, installer.configFile, installer.sofsYaml.

let
  cfg = config.installer;
in {
  options.installer = {
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "Target hostname (used as CN=<hostname>-install-key).";
    };
    wrappedKey = lib.mkOption {
      type = lib.types.path;
      description = "Path to the wrapped install key file (wrapped-install-key.bin).";
    };
    configFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the host SOPS config file (install-config.yaml).";
    };
    sofsYaml = lib.mkOption {
      type = lib.types.path;
      description = "Path to the .sops.yaml creation rules file.";
    };
    unwrapScript = lib.mkOption {
      type = lib.types.path;
      description = "Path to yk-unwrap.py.";
    };
    wifiInterface = lib.mkOption {
      type = lib.types.str;
      default = "wlo1";
      description = "WiFi interface name (e.g. wlo1, wlan0).";
    };
  };

  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  config = {
    # -------------------------------------------------------------------------
    # Serial console (USB-serial adapter, null-modem cable to build host)
    # -------------------------------------------------------------------------

    boot.kernelParams = [
      "console=ttyUSB0,115200"
      "console=tty0"
    ];

    # French keyboard layout on the local (tty0) console
    console.keyMap = "fr";

    # Start serial getty when ttyUSB0 appears (udev-triggered)
    services.udev.extraRules = ''
      SUBSYSTEM=="tty", KERNEL=="ttyUSB0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="serial-getty@ttyUSB0.service"
    '';

    systemd.services."serial-getty@" = {
      serviceConfig.ExecStart = lib.mkForce
        "${pkgs.util-linux}/sbin/agetty --noclear %I 115200 vt220";
    };

    # -------------------------------------------------------------------------
    # Passwordless login for nixos user
    # -------------------------------------------------------------------------

    users.users.nixos = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      # Password is "nixos" — installer ISO only, no security concern
      initialHashedPassword = "$6$stTOKx2z7fSzTz1W$NW6bAn6DCnxUzfnejeSvKuNoHNIOF7IigRurDfymuOhGjR1uQTN6e9dfjoC79lTguV19Y03B187A0HMY60HgW1";
    };

    security.sudo.wheelNeedsPassword = false;

    services.getty.autologinUser = lib.mkForce "nixos";

    # -------------------------------------------------------------------------
    # PC/SC daemon (required by yk-unwrap.py)
    # -------------------------------------------------------------------------

    services.pcscd.enable = true;

    # -------------------------------------------------------------------------
    # Repo contents embedded in the ISO
    # -------------------------------------------------------------------------

    environment.etc = {
      "nixos/scripts/yk-unwrap.py".source = cfg.unwrapScript;
      "nixos/${cfg.hostname}/wrapped-install-key.bin".source = cfg.wrappedKey;
      "nixos/${cfg.hostname}/install-config.yaml".source = cfg.configFile;
      "nixos/.sops.yaml".source = cfg.sofsYaml;
    };

    # -------------------------------------------------------------------------
    # Age key unwrapping service
    # -------------------------------------------------------------------------

    environment.etc."nixos/installer/yk-unwrap-loop.sh" = {
      source = ./yk-unwrap-loop.sh;
      mode = "0755";
    };

    environment.etc."nixos/installer/installer-network.sh" = {
      source = ./installer-network.sh;
      mode = "0755";
    };

    systemd.services.yk-unwrap = {
      description = "Unwrap age install key from Yubikey";
      after = [ "pcscd.service" ];
      requires = [ "pcscd.service" ];
      before = [ "getty.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/installer/yk-unwrap-loop.sh";
        Environment = "HOSTNAME=${cfg.hostname}";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };

    # -------------------------------------------------------------------------
    # Network configuration service (WiFi via SOPS credentials)
    # -------------------------------------------------------------------------

    systemd.services.installer-network = {
      description = "Configure installer WiFi from SOPS credentials";
      after = [ "yk-unwrap.service" "wpa_supplicant.service" ];
      requires = [ "yk-unwrap.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/installer/installer-network.sh";
        Environment = [ "HOSTNAME=${cfg.hostname}" "WIFI_INTERFACE=${cfg.wifiInterface}" ];
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };

    # -------------------------------------------------------------------------
    # SOPS_AGE_KEY injected into every login shell
    # -------------------------------------------------------------------------

    environment.etc."profile.d/sops-age-key.sh" = {
      text = ''
        if [ -r /run/age-install-key ]; then
          export SOPS_AGE_KEY=$(cat /run/age-install-key)
        fi
      '';
      mode = "0644";
    };

    # -------------------------------------------------------------------------
    # SSH server — accessible with empty password for nixos user
    # -------------------------------------------------------------------------

    services.openssh = {
      enable = true;
      settings = {
        PermitEmptyPasswords = true;
        PermitRootLogin = "no";
      };
    };

    # -------------------------------------------------------------------------
    # WiFi — wpa_supplicant managed by installer-network.service
    # -------------------------------------------------------------------------

    networking.wireless = {
      enable = true;
      interfaces = [ cfg.wifiInterface ];
    };

    # -------------------------------------------------------------------------
    # Packages
    # -------------------------------------------------------------------------

    environment.systemPackages = with pkgs; [
      age
      sops
      yubikey-manager
      (python3.withPackages (ps: [ ps.cryptography ps.yubikey-manager ]))
      git
      jq
    ];
  };
}
