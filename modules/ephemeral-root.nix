# Ephemeral root: a zram ext4 device built in the initrd on every boot. Idle pages are written back
# to the raw zram partition, so the root can outgrow RAM. /nix and /persistent come from the btrfs
# data partition (./disk.nix) and are mounted in the initrd, before the updater's `init=<toplevel>/init`
# runs.
{
  config,
  lib,
  pkgs,
  utils,
  layout,
  ...
}:
let
  backingDevice = "/dev/disk/by-partlabel/${layout.zramLabel}";
  backingUnit = "${utils.escapeSystemdPath backingDevice}.device";
in
{
  # Writeback is what lets the zram device spill to the partition; fail the build without it.
  system.requiredKernelConfig = with config.lib.kernelConfig; [
    (isModule "ZRAM")
    (isEnabled "ZRAM_WRITEBACK")
  ];

  boot.initrd = {
    # zstd and zsmalloc are built into the kernel; only the zram driver itself is a module.
    kernelModules = [ "zram" ];

    # ext4 (root) and btrfs (/nix, /persistent). Pulls in the filesystem modules and, for ext4,
    # e2fsprogs: the mkfs below reuses that store path, adding nothing to the initrd.
    supportedFilesystems = [
      "ext4"
      "btrfs"
    ];

    systemd = {
      enable = true;
      emergencyAccess = true;

      services.init-zram-root = {
        description = "Initialize ZRAM Root Device";
        wantedBy = [ "initrd-root-device.target" ];
        requires = [ backingUnit ];
        after = [
          backingUnit
          "systemd-modules-load.service"
        ];
        before = [
          "sysroot.mount"
          "shutdown.target"
        ];
        conflicts = [
          "initrd-switch-root.target"
          "shutdown.target"
        ];

        unitConfig = {
          DefaultDependencies = false;
          OnFailure = [ "emergency.target" ];
          FailureAction = "none";
        };

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "15";
          UMask = "0077";
        };

        script = ''
          set -euo pipefail

          sys=/sys/block/zram0

          # compression and backing device must be set before disksize
          echo zstd > $sys/comp_algorithm
          echo ${backingDevice} > $sys/backing_dev

          # 50% of RAM
          read -r _ total_kb _ < /proc/meminfo
          echo $(( total_kb * 512 )) > $sys/disksize

          # No journal: the root is rebuilt on every boot.
          ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L root -O ^has_journal /dev/zram0
        '';
      };
    };
  };

  fileSystems."/" = {
    device = "/dev/zram0";
    fsType = "ext4";
    # Fresh every boot: nothing to check.
    noCheck = true;
  };
  fileSystems."/nix".neededForBoot = true;
  fileSystems."/persistent".neededForBoot = true;

  # The root is already a zram device; no second one.
  zramSwap.enable = lib.mkForce false;
  services.zram-generator.enable = lib.mkForce false;

  boot.tmp.useTmpfs = false;

  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
    fileSystems = [
      "/nix"
      "/persistent"
    ];
  };
}
