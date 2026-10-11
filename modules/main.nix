# Module imported by the main system. Mounts the root partition by its GPT name, loads the disk
# drivers the updater has, and disables GRUB: the updater (../updater) installs the bootloader,
# kernels and initrds on the ESP.

let
  layout = import ../layout.nix;
in
{
  boot.loader.grub.enable = false;

  # The updater kernel's disk controllers beyond NixOS's initrd defaults (AHCI, NVMe): virtio
  # (QEMU/KVM) and Hyper-V storage. Without them the root partition never appears.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "hv_vmbus"
    "hv_storvsc"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/${layout.rootLabel}";
    fsType = "ext4";
  };
}
