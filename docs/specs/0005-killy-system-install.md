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
`lsblk --json --bytes`, prompts the operator to select and confirm the OS and
data drives, and populates the `install:` section of `install-config.yaml`
with device paths, models, minimum sizes, partition layout, filesystem options,
and btrfs subvolume definitions. Re-encrypts the file via SOPS. Run once
before the first install (or when the disk configuration changes).

#### `bin/install` (headless installer, runs on killy)

A Python script placed on PATH inside the installer ISO (via `/etc/nixos/bin/`).
The operator types `install` at the nixos shell to start it — it does not run
automatically, providing a safety gate. Steps:

1. **Validate drives** — reads `install.disks` from `install-config.yaml` via
   SOPS and checks that each configured device matches the expected model
   (substring) and meets the minimum size. Aborts with a clear error if the
   drives don't match; no disk writes occur until validation passes.

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

8. **Copy repo** (excluding `motoko/`, `attic/`) to `/mnt/etc/nixos`.

9. **Install NixOS**:
   ```bash
   nixos-install --root /mnt --no-root-passwd --flake /mnt/etc/nixos#killy
   ```

10. **Unmount and reboot**.

### 5.3 NixOS configuration: `killy/system/`

A new directory `killy/system/` holds the installed system's NixOS modules:

```
killy/system/
  default.nix              — imports all modules; nixosConfigurations.killy entry
  hardware-configuration.nix — generated by nixos-generate-config (step 4)
  base.nix                 — hostname, users, SSH, networking, sops-nix
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

- **Headless install via `bin/install`**: the spec described a bash script
  `bin/killy-install` invoked over SSH. The implementation uses a Python script
  named `install` placed on PATH in the installer ISO. The operator boots the
  ISO, logs into the nixos shell, and types `install` to proceed. This is safer
  than auto-running and more ergonomic than SSHing to invoke a script.

- **Disk spec in `install-config.yaml`**: all disk parameters (device path,
  model, minimum size, partition layout, filesystem, subvolumes) are stored
  under `install.disks` in `install-config.yaml` and populated by the
  `bin/killy-setup` wizard. The install script validates actual hardware against
  this spec before making any changes.

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
