# What an admin does by hand: the updater on the ESP, an ext4 root partition next to it.
{
  lib,
  pkgs,
  layout,
  updater,
}:
(import (pkgs.path + "/nixos/lib/eval-config.nix") {
  system = null;
  modules = [
    (pkgs.path + "/nixos/modules/image/repart.nix")
    {
      nixpkgs.pkgs = pkgs;
      system.stateVersion = lib.trivial.release;
      image.repart = {
        enable = true;
        name = "a-box-test";
        sectorSize = 512;
        partitions = {
          "10-esp" = {
            contents."/EFI/BOOT/BOOTX64.EFI".source = updater.uki;
            repartConfig = {
              Type = "esp";
              Format = "vfat";
              Label = layout.espLabel;
              SizeMinBytes = "256M";
              SizeMaxBytes = "256M";
            };
          };
          "20-root".repartConfig = {
            Type = "linux-generic";
            Format = "ext4";
            Label = layout.rootLabel;
            SizeMinBytes = "4G";
            SizeMaxBytes = "4G";
          };
        };
      };
    }
  ];
}).config.system.build.image
