# Flake entry point for the killy project.
#
# Outputs:
#
#   devShells.x86_64-linux.default   — build-host dev shell (enter with nix-shell)
#
#   packages.x86_64-linux.installer-iso-killy
#     — bootable installer ISO for the killy host.
#       Build with:  build-iso          (inside nix-shell)
#       or directly: nix build .#installer-iso-killy
#       Result:      ./result/iso/killy-installer.iso
#
# Note: nixosConfigurations.killy lives in killy/flake.nix (self-contained,
# mirrors /etc/nixos/ on the installed machine). Deploy with:
#   nixos-rebuild switch --flake ./killy#killy \
#     --target-host fred@<killy-ip> --use-remote-sudo
#
# Adding a new host:
#   1. Create <host>/iso.nix (copy killy/iso.nix and adjust all fields).
#   2. Add a nixosConfigurations.installer-<host> entry below.
#   3. Add a packages entry that extracts .config.system.build.isoImage.
#   4. Update bin/build-iso if you want `build-iso <host>` to work.
{
  description = "killy — installer images and system configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sops-nix }: let
    system = "x86_64-linux";

    # Pre-evaluate the killy target system so the ISO can embed its full store
    # closure via isoImage.storeContents, making nixos-install fully offline.
    #
    # We use the same nixpkgs + sops-nix inputs as the ISO and load the same
    # NixOS modules as killy/flake.nix, but substitute hardware.nix for
    # configuration.nix — the latter imports hardware-configuration.nix which
    # is generated at install time and is not available here.
    #
    # killy/modules/hardware.nix explicitly declares all kernel modules, CPU
    # microcode, and platform settings that nixos-generate-config would add,
    # so both evaluations (here and on the target) produce the same initrd and
    # kernel closures — Nix deduplicates them and nixos-install needs nothing
    # from the network.
    killySystem = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        sops-nix.nixosModules.sops
        ./killy/modules/hardware.nix
        ./killy/modules/base.nix
        ./killy/modules/wireguard.nix
        ./killy/modules/virt.nix
        # Stub fileSystems to satisfy the NixOS assertion that a root filesystem
        # is defined. The real entries come from hardware-configuration.nix at
        # install time; they affect only systemd mount units (thin text files),
        # not any package in the closure.
        {
          fileSystems."/" = { device = "/dev/sda"; fsType = "btrfs"; };
        }
      ];
    };
  in {
    # Build-host dev shell — provides age, sops, ykman, python3, ruff, etc.
    # Enter with:  cd ~/code/killy && nix-shell
    devShells.${system}.default =
      import ./default.nix { pkgs = nixpkgs.legacyPackages.${system}; };

    # Full NixOS configuration for the killy installer ISO.
    nixosConfigurations.installer-killy = nixpkgs.lib.nixosSystem {
      inherit system;
      # Pass the pre-built target system toplevel to iso.nix so it can be added
      # to isoImage.storeContents.
      specialArgs = {
        killyToplevel = killySystem.config.system.build.toplevel;
      };
      modules = [ ./killy/iso.nix ];
    };

    # The ISO image derivation — this is what `build-iso` (and `nix build`) builds.
    packages.${system}.installer-iso-killy =
      self.nixosConfigurations.installer-killy.config.system.build.isoImage;
  };
}
