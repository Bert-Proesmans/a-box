# Updater initrd: init.sh as /init, the static tools and nixos-install, the DHCP lease script,
# nix.conf for the configured caches, CA certificates and the configured firmware.
{
  lib,
  runCommand,
  writeText,
  replaceVarsWith,
  buildEnv,
  makeInitrdNG,
  emptyDirectory,
  nixos-install,
  cacert,

  busybox,
  nix,
  curl,
  bash,
  efibootmgr,
  initrdCompression,
  pointerUrl,
  substituters,
  trustedPublicKeys,
  espLabel,
  rootLabel,
  keepGenerations,
  firmware,
}:
let
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
in
makeInitrdNG {
  name = "a-box-updater-initrd";
  inherit (initrdCompression) compressor compressorArgs;
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
}
