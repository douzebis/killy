# 0005 — Killy NixOS disk installation

- **Status:** implemented
- **Implemented in:** 2026-03-08

---

## Background

Specs 0001–0003 cover the installer ISO: a live boot environment that unwraps
the age key from the Yubikey, connects to WiFi, and exposes a SOPS-capable
shell over SSH. The ISO deliberately stops short of writing to disk (spec 0002
non-goals: "partitioning, formatting, or writing to the target disk").

This spec covers the next step: installing a permanent NixOS system on killy's
disk. The installer ISO is the execution environment; this spec defines what
gets written to disk and how.

The installed system is a **minimal hardened host OS** whose sole purpose is
to run KVM virtual machines and provide WireGuard-based management access. No
application services run on bare metal. See spec 0007 for the VM architecture
and spec 0006 for the mail server VM.

---

## Goals

1. From the installer ISO (booted, Yubikey present, SSH accessible), run a
   single install script that:
   a. Partitions and formats killy's disk.
   b. Generates the host SSH key and derives the host age key from it.
   c. Decrypts secrets from `install-config.yaml` using the install key and
      re-encrypts them for the new host key (via `sops updatekeys`).
   d. Installs a minimal NixOS base system to disk.
   e. On first boot, the system is reachable via SSH and ready for further
      NixOS configuration.

