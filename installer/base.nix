{ config, pkgs, lib, modulesPath, ... }:

# Shared installer ISO base module.
#
# Do not use this module directly. Import it from a host-specific iso.nix
# (e.g. killy/iso.nix) and set the required installer.* options for that host.
#
# Boot sequence on the target machine:
#   1. yk-unwrap.service   — asks the Yubikey to decrypt the age install key,
#                            writes it to /run/age-install-key, retries until
#                            the Yubikey is present.
#   2. installer-network.service — decrypts WiFi credentials from the SOPS
#                            secrets file using the age key, then connects.
#   3. Login shells        — SOPS_AGE_KEY is exported automatically so that
#                            `sops decrypt` works without any manual setup.
#
# SSH access from the build host requires no password; the host's public key
# must be baked into the ISO via users.users.nixos.openssh.authorizedKeys.keys.

let
  cfg = config.installer;

  # Python interpreter for yk-unwrap.py.
  #
  # yubikey-manager is a top-level Nix package, not available in python3Packages,
  # so we build a combined environment from its own bundled Python interpreter.
  # This gives us: ykman, yubikit, fido2, cryptography — the full closure needed
  # by yk-unwrap.py, pinned to the same versions yubikey-manager was built with.
  unwrapPython = pkgs.yubikey-manager.pythonModule.withPackages (ps: [
    pkgs.yubikey-manager  # provides ykman + yubikit
    ps.cryptography       # AES-GCM decryption of the wrapped age key
  ]);

  # Python interpreter for installer-authorized-keys.py.
  #
  # Kept separate from unwrapPython intentionally: this script has no Yubikey
  # dependency and runs before yk-unwrap.service. Using a standard python3 env
  # makes the dependency explicit and avoids coupling to yubikey-manager's
  # internal Python version.
  authorizedKeysPython = pkgs.python3.withPackages (ps: [
    ps.pyyaml  # parse install-config.yaml
  ]);
