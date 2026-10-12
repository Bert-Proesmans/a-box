# Installer initrd: a shell with a-box-install, which lays out a disk with the main system's disko
# format script and persists the updater UKI.
#
# The script is a plain bash file. It enters the initrd as a file, without its closure; the tools
# it calls are listed here per disko layer, and nothing else is shipped:
#
#   shell glue   bash, and busybox: mktemp mkdir rm dirname grep mount umount
#   gpt          sgdisk (gptfdisk), blkid (util-linux), udevadm (udevadm.sh), busybox: partprobe
#   filesystem   mkfs.vfat (dosfstools)
#   btrfs        mkfs.btrfs and btrfs (btrfs-progs), blkid, grep, mount, umount
{
  lib,
  runCommand,
  writeText,
  makeInitrdNG,
  util-linuxMinimal,
  gptfdisk,
  btrfs-progs,
  dosfstools,

  mkScript,
  busybox,
  bash,
  efibootmgr,
  initrdCompression,
  uki,
  espLabel,
  dataLabel,
  diskoFormat,
  diskPlaceholder,
}:
# a-box-install uses the placeholder as a sed pattern.
assert lib.assertMsg (builtins.match "[A-Za-z0-9._/-]+" diskPlaceholder != null)
  "diskPlaceholder must consist of [A-Za-z0-9._/-]";
let
  installerInit = mkScript {
    src = ./installer.sh;
    replacements = {
      busybox = "${busybox}";
      inherit espLabel dataLabel;
    };
  };

  aBoxInstall = mkScript {
    src = ./a-box-install.sh;
    replacements = {
      busybox = "${busybox}";
      uki = "${uki}";
      espLabel = lib.escapeShellArg espLabel;
      dataLabel = lib.escapeShellArg dataLabel;
      diskoFormat = "${diskoFormat}";
      diskPlaceholder = lib.escapeShellArg diskPlaceholder;
    };
  };

  # The initrd has no udev.
  udevadm = mkScript {
    src = ./udevadm.sh;
    replacements.busybox = "${busybox}";
  };

  # Busybox applets, overridden by the full tools where both exist. The disk tools are glibc builds
  # from the binary cache: musl builds bring a musl toolchain (python, meson) to build first.
  # blkid is util-linux's: busybox's has no `-o export`, which the script uses.
  installerBin = runCommand "a-box-installer-bin" { } ''
    mkdir $out
    for applet in $(${busybox}/bin/busybox --list); do
      ln -s ${busybox}/bin/busybox $out/$applet
    done
    ln -sf ${util-linuxMinimal.bin}/bin/blkid $out/blkid
    ln -sf ${util-linuxMinimal.bin}/bin/lsblk $out/lsblk
    ln -s ${bash}/bin/bash $out/bash
    ln -s ${gptfdisk}/bin/sgdisk $out/sgdisk
    ln -s ${btrfs-progs}/bin/btrfs $out/btrfs
    ln -s ${btrfs-progs}/bin/mkfs.btrfs $out/mkfs.btrfs
    ln -sf ${dosfstools}/bin/mkfs.vfat $out/mkfs.vfat
    ln -s ${udevadm} $out/udevadm
    ln -s ${efibootmgr}/bin/efibootmgr $out/efibootmgr
    ln -s ${aBoxInstall} $out/a-box-install
  '';
in
makeInitrdNG {
  name = "a-box-installer-initrd";
  inherit (initrdCompression) compressor compressorArgs;
  # Only the listed files and the shared libraries they need are copied, not whole closures.
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
    { source = "${bash}/bin/bash"; }
    { source = uki; }
    { source = diskoFormat; }
  ];
}
