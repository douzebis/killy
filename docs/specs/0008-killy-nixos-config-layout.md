# 0008 — Killy NixOS config layout

- **Status:** implemented
- **Implemented in:** 2026-03-13

---

## Background

The current repo has killy's NixOS configuration under `killy/system/`, which
is a build-host-centric layout. This is wrong: the NixOS config that ends up on
killy should be self-contained and live in a directory that mirrors what gets
installed to `/etc/nixos/` on the machine — exactly as `motoko/etc/nixos/` does
for motoko.

Additionally, the current `killy-install` copies the full repo tree to
`/mnt/etc/nixos/`, which is incorrect: the installed system's `/etc/nixos/`
should contain only killy's own config, not build-host scaffolding.

---

## Goals

1. Restructure the repo so that `killy/` mirrors `/etc/nixos/` on the installed
   machine.
2. `killy-install` copies `killy/` verbatim to `/mnt/etc/nixos/`, then drops
   `hardware-configuration.nix` in place.
3. The build-host `flake.nix` (repo root) continues to build the installer ISO
   by importing from `killy/`.
4. `nixos-rebuild switch --flake .#killy --target-host ...` from the build host
   continues to work.

---

## Non-goals

- Changing the NixOS module content (what services run, what users exist, etc.).
- Adding VM/microVM definitions — covered in spec 0007.

---

## Specification

### Repo layout after restructure

```
killy/                          ← mirrors /etc/nixos/ on the installed machine
  flake.nix                     ← nixosConfigurations.killy
  flake.lock                    ← pinned nixpkgs + sops-nix
  configuration.nix             ← top-level: imports all modules
  hardware-configuration.nix    ← .gitignored; generated at install time
  install-config.yaml           ← SOPS-encrypted secrets (stays here)
  .sops.yaml                    ← SOPS recipient config (stays here)
  modules/
    base.nix                    ← hostname, users, SSH, networking, firewall
    wireguard.nix               ← WireGuard interface and peer config
    virt.nix                    ← KVM/libvirt
```

`killy/system/` is removed entirely.

### killy/flake.nix

Self-contained flake used both by `nixos-install` (at install time) and by
`nixos-rebuild` (from the build host for subsequent deploys):

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sops-nix }: {
    nixosConfigurations.killy = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        sops-nix.nixosModules.sops
        modules/base.nix
        modules/wireguard.nix
        modules/virt.nix
      ];
    };
  };
}
```

### killy/configuration.nix

Top-level entry point, imports hardware config:

```nix
{ ... }: {
  imports = [ ./hardware-configuration.nix ];
}
```

### killy/modules/base.nix

`sops.defaultSopsFile` uses an absolute string path (not a Nix path) to avoid
pure-eval errors, and `sops.validateSopsFiles = false` to avoid build-time
validation of a runtime path:

```nix
sops.defaultSopsFile = "/etc/nixos/install-config.yaml";
sops.validateSopsFiles = false;
```

`nixos-install` is run with `--impure` to allow access to the absolute path.

### Dependency direction

The dependency is strictly one-way:

```
root flake.nix  →  killy/modules/*.nix  (imports killy modules to build the ISO)
killy/flake.nix →  killy/modules/*.nix  (imports killy modules for the system)
killy/flake.nix     (knows nothing about the ISO or the root flake)
```

`killy/flake.nix` is a plain NixOS system flake. It has no knowledge of the
installer, the build-host repo structure, or the ISO. What ends up in
`/etc/nixos/` on the installed machine is 100% idiomatic NixOS — identical to
what you would write setting up the machine by hand.

### Build-host flake.nix (repo root)

The root `flake.nix` builds the installer ISO. It no longer defines
`nixosConfigurations.killy` — that lives in `killy/flake.nix` now. The ISO
module (`installer/killy.nix`) may import killy modules directly if needed,
but the root flake has no dependency on `killy/flake.nix`:

```nix
nixosConfigurations.installer-killy = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [ ./installer/killy.nix ];
};
```

### Config lifecycle after install

The build host repo is the source of truth for killy's config. `killy/`
mirrors `/etc/nixos/` on killy. The workflow for applying config changes:

```bash
# 1. Edit files in killy/ on the build host, commit to git.

# 2. Sync to killy.
rsync -av --delete killy/ fred@<killy-ip>:/etc/nixos/

# 3. Rebuild and switch on killy (standard NixOS procedure).
ssh fred@<killy-ip> "sudo nixos-rebuild switch --flake /etc/nixos#killy --impure"
```

`/etc/nixos/` on killy always reflects what is (or will be) running.
The build host repo is where edits happen; killy is the authoritative
runtime state.

### killy-install: what gets copied to /mnt/etc/nixos/

`copy_repo()` copies `killy/` verbatim to `/mnt/etc/nixos/`:

```
/mnt/etc/nixos/
  flake.nix
  flake.lock
  configuration.nix
  install-config.yaml
  .sops.yaml
  modules/
    base.nix
    wireguard.nix
    virt.nix
```

`nixos-generate-config --root /mnt` writes `hardware-configuration.nix` to
`/mnt/etc/nixos/` (standard location). No move needed.

`nixos-install` runs against `/mnt/etc/nixos#killy` — the self-contained flake
that is already there.

### .gitignore

`killy/hardware-configuration.nix` is added to `.gitignore` (machine-generated,
never committed).

---

## Files changed

| File | Change |
|---|---|
| `killy/flake.nix` | New — self-contained killy system flake |
| `killy/flake.lock` | New — generated by `nix flake update` inside `killy/` |
| `killy/configuration.nix` | New — imports hardware-configuration.nix |
| `killy/modules/base.nix` | Moved from `killy/system/base.nix`; update sops path |
| `killy/modules/wireguard.nix` | Moved from `killy/system/wireguard.nix` |
| `killy/modules/virt.nix` | Moved from `killy/system/virt.nix` |
| `killy/system/` | Removed entirely |
| `flake.nix` (root) | Remove `nixosConfigurations.killy`; keep ISO only |
| `installer/bin/killy-install` | `copy_repo()` copies `killy/` to `/mnt/etc/nixos/`; `nixos-install` uses `/mnt/etc/nixos#killy` |
| `installer/killy.nix` | Rename from `killy/iso.nix`; update flake/lock source paths |
| `.gitignore` | Add `killy/hardware-configuration.nix` |
| `docs/user-guide.md` | Update deploy command to `--flake ./killy#killy` |
