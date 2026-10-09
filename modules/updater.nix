# Updater UKI whose initrd never switches root: it mounts the main root and ESP, pulls the system
# named by the pointer into the main store, prunes old generations, writes boot entries and
# reboots via a one-shot systemd-boot entry. Also defines the install image (image.repart): ESP
# with systemd-boot and the updater, plus a root partition grown on first boot by systemd-repart
# and growfs.
#
#   firmware -> systemd-boot -> updater (default entry) -> reboot
#            -> systemd-boot -> a-box-<gen>.conf (one-shot) -> main system

{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.a-box;
  inherit (cfg.layout) espLabel rootLabel updaterFile;
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
in
{
  imports = [
    ./a-box.nix
    (modulesPath + "/image/repart.nix")
  ];

  system.stateVersion = lib.trivial.release;

  boot.kernelParams = [ "quiet" ];

  # Common wired NICs and virtio. Machines add their own via a-box.updaterModules.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "virtio_net"
    "e1000"
    "e1000e"
    "igb"
    "igc"
    "ixgbe"
    "r8169"
    "tg3"
    "atlantic"
    "r8152"
    "cdc_ether"
    "ax88179_178a"
  ];
  hardware.firmware = [ pkgs.linux-firmware ];

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/${rootLabel}";
    fsType = "ext4";
    autoResize = true;
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/${espLabel}";
    fsType = "vfat";
    neededForBoot = true;
    options = [ "umask=0077" ];
  };

  # Grow the root partition into free disk space, then its filesystem (x-systemd.growfs).
  # Stage 1 does not ship the growfs unit and binary by default.
  boot.initrd.systemd.repart.enable = true;
  systemd.repart.partitions."10-root".Type = "linux-generic";
  boot.initrd.systemd.additionalUpstreamUnits = [ "systemd-growfs@.service" ];
  boot.initrd.systemd.storePaths = [
    "${config.boot.initrd.systemd.package}/lib/systemd/systemd-growfs"
  ];

  boot.initrd.systemd = {
    enable = true;

    network = {
      enable = true;
      networks."10-wired" = {
        matchConfig.Type = "ether";
        networkConfig.DHCP = "yes";
      };
      wait-online = {
        anyInterface = true;
        timeout = 60;
      };
    };

    initrdBin = [
      pkgs.nix
      pkgs.curl
      pkgs.jq
      pkgs.diffutils
    ];

    contents = {
      "/etc/ssl/certs/ca-certificates.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

      # Every nix command operates on the main system's store.
      "/etc/nix/nix.conf".text = ''
        store = local?root=/sysroot
        substituters = ${toString cfg.substituters}
        trusted-public-keys = ${toString cfg.trustedPublicKeys}
        build-users-group =
        max-jobs = 0
        sandbox = false
        connect-timeout = 15
        fsync-store-paths = true
        # Paths left by a failed download stay for the next attempt; collect garbage only when
        # space runs low. Paths of the running realise are temp roots.
        min-free = ${toString (1024 * 1024 * 1024)}
        experimental-features = nix-command
      '';
    };

    # This initrd never switches root.
    services.initrd-find-nixos-closure.enable = false;
    services.initrd-nixos-activation.enable = false;

    services.a-box-update = {
      description = "Update the main system and reboot into it";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "initrd-fs.target"
        "systemd-growfs@sysroot.service"
      ];
      before = [ "initrd.target" ];
      requiredBy = [ "initrd.target" ];
      environment = {
        A_BOX_POINTER_URL = cfg.pointerUrl;
        A_BOX_KEEP = toString cfg.keepGenerations;
        A_BOX_UPDATER_FILE = updaterFile;
      };
      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        TimeoutStartSec = "infinity";
      };
      script = builtins.readFile ./update.sh;
    };
  };

  boot.uki = {
    name = lib.removeSuffix ".efi" updaterFile;
    version = null;
    settings.UKI = {
      # The default embeds the toplevel's init, which this system never has.
      Cmdline = toString config.boot.kernelParams;
      OSRelease = "@${pkgs.writeText "os-release" ''
        ID=a-box-updater
        PRETTY_NAME="a-box updater"
      ''}";
    };
  };

  image.repart = {
    enable = true;
    name = "a-box";
    # OVMF and most firmware expect 512-byte sectors.
    sectorSize = 512;
    partitions = {
      "10-esp" = {
        contents = {
          "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
            "${config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
          "/EFI/Linux/${updaterFile}".source =
            "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
          "/loader/loader.conf".source = pkgs.writeText "loader.conf" ''
            default ${updaterFile}
            timeout 0
            editor no
          '';
        };
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          Label = espLabel;
          SizeMinBytes = "512M";
          SizeMaxBytes = "512M";
        };
      };
      "20-root" = {
        repartConfig = {
          Type = "linux-generic";
          Format = "ext4";
          Label = rootLabel;
          SizeMinBytes = "256M";
          SizeMaxBytes = "256M";
        };
      };
    };
  };
}