in {
  options.installer = {
    hostname = lib.mkOption {
      type        = lib.types.str;
      description = ''
        Target machine hostname. Used to locate per-host files on the ISO
        (/etc/nixos/<hostname>/) and to find the correct PIV slot on the
        Yubikey (certificate CN=<hostname>-install-key).
      '';
    };

    wrappedKey = lib.mkOption {
      type        = lib.types.path;
      description = ''
        Path to the wrapped install key file (wrapped-install-key.bin).
        This is the age private key encrypted to the Yubikey's on-device
        P-256 key. Safe to embed in the ISO — it cannot be decrypted
        without physical access to the Yubikey.
      '';
    };

    configFile = lib.mkOption {
      type        = lib.types.path;
      description = ''
        Path to the host SOPS secrets file (install-config.yaml).
        Embedded in the ISO at /etc/nixos/<hostname>/install-config.yaml.
        All sensitive fields are SOPS-encrypted; the file is safe to embed.
      '';
    };

    sopsYaml = lib.mkOption {
      type        = lib.types.path;
      description = ''
        Path to the repository .sops.yaml file containing SOPS creation
        rules and age recipient public keys. Embedded at /etc/nixos/.sops.yaml
        so that `sops` on the installer can find its configuration.
      '';
    };

    unwrapScript = lib.mkOption {
      type        = lib.types.path;
      description = ''
        Path to scripts/yk-unwrap.py. Embedded at
        /etc/nixos/scripts/yk-unwrap.py and called by yk-unwrap.service
        at boot to perform ECDH on-device and recover the age private key.
      '';
    };

    wifiInterface = lib.mkOption {
      type        = lib.types.str;
      default     = "wlo1";
      description = ''
        Name of the WiFi network interface on the target machine
        (e.g. wlo1, wlan0). Used by wpa_supplicant and installer-network.service.
        Check with `ip link` on the target if unsure.
      '';
    };
  };

  # Base the ISO on the upstream minimal NixOS installer image, which sets up
  # squashfs, EFI boot, live system infrastructure, and the nixos user account.
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  config = {
    # -------------------------------------------------------------------------
    # Serial console
    #
    # Kernel output and getty are available on both the local display (tty0)
    # and a USB-serial adapter (ttyUSB0, 115200 baud). Connect from the build
    # host with: screen /dev/ttyUSB0 115200
    #
    # ttyUSB0 is added to getty.target directly (not via a udev rule) because
    # udev only fires on plug events — if the adapter is already present when
    # the system boots, the event is missed and the getty never starts.
    # -------------------------------------------------------------------------

    boot.kernelParams = [
      "console=ttyUSB0,115200"  # primary: USB-serial adapter
      "console=tty0"            # fallback: local display
    ];

    console.keyMap = "fr";

    systemd.services."serial-getty@ttyUSB0" = {
      wantedBy              = [ "getty.target" ];
      serviceConfig.Restart = "always";  # respawn if the cable is briefly unplugged
    };

    # -------------------------------------------------------------------------
    # nixos user
    #
    # The installer profile already creates a passwordless nixos user; we add
    # sudo and the build host SSH public key so the operator can run privileged
    # commands remotely without any password prompts.
    # -------------------------------------------------------------------------

    users.users.nixos = {
      isNormalUser = true;
      extraGroups  = [ "wheel" ];
      # Authorized keys are NOT baked into the ISO here. They are read at boot
      # from install-config.yaml (installer.authorized_keys) by
      # installer-authorized-keys.service, which writes them to
      # ~nixos/.ssh/authorized_keys before sshd starts. This keeps the key
      # list in one place (the config file) rather than duplicated in the Nix
      # source.
    };

    security.sudo.wheelNeedsPassword = false;

    # Auto-login on tty0 and ttyUSB0 so the operator reaches a shell
    # immediately on boot without typing a password at the console.
    # lib.mkForce overrides the priority set by the upstream installer profile.
    services.getty.autologinUser = lib.mkForce "nixos";

    # -------------------------------------------------------------------------
    # PC/SC daemon
    #
    # pcscd brokers access to smart card readers, including the Yubikey's CCID
    # interface. It must be running before yk-unwrap.service attempts to talk
    # to the Yubikey. NixOS starts it via socket activation.
    # -------------------------------------------------------------------------

    services.pcscd.enable = true;

    # -------------------------------------------------------------------------
    # Files embedded in the ISO
    #
    # All paths below are available read-only under /etc/nixos/ on the live
    # system. The secrets files (wrapped-install-key.bin, install-config.yaml)
    # are safe to embed — they are encrypted and cannot be used without the
    # Yubikey.
    # -------------------------------------------------------------------------

    environment.etc = {
      "nixos/scripts/yk-unwrap.py".source                   = cfg.unwrapScript;
      "nixos/${cfg.hostname}/wrapped-install-key.bin".source = cfg.wrappedKey;
      "nixos/${cfg.hostname}/install-config.yaml".source     = cfg.configFile;
      "nixos/.sops.yaml".source                              = cfg.sopsYaml;

      # Scripts called by the systemd services below.
      # They live in /etc so they can be read and debugged by the operator.
      "nixos/installer/yk-unwrap-loop.sh" = {
        source = ./yk-unwrap-loop.sh;
        mode   = "0755";
      };
      "nixos/installer/installer-authorized-keys.py" = {
        source = ./installer-authorized-keys.py;
        mode   = "0755";
      };
      "nixos/installer/installer-network.sh" = {
        source = ./installer-network.sh;
        mode   = "0755";
      };

      # Installer-side helper scripts (on PATH in the installer shell).
      # Common to all hosts — reads hostname and disk spec from install-config.yaml.
      # Named killy-install (not install) to avoid shadowing the standard Unix
      # `install` utility, which nixos-install uses internally.
      "nixos/installer/bin/killy-install" = {
        source = ./bin/killy-install;
        mode   = "0755";
      };

    };

    # -------------------------------------------------------------------------
    # Writable overlay over /etc/nixos
    #
    # The ISO embeds /etc/nixos on a read-only squashfs. Mounting an overlayfs
    # here gives a writable /etc/nixos for the duration of the session (changes
    # live in RAM on /run/nixos-overlay/upper/). This makes it easy to sync an
    # updated repo from the build host (rsync, scp) without needing to reflash
    # the Lexar for every iteration.
    #
    # Upper and work dirs are on tmpfs (/run) — changes are lost on reboot.
    # -------------------------------------------------------------------------

    system.activationScripts.nixosOverlay = {
      text = ''
        mkdir -p /run/nixos-overlay/upper /run/nixos-overlay/work
        # Only mount if not already overlaid (idempotent).
        if ! grep -q 'overlay /etc/nixos' /proc/mounts 2>/dev/null; then
          ${pkgs.util-linux}/bin/mount -t overlay overlay \
            -o lowerdir=/etc/nixos,upperdir=/run/nixos-overlay/upper,workdir=/run/nixos-overlay/work \
            /etc/nixos
        fi
      '';
      deps = [];
    };

    # -------------------------------------------------------------------------
    # installer-authorized-keys.service
    #
    # Runs early in boot — before sshd — to populate ~nixos/.ssh/authorized_keys
    # from the installer.authorized_keys list in install-config.yaml.
    #
    # The authorized_keys field is stored PLAINTEXT in install-config.yaml (it
    # is not listed in encrypted_regex in .sops.yaml). This service therefore
    # does NOT depend on yk-unwrap.service or the Yubikey — it can run
    # immediately from the embedded config file.
    #
    # To update the key list: edit killy/install-config.yaml (sops edit) and
    # rebuild the ISO. The YAML field is:
    #   installer:
    #     authorized_keys:
    #       - "ssh-ed25519 AAAA... user@host"
    # -------------------------------------------------------------------------

    systemd.services.installer-authorized-keys = {
      description = "Install SSH authorized_keys from install-config.yaml";
      # before = sshd ensures ordering; wantedBy = sshd makes sshd pull this
      # service in as a dependency so it waits for completion before accepting
      # connections. Both are needed — before alone only orders within an
      # existing transaction; wantedBy alone doesn't enforce ordering.
      before   = [ "sshd.service" ];
      wantedBy = [ "multi-user.target" "sshd.service" ];
      environment.HOSTNAME = cfg.hostname;
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${authorizedKeysPython}/bin/python3 /etc/nixos/installer/installer-authorized-keys.py"
          + " /etc/nixos/${cfg.hostname}/install-config.yaml"
          + " /home/nixos/.ssh/authorized_keys"
          + " nixos";
        StandardOutput = "journal+console";
        StandardError  = "journal+console";
      };
    };

    # -------------------------------------------------------------------------
    # yk-unwrap.service
    #
    # Runs at boot. Calls yk-unwrap.py via the Yubikey to perform ECDH on-device
    # and recover the plaintext age private key. Writes it to /run/age-install-key
    # (mode 0644, tmpfs — never touches disk). Retries every 2 seconds until the
    # Yubikey is present and responsive.
    #
    # The service does NOT block the login prompt; the operator can log in while
    # the service is still retrying, and SOPS_AGE_KEY will be available in their
    # session once the service succeeds.
    # -------------------------------------------------------------------------

    systemd.services.yk-unwrap = {
      description = "Unwrap age install key from Yubikey";
      after       = [ "pcscd.service" ];
      requires    = [ "pcscd.service" ];
      wantedBy    = [ "multi-user.target" ];
      # ExecStart uses the full bash store path (systemd resolves ExecStart
      # before PATH is applied). PATH is still set so that yk-unwrap-loop.sh
      # can call bare `python3` and find the ykman/cryptography imports.
      path        = [ pkgs.bash unwrapPython ];
      environment.HOSTNAME = cfg.hostname;
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        ExecStart       = "${pkgs.bash}/bin/bash /etc/nixos/installer/yk-unwrap-loop.sh";
        StandardOutput  = "journal+console";
        StandardError   = "journal+console";
      };
    };

    # -------------------------------------------------------------------------
    # installer-network.service
    #
    # Runs after yk-unwrap.service (needs the age key to decrypt WiFi credentials)
    # and after wpa_supplicant is up (needs a running daemon to configure).
    # Decrypts the WiFi SSID and PSK from install-config.yaml using SOPS, then
    # configures wpa_supplicant via wpa_cli. dhcpcd picks up the IP automatically
    # once the interface associates.
    # -------------------------------------------------------------------------

    systemd.services.installer-network = {
      description = "Configure installer WiFi from SOPS credentials";
      after       = [ "yk-unwrap.service" "wpa_supplicant-${cfg.wifiInterface}.service" ];
      requires    = [ "yk-unwrap.service" ];
      wantedBy    = [ "multi-user.target" ];
      path        = [ pkgs.bash pkgs.sops pkgs.wpa_supplicant pkgs.iproute2 ];
      environment = {
        HOSTNAME       = cfg.hostname;
        WIFI_INTERFACE = cfg.wifiInterface;
      };
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        ExecStart       = "${pkgs.bash}/bin/bash /etc/nixos/installer/installer-network.sh";
        StandardOutput  = "journal+console";
        StandardError   = "journal+console";
      };
    };

    # -------------------------------------------------------------------------
    # SSH server
    #
    # Accepts connections using key-based authentication only. Password and
    # keyboard-interactive auth are disabled. Authorized keys are written to
    # ~nixos/.ssh/authorized_keys at boot by installer-authorized-keys.service,
    # which reads them from install-config.yaml (installer.authorized_keys).
    #
    # To connect from the build host once the network is up:
    #   ssh nixos@<ip>
    # -------------------------------------------------------------------------

    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin              = "no";
        PasswordAuthentication       = false;
        KbdInteractiveAuthentication = false;
      };
    };

    # -------------------------------------------------------------------------
    # Login shell environment
    #
    # NixOS does not source /etc/profile.d/*.sh for bash login shells —
    # the correct hook is programs.bash.loginShellInit, which is appended
    # to /etc/bashrc and sourced by every bash login shell (interactive and
    # non-interactive login, including `ssh nixos@<ip> "bash -l ..."`).
    #
    # SOPS_AGE_KEY is exported so the operator can run `sops decrypt`
    # immediately after logging in without any manual setup. The age key
    # is in /run/age-install-key (mode 0644) once yk-unwrap.service succeeds.
    # -------------------------------------------------------------------------

    programs.bash.loginShellInit = ''
      if [ -r /run/age-install-key ]; then
        export SOPS_AGE_KEY=$(cat /run/age-install-key)
      fi
      # Put installer helpers on PATH (killy-install, etc.).
      # Note: build-host tools (build-iso, killy-serial, killy-setup) live in
      # bin/ and are NOT added here — they don't belong on the installer.
      export PATH="/etc/nixos/installer/bin:$PATH"
    '';

    # -------------------------------------------------------------------------
    # WiFi
    #
    # wpa_supplicant is enabled for the configured interface. Credentials are
    # NOT set here — installer-network.service configures them at runtime by
    # decrypting the SOPS secrets file and calling wpa_cli. dhcpcd runs
    # automatically and assigns an IP once the interface associates.
    # -------------------------------------------------------------------------

    networking.wireless = {
      enable     = true;
      interfaces = [ cfg.wifiInterface ];
    };

    # -------------------------------------------------------------------------
    # Packages available on the live system
    # -------------------------------------------------------------------------

    environment.systemPackages = with pkgs; [
      age             # age encryption — used to generate host keys at install time
      ssh-to-age      # derive age key from SSH ed25519 host key (used by bin/install)
      sops            # SOPS secrets decryption
      yubikey-manager # ykman — Yubikey management and diagnostics
      git             # clone / inspect the repo
      rsync           # sync repo from build host to /etc/nixos overlay
      vim             # editor
      jq              # parse JSON output from various tools
      htop            # process and resource monitoring
      curl            # test network connectivity
      strace          # debug service startup failures
      nmap            # network diagnostics
      tcpdump         # packet-level WiFi/DHCP debugging
      dmidecode       # read BIOS/board/RAM details from DMI table
      nvme-cli        # NVMe drive info and SMART data
      smartmontools   # SMART data for all drive types
      pciutils        # lspci — PCI device inventory
      usbutils        # lsusb — USB device inventory
      iw              # WiFi interface info and capabilities
      parted          # partition inspection (parted -l)
      util-linux      # lsblk, blkid, findmnt, lscpu
      btrfs-progs     # btrfs subvolume/filesystem inspection
      cryptsetup      # LUKS inspection (cryptsetup luksDump)
      e2fsprogs       # fsck, tune2fs
      dosfstools      # EFI partition tools (fsck.fat, mkfs.fat)
      (python3.withPackages (ps: [ ps.pyyaml ]))  # scripting + yaml parsing (bin/install)
    ];
  };
}
