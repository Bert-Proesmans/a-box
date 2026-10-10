# Module imported by the main system. Mounts the root partition by its GPT name and disables GRUB:
# the updater (../updater) installs the bootloader, kernels and initrds on the ESP.

let
  layout = import ../layout.nix;
in
{
  boot.loader.grub.enable = false;

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/${layout.rootLabel}";
    fsType = "ext4";
  };
}
