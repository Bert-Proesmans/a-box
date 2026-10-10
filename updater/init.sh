#!@busybox@/bin/busybox sh
# PID 1 of the updater initrd. Brings up the network (DHCP for IPv4, router advertisements for
# IPv6; Google Public DNS when the pointer host does not resolve), mounts the main root and ESP,
# installs the system named by the pointer (retrying every 30s while none is installed) and prunes
# old generations. Then it installs systemd-boot, kernels and initrds of the kept generations on
# the ESP, registers systemd-boot as a firmware boot entry that is not in BootOrder, makes it
# BootNext and reboots. The boot order is never changed.

pointer_url=@pointerUrl@
keep=@keepGenerations@
esp_label=@espLabel@
root_label=@rootLabel@

export PATH=/bin

# The initrd carries no mountpoints.
mkdir -p /dev /proc /sys

mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /run
mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true

set -e

root=/sysroot
esp=$root/boot
profiles=$root/nix/var/nix/profiles
profile=$profiles/system
loader=EFI/a-box/systemd-bootx64.efi
loader_efi='\EFI\a-box\systemd-bootx64.efi'

# stderr: functions whose stdout is captured log too.
log() { echo "a-box: $*" >&2; }

fatal() {
  log "$*"
  dmesg | tail -n 40
  log "block devices: $(ls /sys/class/block 2>&1)"
  log "emergency shell; exit reboots"
  setsid cttyhack sh || true
  reboot -f
}

ether_ifaces() {
  local n
  for n in /sys/class/net/*; do
    if [ "$(cat "$n/type")" = 1 ]; then
      echo "${n##*/}"
    fi
  done
}

# IPv4: DHCP; the first lease wins the default route and DNS (see udhcpc.sh). IPv6: the kernel
# configures addresses and routes from router advertisements. Up means either one.
network() {
  local i=0 ifc
  rm -f /run/net-up
  ip link set lo up

  # USB NICs enumerate late.
  while [ -z "$(ether_ifaces)" ] && [ "$i" -lt 30 ]; do
    sleep 1
    i=$((i + 1))
  done

  for ifc in $(ether_ifaces); do
    ip link set "$ifc" up
    udhcpc -i "$ifc" -n -q -t 10 -T 3 -s /etc/udhcpc.sh >/dev/null 2>&1 &
  done

  i=0
  while [ ! -e /run/net-up ] && [ "$i" -lt 60 ]; do
    # Do not wait out a missing DHCP server when IPv6 is configured.
    if [ "$i" -ge 15 ] && [ -n "$(ip -6 route show default)" ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  [ -e /run/net-up ] || log "no DHCP lease"
}

# The partition whose GPT name is $1, as a /dev path.
find_part() {
  local u d
  for u in /sys/class/block/*/uevent; do
    if grep -qx "PARTNAME=$1" "$u"; then
      d=${u%/uevent}
      echo "/dev/${d##*/}"
      return 0
    fi
  done
  return 1
}

# mount_part LABEL TYPE OPTIONS DIR; sets $part_dev.
mount_part() {
  local i=0
  part_dev=
  while ! part_dev=$(find_part "$1") && [ "$i" -lt 60 ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -n "$part_dev" ] || fatal "no partition named $1"

  mkdir -p "$4"
  mount -t "$2" -o "$3" "$part_dev" "$4" || fatal "cannot mount $part_dev"
}

# Links inside the main store are absolute in its own namespace.
current_system() {
  local link
  link=$(readlink "$profile") || return 0
  readlink "$profiles/$link"
}

