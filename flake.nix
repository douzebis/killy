{
  description = "killy — installer image and system configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # Dev shell (mirrors default.nix for nix-shell compatibility)
    devShells.${system}.default = import ./default.nix { inherit pkgs; };

    # Installer ISO
    nixosConfigurations.installer = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ ./installer/iso.nix ];
    };

    packages.${system}.installer-iso =
      self.nixosConfigurations.installer.config.system.build.isoImage;
  };
}
