# killy — operator user guide

This guide covers the day-to-day operations and one-time setup tasks for the
killy installation. It assumes the build host is already running NixOS with the
repo checked out and the `nix-shell` dev environment available.

---

## Build host setup

### USB devices passed through to the `experiment` VM

The following USB devices are attached to the build host and passed through
to the `experiment` VM via libvirt:

| Device | Vendor:Product | Purpose |
|---|---|---|
| Yubico YubiKey 5 NFC (serial 32283437) | `1050:0407` | Install key unwrapping (PIV slot RETIRED2, `CN=killy-install-key`) |
| Lexar USB Flash Drive | `21c4:0809` | Installer key — write ISO here, boot killy from it |
| FTDI FT232 Serial (UART) | `0403:6001` | Null-modem USB-serial cable to killy's serial console |

The FT232 adapter appears as `/dev/ttyUSB0` inside the VM. Connect to
killy's serial console with:

```bash
screen /dev/ttyUSB0 115200
# or: minicom -D /dev/ttyUSB0 -b 115200
```

The `experiment` user is in the `dialout` group so no `sudo` is needed.

The Lexar drive appears as `/dev/sda` inside the VM (confirm with `lsblk`
before writing the ISO — device assignment can change if other USB storage
is present).

### Libvirt XML for the `experiment` VM (persistent config)

The three `<hostdev>` entries in the domain XML (`sudo virsh edit experiment`
on the build host):

```xml
<!-- Yubikey -->
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source startupPolicy='optional'>
    <vendor id='0x1050'/>
    <product id='0x0407'/>
  </source>
</hostdev>

<!-- Lexar USB Flash Drive (installer key) -->
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source startupPolicy='optional'>
    <vendor id='0x21c4'/>
    <product id='0x0809'/>
  </source>
</hostdev>

<!-- FTDI FT232 (null-modem serial to killy) -->
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source startupPolicy='optional'>
    <vendor id='0x0403'/>
    <product id='0x6001'/>
  </source>
</hostdev>
```

All three use `managed='yes'` (libvirt unbinds host drivers automatically
before passthrough and rebinds on VM shutdown) and `startupPolicy='optional'`
(VM starts even if a device is absent). Vendor/product matching is used
rather than bus/device address, so entries survive replug and reboot without
going stale.

### Adding a new USB device to the VM

1. On the build host, identify the device vendor/product ID:
   ```bash
   lsusb
   # e.g. Bus 003 Device 009: ID 0403:6001 Future Technology Devices ...
   #                              ^^^^ ^^^^
   #                              vendor product
   ```

2. Attach it to the running VM and persist the config:
   ```bash
   sudo virsh attach-device experiment --config --live /dev/stdin <<'EOF'
   <hostdev mode='subsystem' type='usb' managed='yes'>
     <source startupPolicy='optional'>
       <vendor id='0xVVVV'/>
       <product id='0xPPPP'/>
     </source>
   </hostdev>
   EOF
   ```
   Replace `0xVVVV` and `0xPPPP` with the vendor and product IDs.
   `--config` persists across VM reboots; `--live` applies immediately.

3. Verify inside the VM:
   ```bash
   nix-shell -p usbutils --run lsusb
   ```

### Removing a USB device from the VM

Edit the XML directly to avoid matching issues with libvirt:
```bash
sudo virsh edit experiment
# Find and delete the relevant <hostdev> block, save and quit.
```

To also hot-remove from the running VM, note the full block including
`<alias>` and outer `<address>` from `sudo virsh dumpxml experiment`, then:
```bash
sudo virsh detach-device experiment --live /dev/stdin <<'EOF'
<hostdev ...>...</hostdev>
EOF
```

---

## Prerequisites

The `experiment` VM user has no password and passwordless `sudo`. No
credentials are needed for local login or privilege escalation.

Enter the dev shell before running any script or SOPS command:

```bash
cd ~/code/killy
nix-shell        # or: nix-shell --run bash
```