# /nix/store/<32 chars of [0-9a-z]>-<name without slash>
valid_store_path() {
  local rest=${1#/nix/store/} hash
  case $1 in
    /nix/store/????????????????????????????????-?*) ;;
    *) return 1 ;;
  esac
  hash=${rest%"${rest#????????????????????????????????}"}
  case $hash in *[!0-9a-z]*) return 1 ;; esac
  case $rest in */*) return 1 ;; esac
}

# Google Public DNS. On SLAAC the resolver stays unknown: the kernel hands RDNSS options of router
# advertisements to userspace, which runs no listener, and no DHCPv6 client runs. musl then asks
# 127.0.0.1. musl queries all nameservers at once and takes the first answer, so the fallback
# replaces the configured servers instead of joining them.
fallback_dns='nameserver 2001:4860:4860::8888
nameserver 2001:4860:4860::8844
nameserver 8.8.8.8'

get_pointer() {
  curl --fail --silent --show-error --location --max-time 30 \
    --retry 3 --retry-all-errors "$pointer_url"
}

fetch_pointer() {
  local want rc=0 prev
  want=$(get_pointer) || rc=$?

  # curl exit 6: host not resolved. Nix resolves the substituters through the same file later.
  prev=$(cat /etc/resolv.conf 2>/dev/null) || true
  if [ "$rc" = 6 ] && [ "$prev" != "$fallback_dns" ]; then
    log "name resolution failed; retrying with Google Public DNS"
    echo "$fallback_dns" >/etc/resolv.conf
    rc=0
    want=$(get_pointer) || rc=$?
    if [ "$rc" = 6 ]; then
      echo "$prev" >/etc/resolv.conf
    fi
  fi
  [ "$rc" = 0 ] || return 1

  want=$(echo "$want" | tr -d '[:space:]')
  if ! valid_store_path "$want"; then
    log "pointer is not a store path: $want"
    return 1
  fi
  echo "$want"
}

# Errors are handled explicitly: set -e does not apply inside a function called from `||`.
install_system() {
  local want=$1
  log "fetching $want"
  nix-store --store "$root" --realise "$want" >/dev/null || return 1

  # Check before the profile points at it.
  if [ ! -f "$root$want/init" ] || [ ! -L "$root$want/kernel" ] ||
    [ ! -L "$root$want/initrd" ] || [ ! -L "$root$want/systemd" ] ||
    [ ! -f "$root$want/kernel-params" ]; then
    log "$want is not a NixOS system"
    return 1
  fi

  nixos-install --root "$root" --system "$want" --no-bootloader --no-root-passwd \
    --no-channel-copy || return 1

  log "pruning to $keep generations"
  nix-env --store "$root" --profile "$profile" --delete-generations "+$keep" || return 1
  nix-store --store "$root" --gc || return 1
}

try_update() {
  local want have
  if ! want=$(fetch_pointer); then
    log "no pointer; keeping current system"
    return 0
  fi

  have=$(current_system)
  if [ "$want" = "$have" ]; then
    log "up to date"
    return 0
  fi

  if ! install_system "$want"; then
    log "update failed; keeping current system"
  fi
}

# /nix/store/<hash>-linux-6.12/bzImage -> <hash>-linux-6.12-bzImage
esp_name() {
  local p=${1#/nix/store/}
  echo "$p" | tr / -
}

# FAT has no journal: flush data before the rename makes the file visible.
copy_to_esp() {
  local src=$1 dst=$2
  cp "$src" "$dst.tmp"
  sync
  mv "$dst.tmp" "$dst"
}

# One Type #1 boot entry per kept generation; kernels and initrds live in /a-box.
write_entries() {
  local link gen sys kernel initrd kname iname f
  mkdir -p "$esp/loader/entries" "$esp/a-box"
  : >/run/keep

  for link in "$profiles"/system-*-link; do
    [ -L "$link" ] || continue
    gen=${link##*/system-}
    gen=${gen%-link}
    sys=$(readlink "$link")

    kernel=$(readlink "$root$sys/kernel")
    initrd=$(readlink "$root$sys/initrd")
    kname=$(esp_name "$kernel")
    iname=$(esp_name "$initrd")
    [ -e "$esp/a-box/$kname" ] || copy_to_esp "$root$kernel" "$esp/a-box/$kname" || return 1
    [ -e "$esp/a-box/$iname" ] || copy_to_esp "$root$initrd" "$esp/a-box/$iname" || return 1

    {
      echo "title a-box"
      echo "version Generation $gen"
      echo "sort-key a-box"
      echo "linux /a-box/$kname"
      echo "initrd /a-box/$iname"
      echo "options init=$sys/init $(cat "$root$sys/kernel-params")"
    } >"$esp/loader/entries/a-box-$gen.conf.tmp" || return 1
    mv "$esp/loader/entries/a-box-$gen.conf.tmp" "$esp/loader/entries/a-box-$gen.conf" || return 1

    printf '%s\n' "$kname" "$iname" "a-box-$gen.conf" >>/run/keep
  done

  for f in "$esp"/a-box/* "$esp"/loader/entries/a-box-*; do
    [ -e "$f" ] || continue
    grep -qxF "${f##*/}" /run/keep || rm -f "$f"
  done
}

# The main system carries the boot manager it was built with. Newest generation boots by default.
install_loader() {
  local src=$root$(readlink "$root$1/systemd")/lib/systemd/boot/efi/systemd-bootx64.efi
  mkdir -p "$esp/EFI/a-box"
  cmp -s "$src" "$esp/$loader" || copy_to_esp "$src" "$esp/$loader" || return 1

  cat >"$esp/loader/loader.conf" <<EOF
timeout 0
editor no
EOF
}

boot_nums() {
  efibootmgr | sed -n 's/^Boot\([0-9A-F][0-9A-F][0-9A-F][0-9A-F]\)[* ] a-box[[:space:]].*/\1/p'
}

# A firmware entry for the bootloader, outside BootOrder, then boot it once.
register_loader() {
  local name=${part_dev##*/} part disk num
  part=$(cat "/sys/class/block/$name/partition") || return 1
  disk=$(readlink -f "/sys/class/block/$name") || return 1
  disk=/dev/$(basename "$(dirname "$disk")")

  for num in $(boot_nums); do
    efibootmgr -q --delete-bootnum --bootnum "$num" || return 1
  done
  efibootmgr -q --create-only --disk "$disk" --part "$part" --label a-box \
    --loader "$loader_efi" || return 1

  num=$(boot_nums | sed -n 1p)
  [ -n "$num" ] || return 1
  efibootmgr -q --bootnext "$num"
}

handoff() {
  mount_part "$esp_label" vfat umask=0077 "$esp"
  write_entries || return 1
  install_loader "$1" || return 1
  sync
  register_loader || return 1
}

mount_part "$root_label" ext4 noatime "$root"
network

# The initrd runs from RAM; keep nix's cache and scratch files on the main disk.
export HOME=$root/nix/var/a-box
export TMPDIR=$HOME/tmp
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

try_update
while [ -z "$(current_system)" ]; do
  log "no system installed; retrying in 30s"
  sleep 30
  [ -e /run/net-up ] || network
  try_update
done

sys=$(current_system)
log "handing over to $sys"
if ! handoff "$sys"; then
  # A failing ESP step must not strand the box: boot the bootloader that is already installed.
  log "bootloader update failed"
  num=$(boot_nums | sed -n 1p)
  if [ -n "$num" ]; then
    efibootmgr -q --bootnext "$num" || fatal "cannot set BootNext"
  else
    fatal "no bootloader entry to hand over to"
  fi
fi

sync
umount "$esp" || true
umount "$root" || true
log "rebooting"
reboot -f
