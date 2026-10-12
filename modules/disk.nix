{
  lib,
  layout,
  sources,
  ...
}:
let
  btrfsOptions = [
    "compress=zstd"
    "noatime"
  ];
in
{
  imports = [ (sources.disko + "/module.nix") ];

  disko.devices.disk.main = {
    type = "disk";
    # Only the installer's script uses the device; the installer swaps it for the disk it is given.
    device = lib.mkDefault "/dev/sda";

    content = {
      type = "gpt";

      partitions = {
        esp = {
          label = layout.espLabel;
          type = "EF00";
          size = "1G";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };

        # No content: the zram root writes idle pages back to the raw partition.
        zram = {
          label = layout.zramLabel;
          size = "4G";
        };

        # The remainder of the disk; disko creates the 100% partition last.
        data = {
          label = layout.dataLabel;
          size = "100%";
          content = {
            type = "btrfs";
            # Overwrite what the partition held.
            extraArgs = [ "-f" ];
            subvolumes = {
              ${layout.nixSubvolume} = {
                mountpoint = "/nix";
                mountOptions = btrfsOptions;
              };
              ${layout.persistentSubvolume} = {
                mountpoint = "/persistent";
                mountOptions = btrfsOptions;
              };
            };
          };
        };
      };
    };
  };
}