The dev shell provides: `age`, `ssh-to-age`, `sops`, `yubikey-manager`,
`yubico-piv-tool`, `python3`, `cryptography`, `ruff`, `openssl`, `jq`.

---

## Secrets management

Secrets live in `killy/install-config.yaml`, encrypted with SOPS/age.

Three recipients are registered in `.sops.yaml`:

| Recipient | Key | When used |
|---|---|---|
| Host key | Derived from SSH host ed25519 key via `ssh-to-age` | Runtime (on killy) |
| Operator key | `~/.config/sops/age/keys.txt` on build host | Day-to-day editing |
| Install key | Yubikey PIV slot 0x9d, unwrapped via `yk-unwrap.py` | Autonomous install |

### Decrypt a secrets file (day-to-day)

The operator key in `~/.config/sops/age/keys.txt` is picked up automatically:

```bash
sops decrypt killy/install-config.yaml
```

### Edit a secrets file

```bash
sops edit killy/install-config.yaml
```

Always run this from the repo root (`~/code/killy`) so that SOPS finds
`.sops.yaml` and its path regex matches. The file is decrypted to a temp
file, opened in `$EDITOR`, and re-encrypted on save.

**Non-interactive edits** (e.g. from a script): decrypt, modify, then
encrypt in-place at the original path — do not encrypt from a `/tmp/` path,
as the path regex in `.sops.yaml` will not match:

```bash
sops decrypt killy/install-config.yaml > /tmp/ic.yaml
# ... modify /tmp/ic.yaml ...
cp /tmp/ic.yaml killy/install-config.yaml
sops encrypt --in-place killy/install-config.yaml
rm /tmp/ic.yaml
```

### Decrypt using the Yubikey (install key)

Plug in the Yubikey, then:

```bash
SOPS_AGE_KEY=$(python3 scripts/yk-unwrap.py --hostname killy \
                 killy/wrapped-install-key.bin) \
  sops decrypt killy/install-config.yaml
```

No PIN is required — the install slot uses `PIN_POLICY=NEVER` for unattended
operation. The age private key lives only in the environment variable — in RAM,
never on disk.

---

## Yubikey scripts

### `scripts/yk-setup.py` — one-time setup per Yubikey

Run once when setting up a new Yubikey (or to rotate the install key):

```bash
# 1. Generate a fresh age install key in a private temp directory
mkdir -m 700 /tmp/yk-setup
age-keygen -o /tmp/yk-setup/install.key

# 2. Find or create the install slot and wrap the age key.
#    Prints the age public key to stdout.
python3 scripts/yk-setup.py \
  --hostname killy \
  --age-key /tmp/yk-setup/install.key \
  --out killy/wrapped-install-key.bin

# 3. Securely delete the plaintext age key
shred -u /tmp/yk-setup/install.key && rmdir /tmp/yk-setup
```

The printed age public key must be recorded in `.sops.yaml` under
`creation_rules[].age`, then `sops updatekeys` must be run on the secrets
file to add the install key as a recipient (see below).

**What it does internally:**
- Scans PIV retired slots (0x82–0x95) for `CN=killy-install-key`.
- If found and `--force` not set: reuses that slot's existing key.
- If not found: picks the first free retired slot, generates a P-256 key
  on-device with `PIN_POLICY=NEVER` and `TOUCH_POLICY=NEVER`, stores a
  self-signed certificate with `CN=killy-install-key` as a label.
- Performs ECDH between an ephemeral software key pair and the slot's public key.
- Derives a 32-byte AES key via HKDF-SHA256 (`info=b"killy-install"`).
- Encrypts the age key with AES-256-GCM and writes:
  `ephemeral_pubkey(65 bytes) || nonce(12 bytes) || ciphertext+tag`
  to `killy/wrapped-install-key.bin`.

**Trade-off:** `PIN_POLICY=NEVER` means the Yubikey will unwrap the install
key with no PIN. Physical possession of both the Yubikey and the installer
image is the sole protection. The two objects should be stored and transported
separately.

