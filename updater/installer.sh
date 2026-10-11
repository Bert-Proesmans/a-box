#!@busybox@/bin/busybox sh
# PID 1 of the installer initrd: a shell in which the administrator prepares disks and installs the
# updater with a-box-install. Leaving the shell reboots.

export PATH=/bin
export HOME=/root

# The initrd carries no mountpoints.
mkdir -p /dev /proc /sys /run /root

mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /run
mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true

cat <<EOF

a-box installer

  lsblk                   list disks
  a-box-install DISK      wipe DISK, partition it for a-box and install the updater
  a-box-install           install the updater on partitions named "@espLabel@" and "@rootLabel@"
  exit                    reboot

EOF

setsid cttyhack sh || true
sync
reboot -f
