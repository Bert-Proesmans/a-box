{ pkgs }:

# Throwaway "Device 1 v0" root filesystem (chunk B2): a squashfs image
# containing nothing but the pid1-init static binary as `/init`, just
# enough to prove the boot path works. Chunk H replaces this with the real,
# full closure (coreutils/bash/git/python3/Claude Code CLI/...).
let
  pid1-init = import ./guest-init.nix { inherit pkgs; };
in
pkgs.runCommand "agent-vm-device1-v0.squashfs"
  {
    nativeBuildInputs = [ pkgs.squashfsTools ];
  }
  ''
    mkdir -p root
    install -m 0755 ${pid1-init}/bin/pid1-init root/init

    # B3's pid1-init mounts proc/sysfs/tmpfs onto /proc /sys /tmp at boot
    # (see pseudo_filesystem_mounts() in
    # ../guest/pid1-init/src/mount.rs - keep these two lists in sync).
    # /dev isn't mounted by pid1-init itself, but the kernel's own
    # DEVTMPFS_MOUNT=y auto-mounts devtmpfs onto it before init runs
    # (guest-kernel.nix), so it still needs to exist as a target.
    # The root filesystem is this read-only squashfs, so none of these
    # mount targets can be created at runtime - they must already exist
    # as empty directories in the image.
    mkdir -p root/proc root/sys root/dev root/tmp

    mksquashfs root $out -all-root -no-xattrs -comp zstd -Xcompression-level -4 -noappend
  ''
