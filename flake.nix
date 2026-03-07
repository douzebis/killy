{
  description = "killy — installer images and system configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
  in {
    # Build-host dev shell
    devShells.${system}.default =
      import ./default.nix { pkgs = nixpkgs.legacyPackages.${system}; };

    # killy installer ISO
    nixosConfigurations.installer-killy = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ ./killy/iso.nix ];
    };

    packages.${system}.installer-iso-killy =
      self.nixosConfigurations.installer-killy.config.system.build.isoImage;
  };
}
