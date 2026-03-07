# 0002 — Installer ISO image

- **Status:** draft
- **Implemented in:** —

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

1. Build a bootable NixOS ISO via a flake output (`.#installer-iso`).
2. On boot:
   a. Enable serial console on `ttyUSB0` at 115200 baud (USB-serial adapter,
      null-modem cable to build host).
   b. Automatically unwrap the age install key from the Yubikey (PIV slot
      discovered by `CN=killy-install-key`). If the Yubikey is absent,
      display a message on the console and retry until it appears.
   c. Export `SOPS_AGE_KEY` into the default user's login session.
3. Allow the default user (`nixos`) to log in without a password on the
   serial console and on `tty0`.
4. Allow the default user to run `sops decrypt killy/install-secrets.yaml`
   successfully using the unwrapped age key.

---

## Non-goals

- The full install script (`install.bash`) — later spec.
- Partitioning, formatting, or writing to the target disk.
- Network configuration beyond what NixOS provides by default.
- SSH access (can be added later; not required for this spec).
- Pre-building the full killy system closure into the ISO (later spec).

---

## Specification

### Flake output

Add a `nixosConfigurations.installer` entry to `flake.nix` (to be created).
The ISO is produced by:

```bash
nix build .#installer-iso
# result/iso/nixos-installer-*.iso
```

The flake uses `nixpkgs.lib.nixosSystem` with a custom module
`installer/iso.nix` as its configuration.

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

The scripts and secrets bundle must be accessible at runtime. Two options:

- **Option A** (simpler): embed the repo checkout in the ISO at a fixed path
  (e.g. `/etc/nixos/`) using `environment.etc` or a NixOS path option.
- **Option B**: clone from GitHub at boot time (requires network).

Option A is preferred: it keeps the ISO self-contained and avoids network
dependency. Only the files needed for this spec are included:
`scripts/yk-unwrap.py`, `killy/wrapped-install-key.bin`, `.sops.yaml`,
`killy/install-secrets.yaml`.

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
| `flake.nix` | Flake with `nixosConfigurations.installer` and `packages.installer-iso` |
| `installer/iso.nix` | NixOS module defining the installer ISO configuration |
| `installer/yk-unwrap-loop.sh` | Retry wrapper called by `yk-unwrap.service` |

---

## Validation

On the build host:

```bash
# 1. Build the ISO
nix build .#installer-iso

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
sops decrypt /etc/nixos/killy/install-secrets.yaml | head -3
# Expected: ovh: acme_creds: ...
```

If the Yubikey is unplugged before boot:

```
yk-unwrap: Yubikey not ready, retrying in 2s... (ERROR: no Yubikey found)
yk-unwrap: Yubikey not ready, retrying in 2s...
```

Plugging the Yubikey in while retrying should cause the next attempt to succeed.

---

## Open questions

1. **`/etc/profile.d` vs `pam_env`**: the `profile.d` approach only works for
   interactive shells. If future scripts run as non-login processes and need
   `SOPS_AGE_KEY`, `pam_env` or a systemd `EnvironmentFile` will be needed.
   For this spec, `profile.d` is sufficient.

2. **Key file permissions**: `/run/age-install-key` is root-owned (0600). The
   `nixos` user reads it via the `profile.d` script, which runs as root in the
   shell initialization? No — `profile.d` runs as the user. The file must be
   world-readable (0644) or the `nixos` user must be in a group that can read
   it. Recommend mode 0644 since the key is already derivable by anyone with
   physical access to the Yubikey + installer image.

3. **VM testing**: the ISO should be testable in the `experiment` VM before
   burning to USB, with the Yubikey passed through via libvirt.
