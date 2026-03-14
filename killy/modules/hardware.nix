# killy host OS — stable hardware declarations.
#
# Covers the kernel modules and CPU-specific settings that are known at
# build time. These are deliberately separated from hardware-configuration.nix
# (which is generated at install time by nixos-generate-config and contains
# filesystem UUIDs) so that the target system can be pre-built in the ISO
# without a real hardware-configuration.nix being available.
#
# Kernel modules here must be a superset of what nixos-generate-config will
# add for this machine, so that both evaluations produce the same initrd
# derivation and nixos-install can proceed fully offline.
{ lib, ... }:

{
  # Kernel modules required to boot from killy's NVMe + USB hardware.
  # Matches what nixos-generate-config produces for this machine (Intel NUC,
  # xhci + ahci + nvme controller, USB storage for the installer).
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "nvme" "usb_storage" "usbhid" "uas" "sd_mod"
  ];

  # kvm-intel: needed at runtime for libvirtd (virt.nix).
  boot.kernelModules = [ "kvm-intel" ];

  # Intel CPU — enable microcode updates.
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;

  # Explicit host platform (normally set by hardware-configuration.nix).
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
