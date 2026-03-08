# killy host OS — top-level NixOS configuration.
#
# This file is the entry point for `nixosConfigurations.killy` in flake.nix.
# It imports all host OS modules. Hardware-specific details (UUIDs, kernel
# modules) live in hardware-configuration.nix, which is regenerated during
# the spec 0005 install and must be committed before nixos-install runs.
#
# Deploy from the build host:
#   nixos-rebuild switch --flake .#killy \
#     --target-host fred@<killy-ip> --use-remote-sudo
{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./base.nix
    ./wireguard.nix
    ./virt.nix
  ];
}
