# 0002 — Installer ISO image

- **Status:** implemented
- **Implemented in:** 2026-03-08

---

## Background

Spec 0001 established the mechanism for wrapping an age install key in a
Yubikey PIV retired slot and unwrapping it without a PIN. This spec defines
the next deliverable: a bootable NixOS ISO image that serves as the installer
key.

The ISO is the first concrete step toward the autonomous install described in
`docs/design/killy-install.md`. It deliberately stops short of the full
install script (a later spec); its goal is to boot into a usable environment
where the operator can interact with secrets via SOPS, using the age key
unwrapped from the Yubikey.

---

## Goals

1. Build a bootable NixOS ISO via a flake output (`.#installer-iso-killy`).
2. On boot:
   a. Enable serial console on `ttyUSB0` at 115200 baud (USB-serial adapter,
      null-modem cable to build host).
   b. Automatically unwrap the age install key from the Yubikey (PIV slot
      discovered by `CN=killy-install-key`). If the Yubikey is absent,
      display a message on the console and retry until it appears.
   c. Export `SOPS_AGE_KEY` into the default user's login session.
3. Allow the default user (`nixos`) to log in without a password on the
   serial console and on `tty0`.
4. Allow the default user to run `sops decrypt killy/install-config.yaml`
   successfully using the unwrapped age key.

---

## Non-goals

- The full install script (`install.bash`) — later spec.
- Partitioning, formatting, or writing to the target disk.
- Pre-building the full killy system closure into the ISO (later spec).

---

## Specification

### Flake output

Add a `nixosConfigurations.installer-killy` entry to `flake.nix` (to be created).
The ISO is produced by:

```bash
nix build .#installer-iso-killy
# result/iso/nixos-installer-*.iso
```

The flake uses `nixpkgs.lib.nixosSystem` with a custom module
`killy/iso.nix` as its configuration.

### Serial console

Mirror the existing killy configuration:

```nix
boot.kernelParams = [ "console=ttyUSB0,115200" "console=tty0" ];

systemd.services."serial-getty@ttyUSB0" = {
  enable = true;
  wantedBy = [ "getty.target" ];
};

systemd.services."serial-getty@" = {
  serviceConfig.ExecStart = lib.mkForce
    "${pkgs.util-linux}/sbin/agetty --noclear %I 115200 vt220";
};
```

On the build host, connect with:

```bash
screen /dev/ttyUSB0 115200
# or: minicom -D /dev/ttyUSB0 -b 115200
```

### Age key unwrapping service

A systemd oneshot service `yk-unwrap.service` runs at boot, before the login
prompt:

```
[Unit]
Description=Unwrap age install key from Yubikey
After=pcscd.service
Requires=pcscd.service
Before=getty.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/path/to/yk-unwrap-loop.sh
StandardOutput=journal+console
StandardError=journal+console
```

`yk-unwrap-loop.sh` retries until the Yubikey is present:

```bash
#!/bin/bash
while true; do
  KEY=$(python3 /etc/nixos/scripts/yk-unwrap.py --hostname killy \
          /etc/nixos/killy/wrapped-install-key.bin 2>/tmp/yk-unwrap.err)
  if [ $? -eq 0 ] && [ -n "$KEY" ]; then
    # Write to a root-only file; shell environment injection happens via pam_env
    install -m 0600 /dev/null /run/age-install-key
    printf '%s' "$KEY" > /run/age-install-key
    echo "yk-unwrap: age key loaded successfully"
    break
  fi
  echo "yk-unwrap: Yubikey not ready, retrying in 2s... ($(cat /tmp/yk-unwrap.err))"
  sleep 2
done
```

The key is written to `/run/age-install-key` (mode 0600, root-owned, tmpfs —
never touches disk).

### SOPS_AGE_KEY in user session

`pam_env` injects `SOPS_AGE_KEY` into every login session by reading
`/run/age-install-key`:

```nix
environment.pam.services.login.text = lib.mkAfter ''
  session optional ${pkgs.pam}/lib/security/pam_env.so \
    envfile=/etc/sops-age-env
'';
```

`/etc/sops-age-env` is generated at login time from `/run/age-install-key`
via a small helper, or alternatively `environment.sessionVariables` is
populated from a file sourced by the shell profile.

Simpler alternative: add to `/etc/profile.d/sops-age-key.sh`:

```bash
if [ -r /run/age-install-key ]; then
  export SOPS_AGE_KEY=$(cat /run/age-install-key)
fi
```

This is sourced by every interactive login shell automatically.

### Passwordless login

```nix
users.users.nixos = {
  isNormalUser = true;
  extraGroups = [ "wheel" ];
  password = "";        # empty password
  # or: initialHashedPassword = "";
};

security.sudo.wheelNeedsPassword = false;
```

The NixOS installer image already sets this up; the custom ISO inherits it.

### Repo contents on the ISO

The ISO is fully self-contained — no network access to the build host is
required at install time. All files needed by `nixos-install` and `killy-install`
are embedded via `environment.etc`:

