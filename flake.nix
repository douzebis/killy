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
# Adding a new host:
#   1. Create <host>/iso.nix (copy killy/iso.nix and adjust all fields).
#   2. Add a nixosConfigurations.installer-<host> entry below.
#   3. Add a packages entry that extracts .config.system.build.isoImage.
#   4. Update bin/build-iso if you want `build-iso <host>` to work.
{
  description = "killy — installer images and system configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
  in {
    # Build-host dev shell — provides age, sops, ykman, python3, ruff, etc.
    # Enter with:  cd ~/code/killy && nix-shell
    devShells.${system}.default =
      import ./default.nix { pkgs = nixpkgs.legacyPackages.${system}; };

    # Full NixOS configuration for the killy installer ISO.
    # This is an intermediate object; the actual ISO derivation is extracted
    # below via .config.system.build.isoImage.
    nixosConfigurations.installer-killy = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ ./killy/iso.nix ];
    };

    # The ISO image derivation — this is what `build-iso` (and `nix build`) builds.
    packages.${system}.installer-iso-killy =
      self.nixosConfigurations.installer-killy.config.system.build.isoImage;
  };
}
