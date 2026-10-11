# The updater's package set: its configuration and the artifacts built from it. Each artifact is a
# recipe in this directory that takes the configuration and the other artifacts as inputs.
#
#   kernel ─┐
#   initrd ─┴─ uki ─┬─ iso
#                   ├─ netboot ─ netboot.githubRelease
#                   └─ installerInitrd ─┐
#             installerKernel ──────────┴─ installerUki ─ installerIso
#
# Installed: copy `uki` to the ESP, as /EFI/BOOT/BOOTX64.EFI or behind a boot entry that is first in
# BootOrder; `installerIso` does both. Netbooted: serve `netboot` (UKI over UEFI HTTP boot or UEFI
# PXE, or through boot.ipxe from UEFI iPXE), or `kernel`/bzImage + `initrd`/initrd over PXE. The
# updater never changes BootOrder.
{
  lib,
  newScope,
  pkgsStatic,
  pkgsMusl,

  # URL of the file holding the store path of the system to run.
  pointerUrl,
  # Binary caches the system is downloaded from, and the keys their signatures must match.
  substituters,
  trustedPublicKeys,
  # GPT partition names of the ESP (FAT) and the main root (ext4).
  espLabel,
  rootLabel,
  # Generations kept in the main root's system profile and on the ESP.
  keepGenerations ? 2,
  # Kernel command line of the updater.
  kernelParams ? [ "quiet" ],
  # Extra structured kernel config for the hardware at hand, e.g. `{ R8169 = lib.kernel.yes; }` for another NIC driver.
  kernelConfig ? { },
  # Packages providing `lib/firmware`, for drivers that need it.
  firmware ? [ ],
}:
lib.makeScope newScope (self: {
  inherit
    pointerUrl
    substituters
    trustedPublicKeys
    espLabel
    rootLabel
    keepGenerations
    kernelParams
    firmware
    ;

  # Static binaries are copied into the initrds as single files, without a libc or other closure.
  busybox = pkgsStatic.busybox;
  # musl's <sys/syscall.h> is not included by nix-util's file-descriptor.cc; no cache has a static nix.
  nix =
    (pkgsStatic.nixVersions.nixComponents_2_34.appendPatches [ ./nix-musl-syscall.patch ]).nix-cli;
  curl = pkgsStatic.curl;
  bash = pkgsStatic.bashNonInteractive;
  # The static build of efivar does not link. musl keeps the dynamic libc small.
  efibootmgr = pkgsMusl.efibootmgr;

  # Shared by both initrds.
  initrdCompression = {
    compressor = "xz";
    compressorArgs = [
      "--check=crc32"
      "--x86"
      "--lzma2=preset=9e,dict=32MiB"
    ];
  };

  kernel = self.callPackage ./kernel.nix { extraConfig = kernelConfig; };
  initrd = self.callPackage ./initrd.nix { };
  uki = self.callPackage ./uki.nix {
    name = "a-box-updater.efi";
    id = "a-box-updater";
    prettyName = "a-box updater";
  };

  # The installer's own kernel: the updater's plus keyboards, and the disk controllers, keyboards
  # and displays of common hypervisors. The updater stays without.
  installerKernel = self.callPackage ./kernel.nix {
    extraConfig =
      with lib.kernel;
      {
        # Keyboard: PS/2, USB
        INPUT = yes;
        INPUT_KEYBOARD = yes;
        KEYBOARD_ATKBD = yes;
        SERIO = yes;
        SERIO_I8042 = yes;
        HID_SUPPORT = yes;
        HID = yes;
        HID_GENERIC = yes;
        USB_HID = yes;

        # Hyper-V (VMBus and its storage in the updater's kernel): synthetic keyboard and video
        HYPERV_KEYBOARD = yes;
        DRM = yes;
        DRM_HYPERV = yes;
        DRM_FBDEV_EMULATION = yes;

        # VMware: PVSCSI and LSI Logic controllers
        VMWARE_PVSCSI = yes;
        FUSION = yes;
        FUSION_SPI = yes;
        FUSION_SAS = yes;

        # Emulated IDE (Hyper-V generation 1, QEMU), virtio keyboard (QEMU)
        ATA_SFF = yes;
        ATA_BMDMA = yes;
        ATA_PIIX = yes;
        VIRTIO_INPUT = yes;
      }
      // kernelConfig;
  };
  installerInitrd = self.callPackage ./installer-initrd.nix { };
  installerUki = self.callPackage ./uki.nix {
    name = "a-box-installer.efi";
    id = "a-box-installer";
    prettyName = "a-box installer";
    kernel = self.installerKernel;
    initrd = self.installerInitrd;
  };

  # Boots the updater from a CD or USB stick, for disks that are already prepared.
  iso = self.callPackage ./iso.nix {
    name = "a-box-updater.iso";
    volumeId = "A_BOX_UPDATER";
  };

  # Boots the installer from a CD or USB stick.
  installerIso = self.callPackage ./iso.nix {
    name = "a-box-installer.iso";
    volumeId = "A_BOX_INSTALLER";
    uki = self.installerUki;
  };

  netboot = self.callPackage ./netboot.nix { };
})
