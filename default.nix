# Build-host dev shell.
#
# Enter from the repo root with:   nix-shell
# Or from anywhere:                nix-shell ~/code/killy
#
# This shell is required before running any script or SOPS command in this
# repo. It provides all tools needed for secrets management, Yubikey
# operations, and ISO builds. The bin/ directory is added to PATH so that
# helper scripts (build-iso, killy-serial) are available by name.
#
# This file is also imported by flake.nix for `nix develop` / `nix-shell`
# invocations via the flake interface.
{ pkgs ? import <nixpkgs> {} }:

let
  shell = pkgs.mkShell {
    name = "killy-dev";

    shellHook = ''
      # Used by the lint hook to detect whether the active nix-shell belongs
      # to this repo (see ~/.claude/hooks/claude-hook-post-edit-lint).
      export NIXSHELL_REPO="${toString ./.}"

      # Put repo helper scripts on PATH so they can be called by name:
      #   build-iso       — build the installer ISO for a given host
      #   killy-serial    — send commands to killy's serial console
      export PATH="${toString ./.}/bin:$PATH"
    '';

    packages = with pkgs; [
      # age — encrypt/decrypt files and generate host keys.
      # Used by: yk-setup.py (key generation), yk-unwrap.py (key recovery),
      # and manually when deriving new host age keys at install time.
      age
      # ssh-to-age — derive an age private key from an SSH ed25519 key.
      # Used once to set up the operator age key from the build host's SSH
      # host key (see docs/user-guide.md — "Operator key setup").
      ssh-to-age

      # sops — encrypt and decrypt secrets files.
      # The secrets file (killy/install-config.yaml) is edited with:
      #   sops edit killy/install-config.yaml
      # Decryption uses the operator key in ~/.config/sops/age/keys.txt.
      sops

      # ykman — Yubikey management CLI. Used by yk-setup.py and yk-unwrap.py
      # internally, and useful for diagnostics (ykman list, ykman piv info).
      yubikey-manager
      # yubico-piv-tool — lower-level PIV operations (key generation, cert
      # import/export). Used by yk-setup.py when provisioning a new slot.
      yubico-piv-tool

      # openssl — inspect TLS certificates and keys. Not required for normal
      # operation, but handy when debugging PIV certificate issues.
      openssl

      # python3 + cryptography — runtime for scripts/yk-setup.py and
      # scripts/yk-unwrap.py on the build host.
      # Note: the ISO uses a separate Python env built from yubikey-manager's
      # own pythonModule, not this one (see installer/base.nix — unwrapPython).
      python3
      python3Packages.cryptography

      # bash and jq — shell scripting and JSON parsing used by helper scripts.
      bash
      jq

      # ruff — Python linter for scripts/. Run manually: ruff check scripts/
      ruff
    ];
  };

in
{
  default = shell;
  shell   = shell;
}
