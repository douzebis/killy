{ pkgs ? import <nixpkgs> {} }:

let
  shell = pkgs.mkShell {
    name = "killy-dev";

    shellHook = ''
      export NIXSHELL_REPO="${toString ./.}"
    '';

    packages = with pkgs; [
      # Age encryption
      age
      ssh-to-age

      # SOPS secrets management
      sops

      # Yubikey tooling
      yubikey-manager   # ykman
      yubico-piv-tool   # PIV operations: keygen, cert, decrypt

      # TLS / key inspection
      openssl

      # Python — build-host tooling (PKI, cert management, key lifecycle)
      python3
      python3Packages.cryptography

      # Shell scripting
      bash
      jq
    ];
  };

in
{
  default = shell;
  shell   = shell;
}