**Requirements:** Yubikey plugged in, pcscd running (managed by systemd —
do not start pcscd manually).

---

### `scripts/yk-unwrap.py` — unwrap at install time

```bash
python3 scripts/yk-unwrap.py --hostname killy killy/wrapped-install-key.bin
```

Scans retired slots for `CN=killy-install-key`, performs ECDH on-device
without PIN, and prints the plaintext age key to stdout. No TTY required —
safe to call from scripts and systemd units.

**Typical use — decrypt a SOPS file:**

```bash
SOPS_AGE_KEY=$(python3 scripts/yk-unwrap.py --hostname killy \
                 killy/wrapped-install-key.bin) \
  sops decrypt killy/install-config.yaml
```

**Re-derive the install key's age public key** (e.g. after losing track of it):

```bash
python3 scripts/yk-unwrap.py --hostname killy \
  killy/wrapped-install-key.bin | age-keygen -y
```

---

## Adding a new Yubikey (or replacing the install key)

If the Yubikey is lost, replaced, or the install slot is compromised:

1. Run `yk-setup.py --force` to regenerate the on-device key and wrap a new
   age key (see the script section above).
2. Update `.sops.yaml` with the new age public key (replace the old one under
   `# install key`).
3. Re-encrypt the secrets file for the new recipient (operator key authorizes
   this — no Yubikey needed):
   ```bash
   sops updatekeys killy/install-config.yaml
   ```
4. Commit `killy/wrapped-install-key.bin`, `.sops.yaml`, and the updated
   secrets file.

No secrets are lost: the secrets file remains decryptable via the operator key
throughout.

---

## Yubikey troubleshooting

### "No YubiKey detected" from ykman

First check that pcscd is not holding stale processes:

```bash
pgrep -a pcscd     # should show at most one process, or none
ykman list         # triggers socket-activated pcscd
```

If multiple pcscd processes are running (leftover from manual debugging):

```bash
sudo kill $(pgrep pcscd)
sleep 1
sudo rm -f /run/pcscd/pcscd.comm
ykman list
```

Never start pcscd manually. The systemd unit manages it correctly via socket
activation with `--auto-exit`. See `docs/yubikey-vm-passthrough.md` for full
diagnosis notes (VM-specific, but the pcscd section applies generally).

### PIN

The install slot uses `PIN_POLICY=NEVER` — no PIN is required for unwrapping.
The PIV PIN is not used by `yk-unwrap.py`.

If you use other PIV slots on the same Yubikey (e.g. for SSH auth), the
default PIN is `123456` and should be changed:

```bash
ykman piv access change-pin
```

---

## Operator key setup (build host, one-time)

The operator key enables day-to-day secrets editing without the Yubikey. It
is derived from the build host's SSH host key:

```bash
# Derive the age key from the SSH host key
sudo ssh-to-age -private-key \
  < /etc/ssh/ssh_host_ed25519_key \
  >> ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Verify that SOPS can decrypt:

```bash
sops decrypt killy/install-config.yaml | head -3
```

---

## WireGuard keys

### Overview

Two WireGuard peers are pre-provisioned:

| Peer | WireGuard address | Private key location |
|---|---|---|
| killy host | `10.10.0.1` | `install-config.yaml` → `wireguard.host_private_key` (encrypted) |
| operator laptop | `10.10.0.2` | `install-config.yaml` → `wireguard.laptop_private_key` (encrypted) |

Public keys are stored in plaintext in `killy/system/wireguard.nix` (host)
and in the laptop's WireGuard config (see §"Laptop WireGuard config" below).

### Generating new keys (one-time, or on rotation)

```bash
cd ~/code/killy
nix-shell
# Generate host key pair
wg genkey | tee /tmp/wg-host.key | wg pubkey > /tmp/wg-host.pub
# Generate laptop key pair
wg genkey | tee /tmp/wg-laptop.key | wg pubkey > /tmp/wg-laptop.pub

