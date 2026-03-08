# 0007 — Killy VM architecture and WireGuard management

- **Status:** pending

---

## Background

Spec 0005 installs a minimal hardened NixOS host OS on killy's bare metal.
This spec defines what runs on top of it: a set of KVM virtual machines
hosting application services, and a WireGuard overlay network that makes the
host OS invisible to the public internet while keeping it manageable from the
operator's laptop.

**Prerequisite**: spec 0005 (host OS install) must be complete.

---

## Goals

1. The host OS exposes exactly one port to the internet: UDP 51820 (WireGuard).
   All other inbound traffic is silently dropped. SSH is only reachable through
   the WireGuard tunnel.
2. The operator's laptop is a permanent WireGuard peer — connection is
   automatic, no manual steps after initial setup.
3. VMs are defined declaratively in the repo as NixOS configurations, built and
   deployed with the same `nixos-rebuild` workflow as the host.
4. Each VM has its own WireGuard address and is reachable from the operator's
   laptop through the tunnel without any port forwarding.
5. Public-facing service ports (443, 25, 587, 993) are forwarded from the
   host's public interfaces to the appropriate VM.
6. VM disk images live on the 2 TB data drive; the host OS root remains on the
   512 GB OS drive.
7. A snapshot/backup strategy for VM state is defined (even if not yet fully
   implemented).

---

## Non-goals

- VM contents (mail server, web server, etc.) — covered in later specs
  (0006 and beyond).
- High availability or live migration — killy is a single machine.
- GPU passthrough or USB passthrough (not required for server workloads).

---

## Specification

### 7.1 WireGuard topology

A hub-and-spoke WireGuard network. Killy is the hub; all peers route through
it. Each peer has a `/32` address in the `10.10.0.0/24` range:

| Peer | WireGuard address | Role |
|---|---|---|
| killy host | `10.10.0.1` | Hub, routes to VMs |
| operator laptop | `10.10.0.2` | Management peer |
| mail VM | `10.10.0.10` | Guest |
| web/proxy VM | `10.10.0.11` | Guest (future) |
| (additional VMs) | `10.10.0.12+` | Guests (future) |

The operator's laptop connects to killy's public address on UDP 51820.
Once connected, the laptop can reach:
- `10.10.0.1` — killy host (SSH, management)
- `10.10.0.10` — mail VM (SSH, admin interfaces)
- Any future VMs directly by their WireGuard address

VMs do not connect directly to each other or to the internet via WireGuard —
they use the host as a default gateway for internet access (NAT via the host's
`wlo1`) and communicate with each other via their WireGuard addresses.

### 7.2 WireGuard on the host (`killy/system/wireguard.nix`)

```nix
networking.wireguard.interfaces.wg0 = {
  ips = [ "10.10.0.1/24" ];
  listenPort = 51820;
  privateKeyFile = config.sops.secrets."wireguard/host-private-key".path;

  peers = [
    {
      # Operator laptop
      publicKey = "<laptop-pubkey>";
      allowedIPs = [ "10.10.0.2/32" ];
    }
  ];
  # VM peers added here as VMs are created
};

# SSH only on WireGuard and LAN interfaces — never on public internet
services.openssh.listenAddresses = [
  { addr = "10.10.0.1"; port = 22; }
  { addr = "192.168.42.50"; port = 22; }  # LAN, for initial setup only
];

# Firewall
networking.firewall = {
  enable = true;
  allowedUDPPorts = [ 51820 ];  # WireGuard — only public port
  # SSH on wg0 and LAN handled by interface-specific rules
  interfaces.wg0.allowedTCPPorts = [ 22 ];
  interfaces.eno2.allowedTCPPorts = [ 22 ];
  interfaces.wlo1.allowedTCPPorts = [ 22 ];
};

sops.secrets."wireguard/host-private-key" = {};
```

WireGuard keys are generated at install time:
```bash
wg genkey | tee /tmp/wg-host.key | wg pubkey > /tmp/wg-host.pub
```
The private key is stored encrypted in `install-config.yaml` under
`wireguard.host_private_key` (added to `encrypted_regex`). The public key is
committed in plaintext to `killy/system/wireguard.nix`.

### 7.3 VM technology: libvirt + QEMU/KVM

NixOS's `virtualisation.libvirtd` module provides libvirt with QEMU/KVM.
VMs are defined as NixOS configurations and their disk images are managed by
libvirt's storage pools.

