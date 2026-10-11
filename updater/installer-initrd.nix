# Installer initrd: a shell with disk tools and a-box-install, which prepares a disk and persists
# the updater UKI.
{
  lib,
  runCommand,
  writeText,
  replaceVarsWith,
  makeInitrdNG,
  util-linuxMinimal,
  e2fsprogs,
  dosfstools,

  busybox,
  efibootmgr,
  initrdCompression,
  uki,
  espLabel,
  rootLabel,
}:
let
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
in
makeInitrdNG {
  name = "a-box-installer-initrd";
  inherit (initrdCompression) compressor compressorArgs;
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
}
