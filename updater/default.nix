{
  lib,
  stdenv,
  runCommand,
  writeText,
  replaceVarsWith,
  buildEnv,
  gnumake,
  flex,
  bison,
  bc,
  perl,
  linux,
  linuxKernel,
  makeInitrdNG,
  systemd,
  systemdUkify,
  pkgsStatic,
  pkgsMusl,
  emptyDirectory,
  nixos-install,
  cacert,

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
  # Extra kernel config lines (`CONFIG_X=y`) for the hardware at hand, e.g. another NIC driver.
  kernelConfig ? "",
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

  # Allnoconfig plus kernel.config: only what this updater needs, all built in.
  kernelConfigFile =
    runCommand "a-box-updater-kernel.config"
      {
        nativeBuildInputs = [
          gnumake
          stdenv.cc
          flex
          bison
          bc
          perl
        ];
        inherit (linux) src;
        fragment = ./kernel.config;
        inherit kernelConfig;
        passAsFile = [ "kernelConfig" ];
      }
      ''
        mkdir source
        tar -xf $src -C source --strip-components=1
        cd source
        patchShebangs scripts

        make ARCH=x86_64 allnoconfig
        scripts/kconfig/merge_config.sh -m .config $fragment $kernelConfigPath
        make ARCH=x86_64 olddefconfig

        # Kconfig silently drops symbols whose dependencies are missing.
        failed=
        while read -r line; do
          if ! grep -qxF "$line" .config; then
            echo "kernel config not honoured: $line" >&2
            failed=1
          fi
        done < <(grep -hE '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set)' $fragment $kernelConfigPath)
        [ -z "$failed" ]

        cp .config $out
      '';

  kernel = linuxKernel.manualConfig {
    inherit (linux) version src;
    configfile = kernelConfigFile;
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

  initrd = makeInitrdNG {
    name = "a-box-updater-initrd";
    compressor = "xz";
    compressorArgs = [
      "--check=crc32"
      "--x86"
      "--lzma2=preset=9e,dict=32MiB"
    ];
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

  uki =
    runCommand "a-box-updater.efi"
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
            ID=a-box-updater
            PRETTY_NAME="a-box updater"
          ''} \
          --stub=${systemd}/lib/systemd/boot/efi/linux${stdenv.hostPlatform.efiArch}.efi.stub \
          --output=$out
      '';
in
{
  # Installed: copy `uki` to the ESP, as /EFI/BOOT/BOOTX64.EFI or behind a boot entry that is first
  # in BootOrder. Netbooted: serve `uki` over UEFI HTTP boot, or `kernel`/bzImage + `initrd`/initrd
  # over PXE. The updater never changes BootOrder.
  inherit uki initrd kernel;
}
