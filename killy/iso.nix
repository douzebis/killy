{ ... }:

# killy-specific installer ISO configuration.
# Imports the shared base module and sets host-specific options.

{
  imports = [ ../installer/base.nix ];

  installer.hostname    = "killy";
  installer.wrappedKey  = ./wrapped-install-key.bin;
  installer.configFile  = ./install-config.yaml;
  installer.sofsYaml   = ../.sops.yaml;
  installer.unwrapScript = ../scripts/yk-unwrap.py;

  isoImage.isoName  = "killy-installer.iso";
  isoImage.volumeID = "KILLY_INSTALLER";
}
