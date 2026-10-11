#!@busybox@/bin/busybox sh
# Installs the a-box updater on a disk.
#
#   a-box-install DISK   wipe DISK, create the ESP and the main root, then persist
#   a-box-install        persist, on partitions the administrator created and named by hand
#
# Persisting copies the updater to \EFI\a-box\updater.efi behind a firmware boot entry first in
# BootOrder, and to \EFI\BOOT\BOOTX64.EFI for firmware that loses or ignores its entries.

set -eu

esp_label=@espLabel@
root_label=@rootLabel@
uki=@uki@
disk=${1:-}

# Not "a-box": the updater replaces firmware entries of that name with its systemd-boot entry.
entry=a-box-updater

# The one partition whose GPT name is $1, as a /dev path; on $disk only, if given.
find_part() {
  local glob=/sys/class/block/*/uevent u d
  [ -z "$disk" ] || glob=/sys/block/${disk##*/}/*/uevent
  for u in $glob; do
    if grep -qx "PARTNAME=$1" "$u" 2>/dev/null; then
      d=${u%/uevent}
      set -- "$@" "/dev/${d##*/}"
    fi
  done

  if [ $# != 2 ]; then
    echo "Expected one partition named $1, found $(($# - 1))" >&2
    return 1
  fi
  echo "$2"
}

echo "===================================================="
echo "              a-box updater installation            "
echo "===================================================="
echo "This script will execute the following steps:"
if [ -n "$disk" ]; then
  echo "  1. Partition and format $disk: ESP \"$esp_label\" (1 GiB, FAT32)"
  echo "     and main root \"$root_label\" (rest of the disk, ext4)."
else
  echo "  1. Find the partitions \"$esp_label\" (FAT) and \"$root_label\" (ext4)."
fi
echo "  2. Copy the updater to the ESP."
echo "  3. Add a firmware boot entry for it, first in BootOrder."
echo ""
[ -z "$disk" ] || echo "WARNING: All data on $disk will be wiped."
echo "===================================================="
echo ""

read -r -p "Press [Enter] to begin installation (or Ctrl+C to abort)..." _

if [ -n "$disk" ]; then
  echo "Partitioning.."
  sfdisk -q --wipe always --wipe-partitions always "$disk" <<EOF
label: gpt
size=1GiB, type=uefi, name="$esp_label"
type=linux, name="$root_label"
EOF

  # sfdisk rereads the table; the kernel creates the partition nodes before it returns.
  mkfs.vfat -F 32 "$(find_part "$esp_label")" >/dev/null
  mkfs.ext4 -q -F "$(find_part "$root_label")"
  echo "Filesystems prepared.."
fi

esp=$(find_part "$esp_label")
find_part "$root_label" >/dev/null

# FAT has no journal: flush the data before the rename makes a file visible.
mkdir -p /mnt
mount -t vfat "$esp" /mnt
mkdir -p /mnt/EFI/a-box /mnt/EFI/BOOT
for f in /mnt/EFI/a-box/updater.efi /mnt/EFI/BOOT/BOOTX64.EFI; do
  cp "$uki" "$f.tmp"
  sync
  mv "$f.tmp" "$f"
done
umount /mnt
echo "Updater copied to $esp.."

# Replace the entries of earlier installs. --create puts the new entry first in BootOrder.
name=${esp##*/}
parent=$(basename "$(dirname "$(readlink -f "/sys/class/block/$name")")")
for num in $(efibootmgr | sed -n "s/^Boot\([0-9A-F]\{4\}\)[* ] $entry[[:space:]].*/\1/p"); do
  efibootmgr -q --delete-bootnum --bootnum "$num"
done
efibootmgr -q --create --disk "/dev/$parent" --part "$(cat "/sys/class/block/$name/partition")" \
  --label "$entry" --loader '\EFI\a-box\updater.efi'
echo "Firmware boot entry added.."

echo "DONE. Please reboot the computer"
