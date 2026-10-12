#!@busybox@/bin/busybox sh
# Stand-in for the `udevadm` the disko format script calls; the installer has no udev.
#
#   udevadm trigger   recreate /dev/disk/by-partlabel/<GPT name>, for the partitions of $A_BOX_DISK
#   udevadm settle    nothing to wait for

set -eu

case ${1:-} in
  settle) exit 0 ;;
  trigger) ;;
  *)
    echo "udevadm: unsupported: $*" >&2
    exit 1
    ;;
esac

# The kernel makes the partition nodes (devtmpfs) before the partition table ioctl returns; only
# the by-partlabel links are missing. Partitions of other disks are ignored, so that a leftover
# a-box install on another disk cannot be formatted by mistake.
rm -rf /dev/disk/by-partlabel
mkdir -p /dev/disk/by-partlabel

for u in /sys/block/"${A_BOX_DISK##*/}"/*/uevent; do
  [ -e "$u" ] || continue
  name=$(sed -n 's/^PARTNAME=//p' "$u")
  d=${u%/uevent}
  [ -z "$name" ] || ln -s "/dev/${d##*/}" "/dev/disk/by-partlabel/$name"
done
