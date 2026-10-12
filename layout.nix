# Names that the main system, the installer and the updater agree on: GPT partition names, the btrfs
# subvolumes of the data partition, and the placeholder the installer swaps for the target disk.
{
  # FAT: the bootloader, kernels and initrds, mounted at /boot.
  espLabel = "a-box-esp";
  # Raw: writeback device of the zram root.
  zramLabel = "a-box-zram";
  # btrfs: the subvolumes below.
  dataLabel = "a-box-data";

  # Mounted at /nix: the store of the main system, filled by the updater.
  nixSubvolume = "@nix";
  # Mounted at /persistent: the state `preservation` keeps across reboots.
  persistentSubvolume = "@persistent";

  # Device path of the disk in the disko script the installer runs; a-box-install replaces it with the disk to wipe.
  diskPlaceholder = "/dev/a-box-disk";
}
