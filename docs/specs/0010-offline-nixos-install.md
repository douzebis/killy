# 0010 — Offline nixos-install via pre-built system closure in ISO

- **Status:** implemented
- **Implemented in:** 2026-03-14

---

## Background

After updating sops-nix from the pinned version (c8e69670, 2026-03-08) to a
newer version (d1ff3b10) that supports `sops.useSystemdActivation`, the ISO
build and the target system closure diverged: the ISO is built from the root
`flake.nix` (installer config) while the target system is defined in
`killy/flake.nix`. When `killy-install` runs `nixos-install`, Nix evaluates
`killy/flake.nix` and finds that the target system's closure is not in the ISO
store — it then attempts to download ~750 packages from the internet.

This breaks the design goal of a fully self-contained installer ISO.

---

## Goals

1. `nixos-install` runs fully offline — no packages are fetched from the
   network during installation.
2. `killy/flake.nix` remains self-contained (it mirrors `/etc/nixos/` on the
   installed machine and is used for `nixos-rebuild switch` — it must not
   reference the root flake or build-host paths).
3. The ISO remains a single build artifact produced by `build-iso` on the
   build host.

---

## Non-goals

- Supporting arbitrary target hardware without code changes.
- Making the installer work without network access for future `nixos-rebuild`
  runs (only installation is in scope).

---

## Specification

### 10.1 The offline guarantee

`nixos-install` works offline if all store path *dependencies* of the target
system's `toplevel` derivation are present in the local Nix store. The
`toplevel` itself is a thin derivation (symlinks + text files, no compilation)
that Nix can build locally in seconds from already-present inputs.

The `fileSystems` entries in `hardware-configuration.nix` (UUID-specific,
generated at partition time) cause the final `toplevel` store path to differ
from any pre-built version. But they do not introduce new *package*
dependencies — only new `systemd` mount unit text files that are built from
already-present components.

Therefore: if we embed a system whose package closure is a superset of the
target system's package closure, `nixos-install` will find all dependencies
locally and build only the thin `toplevel`, with zero network access.

### 10.2 Stable hardware module

A new module `killy/modules/hardware.nix` declares the hardware facts that
are stable across installs (i.e., independent of partition UUIDs):

- `boot.initrd.availableKernelModules` — kernel modules for killy's NVMe +
  USB hardware (from the previously captured `hardware-configuration.nix`).
- `boot.kernelModules` — `kvm-intel` (needed by libvirtd).
- `hardware.cpu.intel.updateMicrocode` — adds Intel microcode to the closure.
- `nixpkgs.hostPlatform` — `x86_64-linux`.

These declarations are a superset of what `nixos-generate-config` will add
for this specific machine. When the real `hardware-configuration.nix` is
imported at install time, its kernel module list is a subset of what
`hardware.nix` already declares — the NixOS module system merges them
(deduplicating), and the resulting initrd derivation is identical to the
pre-built one.

### 10.3 Split of configuration.nix

`killy/configuration.nix` imports both:

1. `./modules/hardware.nix` — stable, available at ISO build time.
2. `./hardware-configuration.nix` — UUID-specific, generated at install time
   by `nixos-generate-config`. Provides only `fileSystems` and `swapDevices`.

### 10.4 Root flake evaluates target system inline

The root `flake.nix` evaluates the killy target system (`killySystem`) using
the same `nixpkgs` + `sops-nix` inputs and the same NixOS modules as
`killy/flake.nix`, but substituting `hardware.nix` directly for
`configuration.nix` (which would attempt to import the non-existent
`hardware-configuration.nix` at build time).

`killySystem.config.system.build.toplevel` is passed as `killyToplevel` via
`specialArgs` to the ISO config.

NixOS requires at least a root `fileSystems` entry to evaluate successfully.
Since no real UUID is available at ISO build time, a minimal stub
(`device = "/dev/sda"; fsType = "btrfs"`) is added inline. This stub only
affects the generated systemd mount unit text (thin, no packages) and does
not influence any package in the closure.

### 10.5 ISO embeds the target system closure

`killy/iso.nix` adds `killyToplevel` to `isoImage.storeContents`. The NixOS
ISO build system copies the full closure of this derivation into the ISO's
squashfs store, making all packages available to `nixos-install` at install
time.

### 10.6 Install procedure

`killy-install` runs a single command:

```
nixos-install --root /mnt --no-root-passwd --impure --no-channel-copy \
  --flake /mnt/etc/nixos#killy
```

`nixos-install --flake` internally runs `nix build --store /mnt` with
`--extra-substituters auto?trusted=1`. The `auto?trusted=1` substituter serves
all store paths from the live ISO's Nix daemon (which has the full killy system
closure registered via the squashfs `nix-path-registration` file). No network
access occurs — all packages are served from the ISO store.

The flake is re-evaluated against the real `hardware-configuration.nix`
(generated by `nixos-generate-config` with correct partition UUIDs). Nix builds
only the thin `toplevel` derivation (activation scripts, fstab — seconds of
work). All package dependencies are fetched as substitutes from the ISO store.

`--impure` is required because flake evaluation reads `/etc/nixos/` (an
absolute path on the live system). `--no-channel-copy` skips channel
installation (not needed; the installed system uses the flake).

---

## Key insight (from research)

The "offline guarantee" is:

> All store paths in the target system's *dependency closure* are present on
> the ISO — not necessarily the exact `toplevel` store path.

The `toplevel` derivation is rebuilt locally by Nix in near-zero time. The
heavy lifting (kernel, initrd, all user-space packages) is already in the ISO
store.

---

## Files changed

| File | Change |
|---|---|
| `killy/modules/hardware.nix` | New — stable hardware declarations separated from UUID-specific config |
| `killy/configuration.nix` | Import both `hardware.nix` and `hardware-configuration.nix` |
| `killy/iso.nix` | Accept `killyToplevel` arg; add to `isoImage.storeContents`; embed `hardware.nix` |
| `flake.nix` | Evaluate `killySystem` inline; pass `killyToplevel` via `specialArgs` |
| `installer/bin/killy-install` | Step 10: `nixos-install --impure --no-channel-copy --flake` (relies on `auto?trusted=1` substituter); `wrapped-install-key.bin` copied to `killy/` subdir |