cat /tmp/wg-host.pub    # → paste into killy/system/wireguard.nix as hosts's publicKey
cat /tmp/wg-laptop.pub  # → paste into killy/system/wireguard.nix as laptop peer's publicKey
```

Store the private keys in `install-config.yaml`:

```bash
sops decrypt killy/install-config.yaml > /tmp/ic.yaml
# Edit /tmp/ic.yaml: add or update the wireguard block:
#   wireguard:
#       host_private_key: <content of /tmp/wg-host.key>
#       laptop_private_key: <content of /tmp/wg-laptop.key>
cp /tmp/ic.yaml killy/install-config.yaml
sops encrypt --in-place killy/install-config.yaml
rm /tmp/ic.yaml /tmp/wg-host.key /tmp/wg-laptop.key /tmp/wg-host.pub /tmp/wg-laptop.pub
```

The `encrypted_regex` in `.sops.yaml` covers `host_private_key` and
`laptop_private_key` — both are encrypted at rest.

**Current public keys** (generated 2026-03-08):

| Peer | Public key |
|---|---|
| killy host | `cymg6tTmwttS1JgypXaTWWsHwa9le7dkQo4axiu77Ec=` |
| operator laptop | `wHD2oVuTC58x9xjZqDfl95RiuPGk31nRSaBjo7+Hjnw=` |

### Laptop WireGuard config

Once the killy host is installed and running, configure WireGuard on the
operator laptop (`/etc/wireguard/wg0.conf` or equivalent):

```ini
[Interface]
PrivateKey = <laptop_private_key from install-config.yaml>
Address = 10.10.0.2/24