| Path on ISO | Source |
|---|---|
| `/etc/nixos/flake.nix` | `flake.nix` (repo root) |
| `/etc/nixos/flake.lock` | `flake.lock` (repo root) |
| `/etc/nixos/.sops.yaml` | `.sops.yaml` (repo root) |
| `/etc/nixos/scripts/yk-unwrap.py` | `scripts/yk-unwrap.py` |
| `/etc/nixos/killy/wrapped-install-key.bin` | `killy/wrapped-install-key.bin` |
| `/etc/nixos/killy/install-config.yaml` | `killy/install-config.yaml` |
| `/etc/nixos/killy/system/{default,base,wireguard,virt}.nix` | `killy/system/` |
| `/etc/nixos/installer/` | `installer/` (scripts + killy-install) |

`hardware-configuration.nix` is intentionally absent — it is generated fresh
by `nixos-generate-config --root /mnt` during each install and placed into
`killy/system/` before `nixos-install` runs.

### Packages

```nix
environment.systemPackages = with pkgs; [
  age
  sops
  yubikey-manager
  python3
  python3Packages.cryptography
  pcsclite
];

services.pcscd.enable = true;
```

---

## Files introduced

| Path | Description |
|---|---|
| `flake.nix` | Flake with `nixosConfigurations.installer-killy` and `packages.installer-iso-killy` |
| `installer/base.nix` | Shared NixOS ISO base module (serial console, pcscd, yk-unwrap service, profile.d) |
| `installer/yk-unwrap-loop.sh` | Retry wrapper called by `yk-unwrap.service`; HOSTNAME injected by service |
| `killy/iso.nix` | killy-specific ISO module (imports base.nix, sets installer.* options) |

---

## Validation

On the build host:

```bash
# 1. Build the ISO
nix build .#installer-iso-killy

# 2. Write to USB key (replace /dev/sdX)
dd if=result/iso/nixos-installer-*.iso of=/dev/sdX bs=4M status=progress

# 3. Boot killy from the USB key with:
#    - Yubikey plugged in
#    - USB-serial adapter + null-modem cable to build host
#    - Terminal on build host: screen /dev/ttyUSB0 115200

# 4. Observe on serial console:
#    - yk-unwrap.service starts, finds Yubikey, prints "age key loaded"
#    - Login prompt appears for nixos (no password)

# 5. After login, verify:
sops decrypt /etc/nixos/killy/install-config.yaml | head -3
# Expected: ovh: acme_creds: ...
```

If the Yubikey is unplugged before boot:

```
yk-unwrap: Yubikey not ready, retrying in 2s... (ERROR: no Yubikey found)
yk-unwrap: Yubikey not ready, retrying in 2s...
```

Plugging the Yubikey in while retrying should cause the next attempt to succeed.

---

## Implementation notes

### Deviations from spec

- **WiFi + SSH added**: the installer connects to WiFi automatically and starts
  sshd, allowing remote access from the build host. Credentials (SSID, PSK) are
  stored encrypted in `install-config.yaml` under `installer.*` and decrypted
  by `installer-network.service` after `yk-unwrap.service` completes.

- **`serial-getty@ttyUSB0` auto-start**: the spec proposed a udev rule to start
  the getty when the device appears. This was replaced by directly adding
  `serial-getty@ttyUSB0` to `wantedBy = [ "getty.target" ]` in NixOS, because
  the udev rule only fires on plug events — if the FT232 adapter is already
  present at boot, the event is missed.

- **`yk-unwrap.service` does not block getty**: the spec had `Before=getty.target`
  to ensure the age key is available before login. This was removed because it
  locked the console entirely while waiting for the Yubikey. The key is still
  available in login shells via `profile.d` once the service completes.

- **Python environment**: `yubikey-manager` is not exposed as a Python package
  in nixpkgs. The solution is to build a combined environment via
  `pkgs.yubikey-manager.pythonModule.withPackages (ps: [pkgs.yubikey-manager ps.cryptography])`.

- **`/run/age-install-key` mode 0600**: spec recommended 0644. In practice 0600
  is safer; the `profile.d` script runs as the user and cannot read it. The
  installer-network service runs as root and can read it. The build host SSH key
  is embedded in the ISO so password-based SSH is not required.

- **`yk-unwrap-loop.sh` stderr separation**: stdout and stderr must be redirected
  separately — stdout captures the age key, stderr the diagnostic messages.
  Mixing them (with `2>&1`) corrupts the key file.

- **`wpa_cli` for WiFi**: NixOS's `wpa_supplicant-wlo1.service` uses a
  Nix-store config file that cannot be replaced at runtime. WiFi is configured
  by calling `wpa_cli add_network / set_network / enable_network` against the
  running daemon, which then triggers `dhcpcd` automatically on association.

- **`path` / `environment` for systemd services**: use the NixOS
  `systemd.services.<name>.path` and `environment` attributes rather than
  embedding store paths in `serviceConfig.Environment`. This is idiomatic and
  keeps the unit files readable.
