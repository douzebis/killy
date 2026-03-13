# killy host OS — KVM/libvirt virtualisation (spec 0007).
#
# Enables QEMU/KVM with UEFI (OVMF) support. VM disk images live on the
# 2 TB data drive at /var/lib/libvirt/images/ (btrfs, CoW cloning via
# cp --reflink=always). IP forwarding is enabled so VMs can reach the
# internet via the host's wlo1.
{ pkgs, ... }:

{
  virtualisation.libvirtd = {
    enable = true;
    qemu.ovmf.enable = true;   # UEFI boot for VMs
    qemu.swtpm.enable = true;  # TPM emulation (optional, for future use)
  };

  # Allow fred to manage VMs without sudo.
  # (users.users.fred.extraGroups includes "libvirtd" — set in base.nix)

  # IP forwarding — VMs use the host as default gateway for internet access.
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

  environment.systemPackages = [ pkgs.virt-manager ];
}
