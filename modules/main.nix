# Module imported by every main system. Evaluates the updater (./updater.nix) from the same a-box
# settings, sets default a-box pointerUrl, substituters and trustedPublicKeys, disables GRUB and
# mounts the root partition by label. Links the updater UKI into the system output and exposes
# system.build.a-box-updater and system.build.a-box-image.

{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.a-box;
  storage = "https://storage.proesmans.eu";

  updater = import (modulesPath + "/../lib/eval-config.nix") {
    system = null;
    modules = [
      ./updater.nix
      {
        nixpkgs.pkgs = pkgs;
        a-box = {
          inherit (cfg)
            pointerUrl
            substituters
            trustedPublicKeys
            keepGenerations
            ;
        };
      }
    ]
    ++ cfg.updaterModules;
  };

  uki = "${updater.config.system.build.uki}/${updater.config.system.boot.loader.ukiFile}";
in
{
  imports = [ ./a-box.nix ];

  a-box = {
    pointerUrl = lib.mkDefault "${storage}/a-box/${config.networking.hostName}";
    substituters = lib.mkDefault [
      "${storage}/nix-cache"
      "https://cache.nixos.org"
    ];
    trustedPublicKeys = lib.mkDefault [
      (lib.fileContents ../keys/cache.pub)
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  boot.loader.grub.enable = false;

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/${cfg.layout.rootLabel}";
    fsType = "ext4";
  };

  # Ship the updater inside the system so every update also refreshes the updater.
  system.systemBuilderCommands = ''
    ln -s ${uki} $out/${cfg.layout.updaterFile}
  '';

  system.build = {
    a-box-updater = updater.config.system.build.uki;
    a-box-image = updater.config.system.build.image;
  };
}