[Peer]
PublicKey = cymg6tTmwttS1JgypXaTWWsHwa9le7dkQo4axiu77Ec=
Endpoint = 2001:41d0:fc28:400:edd:24ff:fe75:3dca:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
```

On NixOS, place this in `networking.wireguard.interfaces.wg0` (see
spec 0007 for the full module).

---

## Installer ISO

### Building the ISO

```bash
cd ~/code/killy
nix-shell
build-iso          # builds .#installer-iso-killy, result -> ./result/
```

`build-iso` is in `bin/` which is on PATH inside the nix-shell.

### Writing to the Lexar USB drive

The Lexar must be attached to the `experiment` VM (see USB passthrough above).
Confirm the device, then write:

```bash
lsblk -o NAME,SIZE,LABEL,VENDOR,TRAN   # confirm sda is the Lexar
ISO=$(nix --extra-experimental-features "nix-command flakes" \
      build .#installer-iso-killy --no-link --print-out-paths)
sudo dd if="$(ls $ISO/iso/*.iso)" of=/dev/sda bs=4M status=progress conv=fsync
```

### Boot sequence

1. Insert Lexar USB + ensure Yubikey (serial 17688887) is plugged into killy.
2. Boot killy from the Lexar.
3. On boot, automatically:
   - `yk-unwrap.service` — unwraps the age install key from the Yubikey, writes
     it to `/run/age-install-key` (mode 0600). Retries every 2 s if the Yubikey
     is not ready.
   - `installer-network.service` — decrypts WiFi credentials from
     `install-config.yaml`, connects to WiFi via `wpa_cli`, waits for DHCP.
   - `sshd` — starts automatically; the build host SSH key is baked into the
     ISO, so `ssh nixos@<ip>` works from the build host without a password.
   - Login shells get `SOPS_AGE_KEY` exported automatically (via `loginShellInit` in `installer/base.nix`).

### Connecting via serial console

The FT232 adapter must be attached to the `experiment` VM. Use the helper:

```bash
bin/killy-serial "some command" [wait_seconds]
bin/killy-serial -r    # restart the background reader/buffer
```

The background reader buffers all serial output to `/tmp/killy-buf` and
persists across calls. Started automatically on first use.

Note: `serial-getty@ttyUSB0` starts at boot if the FT232 is already plugged
into killy. If not, plug it in after boot and run:
```bash
sudo systemctl start serial-getty@ttyUSB0
```

### Connecting via SSH

Once the installer-network service succeeds, find killy's IP via serial:

```bash
bin/killy-serial "ip addr show wlo1 | grep 'inet '"
```

Then SSH from the build host:

```bash
ssh nixos@192.168.42.xx   # no password needed — build host key is in the ISO
```

`SOPS_AGE_KEY` is set in the session. You can immediately decrypt secrets:

```bash
sops decrypt /etc/nixos/killy/install-config.yaml
```

### Troubleshooting the installer

**yk-unwrap retrying indefinitely:**
```bash
journalctl -u yk-unwrap --no-pager -n 20
```
Check that pcscd is active and the Yubikey is recognized:
```bash
systemctl status pcscd
ykman list
```

**installer-network failed:**
```bash
journalctl -u installer-network --no-pager -n 20
wpa_cli -i wlo1 status
```

**SSH auth failure (password):** SSH with a password is unreliable on the
installer ISO due to PAM constraints. Use key-based auth — the build host
SSH key is embedded in the ISO (see `installer/base.nix`).

### Installation procedure (spec 0005)

#### Prerequisites

- VT-x and VT-d enabled in BIOS (enter setup with Delete key at boot).
- Static DHCP lease for killy's WiFi MAC `0c:dd:24:75:3d:ca` configured
  on the router — assigned `192.168.42.44`.
- Yubikey (serial 17688887) plugged into killy.
- Lexar USB flashed with the latest ISO and booted (see above).
- SSH accessible from the build host (`ssh nixos@192.168.42.44`).

#### Step 1 — Populate the disk spec (first install only)

Run the setup wizard from the build host. It SSHes into the installer,
enumerates the drives, and populates `install.disks` in `install-config.yaml`:

```bash
cd ~/code/killy
nix-shell
bin/killy-setup 192.168.42.44
```

Follow the prompts to select the OS drive (`nvme0n1`) and data drive
(`nvme1n1`). The wizard writes and re-encrypts `install-config.yaml`
automatically. Skip this step on reinstalls if the disk configuration is
unchanged.

#### Step 2 — Run the installer

SSH into the live installer and type `install`:

```bash
ssh nixos@192.168.42.44
install
```

The script validates that the physical drives match the spec in
`install-config.yaml`, then proceeds headlessly:
- Partitions and formats both NVMe drives
- Creates btrfs subvolumes
- Generates `hardware-configuration.nix` and the SSH host key
- Derives the host age key, updates `.sops.yaml`, runs `sops updatekeys`
- Copies the repo to `/mnt/etc/nixos`
- Runs `nixos-install --flake /mnt/etc/nixos#killy`
- Reboots

#### Step 3 — After reboot

The system boots into the installed NixOS. SSH in as `fred`:

```bash
ssh-keygen -R 192.168.42.44
ssh fred@192.168.42.44
```

#### Step 4 — Commit post-install artifacts

Copy the generated hardware config and updated secrets back to the repo:

```bash
cd ~/code/killy
scp fred@192.168.42.44:/etc/nixos/killy/system/hardware-configuration.nix \
    killy/system/hardware-configuration.nix
scp fred@192.168.42.44:/etc/nixos/killy/install-config.yaml \
    killy/install-config.yaml
scp fred@192.168.42.44:/etc/nixos/.sops.yaml .sops.yaml
git add killy/system/hardware-configuration.nix killy/install-config.yaml .sops.yaml
git commit -m "killy: post-install — hardware-configuration, updated host age key"
```

#### Step 5 — Deploy config changes

For subsequent NixOS config changes, deploy from the build host over LAN
(or WireGuard once established):

```bash
nixos-rebuild switch --flake .#killy \
  --target-host fred@192.168.42.44 --use-remote-sudo
```
