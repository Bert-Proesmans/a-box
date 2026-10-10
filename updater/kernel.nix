{
  lib,
  linux,
  buildLinux,
  linuxManualConfig,

  # Extra structured config for the hardware at hand, e.g. `{ R8169 = lib.kernel.yes; }`.
  extraConfig ? { },
}:
let
  inherit (lib.kernel) yes no;

  # Allnoconfig plus these options: only what this updater needs, all built in, no modules.
  # buildLinux fails the build when kconfig does not honour an option.
  resolved = buildLinux {
    pname = "a-box-updater-kernel";
    inherit (linux) src version;

    defconfig = "allnoconfig";
    enableCommonConfig = false;
    autoModules = false;

    structuredExtraConfig = {
      MODULES = no;

      # Boot as an EFI executable (UKI); efibootmgr needs EFI runtime services and efivarfs
      "64BIT" = yes;
      SMP = yes;
      ACPI = yes;
      X86_LOCAL_APIC = yes;
      X86_IO_APIC = yes;
      X86_X2APIC = yes;
      HPET_TIMER = yes;
      HYPERVISOR_GUEST = yes;
      PARAVIRT = yes;
      KVM_GUEST = yes;
      EFI = yes;
      EFI_STUB = yes;
      EFIVAR_FS = yes;

      # Size
      CC_OPTIMIZE_FOR_SIZE = yes;
      KERNEL_XZ = yes;
      RD_XZ = yes;

      # Userspace: initramfs with static busybox and glibc binaries
      BLK_DEV_INITRD = yes;
      BINFMT_ELF = yes;
      BINFMT_SCRIPT = yes;
      DEVTMPFS = yes;
      PROC_FS = yes;
      SYSFS = yes;
      TMPFS = yes;
      FW_LOADER = yes;

      # Wrong-clock TLS failures are silent, so keep the hardware clock
      RTC_CLASS = yes;
      RTC_HCTOSYS = yes;
      RTC_DRV_CMOS = yes;

      # Console: serial and EFI framebuffer
      PRINTK = yes;
      TTY = yes;
      SERIAL_8250 = yes;
      SERIAL_8250_CONSOLE = yes;
      VT = yes;
      VT_CONSOLE = yes;
      FB = yes;
      FB_EFI = yes;
      FRAMEBUFFER_CONSOLE = yes;

      # Main root (ext4) and ESP (FAT), GPT partitions found by name
      PCI = yes;
      PCI_MSI = yes;
      BLOCK = yes;
      BLK_DEV = yes;
      PARTITION_ADVANCED = yes;
      EFI_PARTITION = yes;
      EXT4_FS = yes;
      VFAT_FS = yes;
      NLS_CODEPAGE_437 = yes;
      NLS_ISO8859_1 = yes;
      BLK_DEV_NVME = yes;
      SCSI = yes;
      BLK_DEV_SD = yes;
      ATA = yes;
      SATA_AHCI = yes;
      VIRTIO_MENU = yes;
      VIRTIO_PCI = yes;
      VIRTIO_BLK = yes;
      SCSI_LOWLEVEL = yes;
      SCSI_VIRTIO = yes;

      # Network: IPv4 with AF_PACKET (DHCP client), IPv6 with router advertisements (SLAAC)
      NET = yes;
      INET = yes;
      IPV6 = yes;
      PACKET = yes;
      UNIX = yes;
      NETDEVICES = yes;
      ETHERNET = yes;
      VIRTIO_NET = yes;
      NET_VENDOR_INTEL = yes;
      E1000 = yes;
      E1000E = yes;
      IGB = yes;
      IGC = yes;
      IXGBE = yes;
      NET_VENDOR_REALTEK = yes;
      R8169 = yes;
      NET_VENDOR_BROADCOM = yes;
      TIGON3 = yes;
      NET_VENDOR_AQUANTIA = yes;
      AQTION = yes;

      # USB NICs
      USB_SUPPORT = yes;
      USB = yes;
      USB_PCI = yes;
      USB_XHCI_HCD = yes;
      USB_XHCI_PCI = yes;
      USB_NET_DRIVERS = yes;
      USB_USBNET = yes;
      USB_RTL8152 = yes;
      USB_NET_CDCETHER = yes;
      USB_NET_AX88179_178A = yes;
    }
    // extraConfig;
  };
in
# buildLinux builds with CONFIG_MODULES="y" hardcoded (generic.nix), so it would expect a module tree.
# linuxManualConfig is the builder one layer down; there `config` is respected.
linuxManualConfig {
  inherit (resolved) version src configfile modDirVersion;
  pname = "a-box-updater-kernel";

  config = {
    CONFIG_MODULES = "n";
    CONFIG_RUST = "n";
  };
}