2. The installed system has:
   - A stable IPv4 LAN address (static DHCP lease assigned on router for
     killy's WiFi MAC `0c:dd:24:75:3d:ca`).
   - A pinned EUI-64 IPv6 address (`2001:41d0:fc28:400:edd:24ff:fe75:3dca`),
     with privacy extensions disabled.
   - WireGuard running as the primary management interface — the only port
     exposed to the internet. SSH bound to the WireGuard interface only,
     invisible from the public internet.
   - KVM/QEMU available for hosting virtual machines.
   - SOPS secrets decryptable with the host age key.
   - `sops-nix` available for secret injection at activation time.

3. The NixOS configuration for killy lives in the repo under `killy/system/`
   and is built/deployed from the build host via `nixos-rebuild` over SSH
   (through the WireGuard tunnel once it is established; directly over LAN
   during initial setup).

---

## Non-goals

- Application services (mail, web) — run inside VMs, covered in later specs.
- VM definitions and WireGuard mesh — covered in spec 0007.
- Full automation of the install (unattended, no operator present) — the
  operator must be present to plug in the Yubikey and confirm partitioning.
- Handling RAID or LVM.
- Preserving any data from the previous install on `nvme0n1` — this is a
  clean wipe.
- BIOS configuration — VT-x and VT-d must be enabled manually before running
  this spec (reboot into UEFI setup, enable "Intel Virtualization Technology"
  and "Intel VT-d").

---

## Specification

### 5.1 Disk layout

Killy has two NVMe drives:

- **`/dev/nvme0n1`** — 512 GB Intel SSDPEKKW512G8 — OS drive
- **`/dev/nvme1n1`** — 2 TB Intel SSDPEKKW020T8 — data drive

Both are wiped and partitioned from scratch. The previous contents of
`nvme0n1` (an earlier NixOS install) are discarded; `nvme1n1` was unformatted.

#### OS drive: `nvme0n1`

GPT partition table, two partitions:

| Partition | Device | Size | Type | Mount | Filesystem |
|---|---|---|---|---|---|
| 1 | `nvme0n1p1` | 1 GiB | EFI System | `/boot` | FAT32 |
| 2 | `nvme0n1p2` | remainder (~511 GiB) | Linux | `/` | btrfs |

**Why btrfs for root:**
- Transparent compression (`zstd`) reduces NixOS store I/O and saves space;
  the nix store contains many compressible text files.
- Subvolumes allow clean separation of rollback-sensitive trees (`@` for `/`,
  `@nix` for `/nix`) from state that should survive rollbacks (`@home`,
  `@log`).
- Snapshots: before each `nixos-rebuild switch`, a snapshot of `@` can be
  taken, enabling boot-time rollback to the previous generation independently
  of the NixOS boot menu.
- Native to the Linux kernel; well-supported in NixOS.

**Btrfs subvolume layout:**

| Subvolume | Mount point | Notes |
|---|---|---|
| `@` | `/` | Root — rolled back on system updates |
| `@nix` | `/nix` | Nix store — large, exclude from root snapshots |
| `@home` | `/home` | User data — persists across rollbacks |
| `@log` | `/var/log` | Logs — persists across rollbacks |

Mount options for all subvolumes: `compress=zstd,noatime`.

**Why 1 GiB for `/boot`:** the EFI partition holds kernels and initrds for
multiple NixOS generations. NixOS keeps the last N generations by default
(typically 5–10); each kernel + initrd pair is ~100–150 MiB, so 1 GiB gives
comfortable headroom. 512 MiB (the previous install's size) is tight with
btrfs compression inactive on FAT32.

#### Data drive: `nvme1n1`

GPT partition table, two partitions:

| Partition | Device | Size | Type | Mount | Filesystem |
|---|---|---|---|---|---|
| 1 | `nvme1n1p1` | 100 GiB | Linux | `/srv` | btrfs |
| 2 | `nvme1n1p2` | remainder (~1.8 TiB) | Linux | `/var/mail` | btrfs |

`/srv` holds application data other than mail (future services). `/var/mail`
holds the Postfix mail spool and Dovecot mailboxes; this is the path Restic
backs up to OVH S3.

Both partitions use btrfs with `compress=zstd,noatime`. No subvolumes needed
on the data drive initially — add them if snapshotting requirements emerge.

**No swap partition:** killy has 32 GiB RAM. Swap-on-zram can be enabled via
`zramSwap.enable = true` in NixOS if ever needed, with no disk partition
required.

### 5.2 Install scripts

Two scripts handle the install workflow:

#### `bin/killy-setup` (wizard, runs on build host)

SSHes into the live installer, enumerates non-USB block devices via
`lsblk --json --bytes`, auto-selects drives (smallest = OS, largest = data),
and resolves the PCI slot for each via sysfs (`readlink /sys/block/<name>`).
Populates the `install:` section of `install-config.yaml` with `pci_slot`,
`model`, `size_gb`, partition layout, filesystem options, and btrfs subvolume
definitions. Re-encrypts the file via SOPS. No interactive prompts — the
proposal is written unconditionally and printed for operator review. Run once
before the first install (or when the disk configuration changes).

#### `installer/bin/killy-install` (headless installer, runs on killy)

A Python script embedded in the installer ISO and placed on PATH via
`loginShellInit`. The operator types `sudo killy-install` at the nixos shell
to start it — it does not run automatically. Steps:

1. **Find drives** — reads `install.disks` from `install-config.yaml` via
   SOPS. For each disk spec, locates the drive by exact PCI slot match (via
   sysfs), then verifies model and size_gb exactly. Aborts with a clear error
   if the slot is not found (drive moved — re-run `killy-setup`) or if model
   or size do not match. No disk writes occur until all drives are verified.

2. **Partition and format `nvme0n1` (OS drive)**:
   - GPT, EFI partition (FAT32, 1 GiB), btrfs root (remainder)

3. **Create btrfs subvolumes** (`@`, `@nix`, `@home`, `@log`) and mount them
   at `/mnt` with `compress=zstd,noatime`.

4. **Partition and format `nvme1n1` (data drive)**:
   - GPT, btrfs `/srv` (100 GiB) and btrfs `/var/mail` (remainder)

5. **Generate NixOS hardware config** via `nixos-generate-config --root /mnt`.

6. **Generate SSH host key**:
   ```bash
   ssh-keygen -t ed25519 -N "" -f /mnt/etc/ssh/ssh_host_ed25519_key
   ```

7. **Derive host age public key** from the SSH host key via `ssh-to-age`,
   update `.sops.yaml` in the overlayfs, and run `sops updatekeys` on
   `install-config.yaml` using the Yubikey install key. This makes the
   secrets file decryptable by the installed system on first boot.

8. **Copy repo from ISO** to `/mnt/etc/nixos` — the ISO embeds the full
   set of files needed by `nixos-install`: `flake.nix`, `flake.lock`,
   `killy/system/`, `installer/`, `scripts/`, `.sops.yaml`. The live
   `install-config.yaml` (re-encrypted in step 7) and `hardware-configuration.nix`
   (generated in step 5) are placed into the correct locations.

9. **Install NixOS**:
   ```bash
   nixos-install --root /mnt --no-root-passwd --flake /mnt/etc/nixos#killy
   ```

10. **Unmount and reboot**.

### 5.3 NixOS configuration: `killy/system/`

`killy/system/` holds the installed system's NixOS modules:

```
killy/system/
  default.nix              — imports all modules; nixosConfigurations.killy entry
  hardware-configuration.nix — generated by killy-install (NOT in git; .gitignored)
  base.nix                 — hostname, users, SSH, networking, sops-nix
  wireguard.nix            — WireGuard interface and peer config
  virt.nix                 — KVM/libvirt
```

`base.nix` covers:

- **Hostname**: `killy`
- **Users**: `fred` (normal user, wheel, SSH authorized keys from
  `install-config.yaml`)
- **SSH**: key-only auth, no passwords, bound to WireGuard interface only
  (not exposed on public interfaces)
- **IPv6 address pinning** (disables privacy extensions):
  ```nix
  networking.interfaces.wlo1.ipv6.addresses = [{
    address = "2001:41d0:fc28:400:edd:24ff:fe75:3dca";
    prefixLength = 64;
  }];
  networking.tempAddresses = "disabled";
  ```
- **WireGuard**: single peer (build host / operator laptop). The WireGuard
  interface (`wg0`) is the only management entry point. UDP 51820 is the only
  port open to the internet. All other inbound traffic is dropped silently.
  WireGuard keys generated at install time and stored via sops-nix.
- **KVM/QEMU**:
  ```nix
  virtualisation.libvirtd.enable = true;
  users.users.fred.extraGroups = [ "libvirtd" ];
  ```
  Requires VT-x and VT-d enabled in BIOS (pre-requisite).
- **sops-nix**: configured to use the host SSH key as the age key source:
  ```nix
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.defaultSopsFile = ./install-config.yaml;
  ```
- **Firewall**: default deny inbound. Only UDP 51820 (WireGuard) open
  externally. VM service ports (25, 443, 587, 993) opened separately when
  VMs are configured (spec 0007).

### 5.4 Deployment after install

Once the system is installed and running, configuration changes are applied
from the build host:

```bash
nixos-rebuild switch --flake .#killy --target-host fred@<killy-ip> --use-remote-sudo
```

No need to touch the USB key again for config changes — only for full
reinstalls.

---

## Prerequisites (manual steps before running the install script)

1. **Enable VT-x and VT-d in BIOS**: reboot killy, enter UEFI setup
   (Delete key), enable "Intel Virtualization Technology" (VT-x) and
   "Intel VT-d" under the CPU or Advanced menu. Without this, KVM will not
   load and libvirtd will fail to start.

2. **Static DHCP lease on router**: bind killy's WiFi MAC
   `0c:dd:24:75:3d:ca` to a fixed LAN IPv4 (e.g. `192.168.42.50`) in the
   router's DHCP settings. Done — confirmed assigned.

## Implementation notes

### Deviations from spec

- **Headless install via `installer/bin/killy-install`**: the script is embedded
  in the installer ISO and placed on PATH via `loginShellInit`. The operator
  runs `sudo killy-install` — no auto-run. Named `killy-install` (not `install`)
  to avoid shadowing the standard Unix `install` utility, which `nixos-install`
  uses internally.

- **Disk identification by PCI slot + exact model + size**: drives are identified
  by PCI slot (primary key, read from sysfs), with model and size_gb verified
  exactly. This survives kernel NVMe index reordering across reboots and catches
  drive swaps or replacements early, before any disk writes.

- **Disk spec in `install-config.yaml`**: all disk parameters (`pci_slot`,
  `model`, `size_gb`, partition layout, filesystem, subvolumes) are stored
  under `install.disks` in `install-config.yaml` and populated by the
  `bin/killy-setup` wizard. No interactive prompts — the wizard auto-selects
  drives and writes the proposal unconditionally.

- **ISO is fully self-contained**: the installer does not require network access
  to the build host. `flake.nix`, `flake.lock`, and all of `killy/system/` are
  embedded in the ISO. `hardware-configuration.nix` is the only file not
  embedded — it is generated fresh by `nixos-generate-config` and placed into
  `killy/system/` before `nixos-install` runs. It is `.gitignored` and never
  committed.

- **SSH `listenAddresses` not used**: the spec described SSH bound to the
  WireGuard interface only. On the installed system, sshd listens on all
  interfaces (`0.0.0.0`/`::`); the firewall restricts SSH to `wlo1` (LAN) and
  `wg0` (WireGuard). This avoids hardcoding the LAN IP and handles the case
  before WireGuard is established.

- **WiFi PSK via `networking.wireless.secretsFile`**: the installed system uses
  `networking.wireless` with `secretsFile` pointing to the sops-nix secret
  `system/wifi_key`. The secret value is stored as `wifi_key=<psk>` (key=value
  format required by wpa_supplicant). The `@wifi_key@` placeholder in the
  network PSK is substituted at activation time.

- **`system.*` section in `install-config.yaml`**: installer credentials
  (`installer.*`) are kept separate from installed system credentials
  (`system.*`). The installed system uses `system/wifi_key`,
  `system/hashed_password`, and `wireguard/host_private_key`; it does not
  reference any `installer.*` key.

- **`sops updatekeys` runs on-device**: the build host cannot re-encrypt for
  the new host key (it doesn't hold the new private key). The install script
  runs `sops updatekeys` on killy using the Yubikey install key, which is a
  registered recipient. The updated `install-config.yaml` is then copied into
  `/mnt/etc/nixos` before `nixos-install`.

- **Overlayfs on `/etc/nixos`**: the installer ISO mounts a writable overlayfs
  over the read-only `/etc/nixos` squashfs at boot. This allows the install
  script to modify `.sops.yaml` and `install-config.yaml` in place without
  reflashing the USB key.

- **Static DHCP lease**: the router assigns `192.168.42.44` to killy's WiFi
  MAC `0c:dd:24:75:3d:ca`. This is not hardcoded in the NixOS config; SSH
  and firewall use interface names, not IP addresses.
