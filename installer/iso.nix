{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  # -------------------------------------------------------------------------
  # Serial console (USB-serial adapter, null-modem cable to build host)
  # -------------------------------------------------------------------------

  boot.kernelParams = [
    "console=ttyUSB0,115200"
    "console=tty0"
  ];

  systemd.services."serial-getty@ttyUSB0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
  };

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
    initialHashedPassword = "";
  };

  security.sudo.wheelNeedsPassword = false;

  # Allow empty passwords on the console
  services.getty.autologinUser = lib.mkForce null;

  # -------------------------------------------------------------------------
  # PC/SC daemon (required by yk-unwrap.py)
  # -------------------------------------------------------------------------

  services.pcscd.enable = true;

  # -------------------------------------------------------------------------
  # Repo contents embedded in the ISO
  # -------------------------------------------------------------------------

  environment.etc = {
    "nixos/scripts/yk-unwrap.py".source = ../scripts/yk-unwrap.py;
    "nixos/killy/wrapped-install-key.bin".source = ../killy/wrapped-install-key.bin;
    "nixos/killy/install-secrets.yaml".source = ../killy/install-secrets.yaml;
    "nixos/.sops.yaml".source = ../.sops.yaml;
  };

  # -------------------------------------------------------------------------
  # Age key unwrapping service
  # -------------------------------------------------------------------------

  environment.etc."nixos/installer/yk-unwrap-loop.sh" = {
    source = ./yk-unwrap-loop.sh;
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
      ExecStart = "/etc/nixos/installer/yk-unwrap-loop.sh";
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
  # Packages
  # -------------------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    age
    sops
    yubikey-manager
    python3
    python3Packages.cryptography
    git
    jq
  ];

  # -------------------------------------------------------------------------
  # ISO metadata
  # -------------------------------------------------------------------------

  isoImage.isoName = lib.mkForce "killy-installer.iso";
  isoImage.volumeID = lib.mkForce "KILLY_INSTALLER";
}