Alternative: `microvm.nix` (lighter, more NixOS-native). Deferred decision —
start with libvirtd as it is more conventional and better documented. Can
migrate to microvm.nix later if desired.

**Host configuration (`killy/system/virt.nix`)**:

```nix
virtualisation.libvirtd = {
  enable = true;
  qemu.ovmf.enable = true;   # UEFI for VMs
  qemu.swtpm.enable = true;  # TPM emulation if needed
};

# Allow fred to manage VMs without sudo
users.users.fred.extraGroups = [ "libvirtd" ];

# IP forwarding for VM internet access
boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
```

### 7.4 Disk layout for VMs

On `nvme1n1` (2 TB data drive):

| Path | Size | Content |
|---|---|---|
| `/var/lib/libvirt/images/` | ~1.8 TiB | VM disk images (libvirt default pool) |
| `/srv/backups/` | ~100 GiB | Restic backup staging area |

`/var/lib/libvirt/images/` sits on `nvme1n1p1` (btrfs). VM disk images are
stored as raw files (not qcow2) for performance on NVMe — btrfs CoW provides
the snapshot capability that qcow2 would otherwise offer.

To create a new VM disk image from a base:
```bash
# Instantaneous, space-efficient CoW clone
cp --reflink=always /var/lib/libvirt/images/base-nixos.raw \
                    /var/lib/libvirt/images/mail.raw
```

### 7.5 VM resource allocation

Initial allocation with 32 GiB RAM and 16 threads:

| VM | vCPUs | RAM | Disk |
|---|---|---|---|
| mail | 2 | 2 GiB | 40 GiB |
| (future: web/proxy) | 2 | 1 GiB | 20 GiB |
| (future: keycloak) | 2 | 3 GiB | 20 GiB |
| Host OS overhead | — | ~2 GiB | — |
| Available headroom | 10 threads | ~27 GiB | — |

With 64 GiB RAM (after replacing both DIMMs with 2 × 32 GB sticks), headroom
grows to ~59 GiB — comfortable for additional VMs.

### 7.6 Port forwarding for public services

The host forwards public-facing ports to the appropriate VM via nftables:

```
internet → killy:443  → mail VM:443   (HTTPS, SNI proxy or direct)
internet → killy:25   → mail VM:25    (SMTP inbound, IPv6)
internet → killy:587  → mail VM:587   (Submission)
internet → killy:993  → mail VM:993   (IMAPS)
```

On IPv6, forwarding is direct (no NAT) — the host forwards packets destined
for `2001:41d0:fc28:400:edd:24ff:fe75:3dca` to the mail VM's internal
address. On IPv4, standard DNAT via nftables.

These rules are added to the host firewall config when each VM is set up, not
in this spec.

### 7.7 Snapshot and backup strategy (outline)

- **btrfs snapshots** of `/var/lib/libvirt/images/` taken before VM
  configuration changes — instant, space-efficient.
- **Restic** backs up VM disk images (or selected directories exported from
  VMs) to the OVH `atlantis` S3 bucket, staged via `/srv/backups/`.
- Frequency and retention policy: deferred to implementation. Start with
  daily snapshots, 7-day retention.

The exact design (snapshot whole images vs. mount and extract data) depends
on VM filesystem and service — defined per-VM in later specs.

---

## Implementation order

1. Complete spec 0005 (host OS install, VT-x/VT-d enabled).
2. Configure WireGuard on host; configure peer on operator laptop; verify
   tunnel connects and SSH works through it.
3. Enable libvirtd; create libvirt storage pool on `nvme1n1p1`.
4. Build and launch the first VM (mail, spec 0006) as a NixOS guest.
5. Configure port forwarding for mail ports.
6. Establish backup schedule.

---

## Open questions

1. **libvirtd vs. microvm.nix**: microvm.nix is more NixOS-native and
   lighter (no libvirt daemon), but less conventional. Decision deferred —
   libvirtd is the default here.

2. **VM networking**: libvirt's default NAT bridge (`virbr0`) gives VMs
   internet access via the host, but VMs are not directly reachable from the
   LAN. WireGuard addresses are the management path. Port forwarding handles
   public services. This is the intended design.

3. **Operator laptop WireGuard config**: the laptop-side WireGuard
   configuration (keys, endpoint, allowed IPs) is out of scope for this repo
   but must be set up before the tunnel can be used. Document in
   `docs/user-guide.md` during implementation.
