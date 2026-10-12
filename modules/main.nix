# Module imported by the main system, a volatile VM host: ephemeral root, state only through the
# attached disk. The updater (../updater) installs the bootloader, kernels and initrds on the ESP,
# so GRUB stays off.
{
  imports = [
    ./disk.nix
    ./ephemeral-root.nix
    ./strict.nix
    ./preservation.nix
  ];

  boot.loader.grub.enable = false;

  # The updater kernel's disk controllers beyond NixOS's initrd defaults (AHCI, NVMe): virtio
  # (QEMU/KVM) and Hyper-V storage. Without them the data partitions never appear.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "hv_vmbus"
    "hv_storvsc"
  ];

  virtualisation.hypervGuest.enable = true;

  # Both loaded: harmless, and only the matching one binds. /dev/kvm needs nested virtualisation
  # exposed by the outer hypervisor (Hyper-V: `Set-VMProcessor -ExposeVirtualizationExtensions $true`).
  boot.kernelModules = [
    "kvm-amd"
    "kvm-intel"
  ];
}
