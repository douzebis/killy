# Captured from the previous killy install (2025-12) for reference.
#
# THIS FILE WILL BE REPLACED during the spec 0005 install: the clean install
# wipes and repartitions both NVMe drives (btrfs subvolumes, new UUIDs).
# After partitioning, regenerate with:
#   nixos-generate-config --root /mnt
# and commit the output here before running nixos-install.
#
# The content below reflects the old ext4 single-partition layout and is
# kept only so the repo is not missing this file before the install runs.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "usbhid" "uas" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/51a773cb-a92e-4d71-b522-7fdc18902357";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/D967-6CF3";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
