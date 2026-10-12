#!@busybox@/bin/busybox sh
# Installs the a-box updater on a disk.
#
#   a-box-install DISK   wipe DISK, lay it out with the main system's disko script, then persist
#   a-box-install        persist, on a disk already laid out for a-box
#
# Persisting copies the updater to \EFI\a-box\updater.efi behind a firmware boot entry first in
# BootOrder, and to \EFI\BOOT\BOOTX64.EFI for firmware that loses or ignores its entries.

set -eu

esp_label=@espLabel@
data_label=@dataLabel@
uki=@uki@
# The disko format script, and the text in it that stands for the disk.
format=@diskoFormat@
placeholder=@diskPlaceholder@
disk=${1:-}

# Not "a-box": the updater replaces firmware entries of that name with its systemd-boot entry.
entry=a-box-updater

# The one partition whose GPT name is $1, as a /dev path; on $disk only, if given.
find_part() {
  local sysdir=/sys/class/block u d
  [ -z "$disk" ] || sysdir=/sys/block/${disk##*/}
  for u in "$sysdir"/*/uevent; do
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

# The disk goes into a script and a sed expression: accept plain device paths only.
case $disk in
  "") ;;
  /dev/*[!A-Za-z0-9._/-]*)
    echo "Unsupported characters in $disk" >&2
    exit 1
    ;;
  /dev/*) [ -b "$disk" ] || { echo "$disk is not a block device" >&2; exit 1; } ;;
  *)
    echo "$disk is not a /dev path" >&2
    exit 1
    ;;
esac

echo "===================================================="
echo "              a-box updater installation            "
echo "===================================================="
echo "This script will execute the following steps:"
if [ -n "$disk" ]; then
  echo "  1. Wipe $disk and lay it out as the main system declares: ESP \"$esp_label\","
  echo "     zram partition and data partition \"$data_label\" (btrfs)."
else
  echo "  1. Find the partitions \"$esp_label\" (FAT) and \"$data_label\" (btrfs)."
fi
echo "  2. Copy the updater to the ESP."
echo "  3. Add a firmware boot entry for it, first in BootOrder."
echo ""
[ -z "$disk" ] || echo "WARNING: All data on $disk will be wiped."
echo "===================================================="
echo ""

read -r -p "Press [Enter] to begin installation (or Ctrl+C to abort)..." _

if [ -n "$disk" ]; then
  echo "Partitioning and formatting.."
  # The script keeps what it finds: clear the old table and the old signatures that a new
  # partition would inherit at the same offset (blkid finds them, so mkfs would be skipped).
  for p in /sys/block/"${disk##*/}"/*/partition; do
    [ -e "$p" ] || continue
    d=${p%/partition}
    dd if=/dev/zero of="/dev/${d##*/}" bs=1M count=1 2>/dev/null
  done
  sgdisk -Z "$disk" >/dev/null
  dd if=/dev/zero of="$disk" bs=1M count=1 2>/dev/null

  # A writable copy, with the disk swapped in. $disk is checked above: no sed metacharacters.
  sed "s|$placeholder|$disk|g" "$format" >/tmp/format.sh
  if ! A_BOX_DISK=$disk bash /tmp/format.sh >/tmp/format.log 2>&1; then
    cat /tmp/format.log >&2
    echo "Formatting $disk failed" >&2
    exit 1
  fi
  echo "Disk laid out.."
fi

esp=$(find_part "$esp_label")
find_part "$data_label" >/dev/null

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
for num in $(efibootmgr | sed -n "s/^Boot\([0-9A-F]\{4\}\)[* ] ${entry}[[:space:]].*/\1/p"); do
  efibootmgr -q --delete-bootnum --bootnum "$num"
done
efibootmgr -q --create --disk "/dev/$parent" --part "$(cat "/sys/class/block/$name/partition")" \
  --label "$entry" --loader '\EFI\a-box\updater.efi'
echo "Firmware boot entry added.."

echo "DONE. Please reboot the computer"
