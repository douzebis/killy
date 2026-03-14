{ ... }: {
  imports = [
    # Stable hardware declarations (kernel modules, CPU, platform).
    # See modules/hardware.nix — deliberately separated so the system can be
    # pre-built in the ISO without a live hardware-configuration.nix.
    ./modules/hardware.nix
    # Generated at install time by nixos-generate-config; provides fileSystems
    # and swapDevices (UUID-specific). Not available at ISO build time.
    ./hardware-configuration.nix
  ];
}
