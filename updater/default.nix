{
  lib,
  stdenv,
  callPackage,
  runCommand,
  writeText,
  replaceVarsWith,
  buildEnv,
  makeInitrdNG,
  systemd,
  systemdUkify,
  pkgsStatic,
  pkgsMusl,
  emptyDirectory,
  nixos-install,
  cacert,
  util-linuxMinimal,
  e2fsprogs,
  dosfstools,

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
let
  # Static binaries are copied into the initrd as single files, without a libc or other closure.
  busybox = pkgsStatic.busybox;
  # musl's <sys/syscall.h> is not included by nix-util's file-descriptor.cc; no cache has a static nix.
  nix =
    (pkgsStatic.nixVersions.nixComponents_2_34.appendPatches [ ./nix-musl-syscall.patch ]).nix-cli;
  curl = pkgsStatic.curl;
  bash = pkgsStatic.bashNonInteractive;
  # The static build of efivar does not link. musl keeps the dynamic libc small.
  efibootmgr = pkgsMusl.efibootmgr;

  kernel = callPackage ./kernel.nix { extraConfig = kernelConfig; };

  # The installer's own kernel: the updater's plus keyboards, and the disk controllers, keyboards
  # and displays of common hypervisors. The updater stays without.
  installerKernel = callPackage ./kernel.nix {
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

  # nixos-install without its bootloader step: no flake, no nixos-enter, no jq.
  installer = nixos-install.override {
    runtimeShell = "${bash}/bin/bash";
    jq = emptyDirectory;
    nixos-enter = emptyDirectory;
    util-linuxMinimal = emptyDirectory;
  };

  init = replaceVarsWith {
    src = ./init.sh;
    isExecutable = true;
    replacements = {
      busybox = "${busybox}";
      pointerUrl = lib.escapeShellArg pointerUrl;
      keepGenerations = toString keepGenerations;
      espLabel = lib.escapeShellArg espLabel;
      rootLabel = lib.escapeShellArg rootLabel;
    };
  };

  udhcpcScript = replaceVarsWith {
    src = ./udhcpc.sh;
    isExecutable = true;
    replacements.busybox = "${busybox}";
  };

  bin = runCommand "a-box-updater-bin" { } ''
    mkdir $out
    for applet in $(${busybox}/bin/busybox --list); do
      ln -s ${busybox}/bin/busybox $out/$applet
    done
    ln -s ${nix}/bin/nix-env $out/nix-env
    ln -s ${nix}/bin/nix-store $out/nix-store
    ln -s ${curl.bin}/bin/curl $out/curl
    ln -s ${efibootmgr}/bin/efibootmgr $out/efibootmgr
    ln -s ${installer}/bin/nixos-install $out/nixos-install
  '';

  nixConf = writeText "nix.conf" ''
    substituters = ${toString substituters}
    trusted-public-keys = ${toString trustedPublicKeys}
    build-users-group =
    max-jobs = 0
    sandbox = false
    connect-timeout = 15
    fsync-store-paths = true
    # Paths left by a failed download stay for the next attempt; collect garbage only when
    # space runs low. Paths of the running realise are temp roots.
    min-free = ${toString (1024 * 1024 * 1024)}
  '';

  # Shared by both initrds.
  compression = {
    compressor = "xz";
    compressorArgs = [
      "--check=crc32"
      "--x86"
      "--lzma2=preset=9e,dict=32MiB"
    ];
  };

  initrd = makeInitrdNG {
    name = "a-box-updater-initrd";
    inherit (compression) compressor compressorArgs;
    # Only the listed files and the shared libraries they need are copied, not whole closures.
    contents = [
      {
        source = init;
        target = "/init";
      }
      {
        source = bin;
        target = "/bin";
      }
      {
        source = udhcpcScript;
        target = "/etc/udhcpc.sh";
      }
      {
        source = nixConf;
        target = "/etc/nix/nix.conf";
      }
      {
        source = writeText "passwd" "root:x:0:0:root:/root:/bin/sh\n";
        target = "/etc/passwd";
      }
      {
        source = writeText "group" "root:x:0:\n";
        target = "/etc/group";
      }
      {
        source = "${cacert}/etc/ssl/certs/ca-bundle.crt";
        target = "/etc/ssl/certs/ca-certificates.crt";
      }
      { source = "${busybox}/bin/busybox"; }
      { source = "${bash}/bin/bash"; }
    ]
    ++ lib.optional (firmware != [ ]) {
      source = "${
        buildEnv {
          name = "a-box-updater-firmware";
          paths = firmware;
          pathsToLink = [ "/lib/firmware" ];
        }
      }/lib/firmware";
      target = "/lib/firmware";
    };
  };

  # mkUki NAME OS-RELEASE-ID PRETTY-NAME KERNEL INITRD
  mkUki =
    name: id: prettyName: kernel: initrd:
    runCommand name
      {
        nativeBuildInputs = [ systemdUkify ];
      }
      ''
        ukify build \
          --linux=${kernel}/bzImage \
          --initrd=${initrd}/initrd \
          --cmdline=${lib.escapeShellArg (toString kernelParams)} \
          --uname=${kernel.modDirVersion} \
          --os-release=@${writeText "os-release" ''
            ID=${id}
            PRETTY_NAME="${prettyName}"
          ''} \
          --stub=${systemd}/lib/systemd/boot/efi/linux${stdenv.hostPlatform.efiArch}.efi.stub \
          --output=$out
      '';

  uki = mkUki "a-box-updater.efi" "a-box-updater" "a-box updater" kernel initrd;

  # Installer: a shell with disk tools and a-box-install, which prepares a disk and persists `uki`.
  installerInit = replaceVarsWith {
    src = ./installer.sh;
    isExecutable = true;
    replacements = {
      busybox = "${busybox}";
      inherit espLabel rootLabel;
    };
  };

  aBoxInstall = replaceVarsWith {
    src = ./a-box-install.sh;
    isExecutable = true;
    replacements = {
      busybox = "${busybox}";
      uki = "${uki}";
      espLabel = lib.escapeShellArg espLabel;
      rootLabel = lib.escapeShellArg rootLabel;
    };
  };

  # Busybox applets, overridden by the full tools where both exist. The disk tools are glibc builds
  # from the binary cache: musl builds bring a musl toolchain (python, meson) to build first.
  installerBin = runCommand "a-box-installer-bin" { } ''
    mkdir $out
    for applet in $(${busybox}/bin/busybox --list); do
      ln -s ${busybox}/bin/busybox $out/$applet
    done
    ln -sf ${util-linuxMinimal.bin}/bin/sfdisk $out/sfdisk
    ln -sf ${util-linuxMinimal.bin}/bin/wipefs $out/wipefs
    ln -sf ${util-linuxMinimal.bin}/bin/lsblk $out/lsblk
    ln -sf ${e2fsprogs.bin}/bin/mkfs.ext4 $out/mkfs.ext4
    ln -sf ${dosfstools}/bin/mkfs.vfat $out/mkfs.vfat
    ln -s ${efibootmgr}/bin/efibootmgr $out/efibootmgr
    ln -s ${aBoxInstall} $out/a-box-install
  '';

  installerInitrd = makeInitrdNG {
    name = "a-box-installer-initrd";
    inherit (compression) compressor compressorArgs;
    contents = [
      {
        source = installerInit;
        target = "/init";
      }
      {
        source = installerBin;
        target = "/bin";
      }
      {
        source = writeText "passwd" "root:x:0:0:root:/root:/bin/sh\n";
        target = "/etc/passwd";
      }
      {
        source = writeText "group" "root:x:0:\n";
        target = "/etc/group";
      }
      { source = "${busybox}/bin/busybox"; }
      { source = uki; }
    ];
  };

  installerUki =
    mkUki "a-box-installer.efi" "a-box-installer" "a-box installer" installerKernel
      installerInitrd;
in
{
  # Installed: copy `uki` to the ESP, as /EFI/BOOT/BOOTX64.EFI or behind a boot entry that is first
  # in BootOrder; `installerIso` does both. Netbooted: serve `netboot` (UKI over UEFI HTTP boot or
  # UEFI PXE, or through boot.ipxe from UEFI iPXE), or `kernel`/bzImage + `initrd`/initrd over PXE.
  # The updater never changes BootOrder.
  inherit uki initrd kernel;

  # Boots the updater from a CD or USB stick, for disks that are already prepared.
  iso = callPackage ./iso.nix {
    name = "a-box-updater.iso";
    volumeId = "A_BOX_UPDATER";
    inherit uki;
  };

  # Boots the installer from a CD or USB stick.
  installerIso = callPackage ./iso.nix {
    name = "a-box-installer.iso";
    volumeId = "A_BOX_INSTALLER";
    uki = installerUki;
  };

  # TFTP or HTTP root for netbooting the updater, for disks that are already prepared.
  netboot = runCommand "a-box-updater-netboot" { } ''
    mkdir $out
    cp ${uki} $out/a-box-updater.efi
    cp ${writeText "boot.ipxe" ''
      #!ipxe
      # UEFI iPXE only. Relative to this script's URL, so over the protocol it came by.
      chain a-box-updater.efi
    ''} $out/boot.ipxe
  '';
}
