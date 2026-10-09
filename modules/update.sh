# Initrd updater for the root at /sysroot and its ESP at /sysroot/boot. Fetches a store-path pointer
# from A_BOX_POINTER_URL, installs it as the system profile and prunes to A_BOX_KEEP generations,
# retrying every 30s while no system exists. Writes boot entries, kernels and initrds to the ESP,
# refreshes the updater image (A_BOX_UPDATER_FILE), then sets a one-shot entry and reboots.

# -E: the ERR trap installed below also fires inside functions.
set -Eeuo pipefail
shopt -s nullglob

root=/sysroot
esp=/sysroot/boot
profiles=$root/nix/var/nix/profiles
profile=$profiles/system

# The initrd runs from RAM; keep nix's cache and scratch files on the main disk.
export HOME=$root/nix/var/a-box
export TMPDIR=$HOME/tmp
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

log() { echo "a-box: $*"; }

# Links inside the main store point into its own namespace; resolve them under $root.
readlink_root() { readlink "$root$1"; }

current_generation() {
  local link
  link=$(readlink "$profile" 2>/dev/null) || return 0
  link=${link#system-}
  echo "${link%-link}"
}

generations() {
  local link gen
  for link in "$profiles"/system-*-link; do
    gen=${link##*/system-}
    echo "${gen%-link}"
  done
}

current_system() {
  local gen
  gen=$(current_generation)
  [[ -n $gen ]] && readlink "$profiles/system-$gen-link"
  return 0
}

fetch_pointer() {
  local want
  want=$(curl --fail --silent --show-error --location --max-time 30 \
    --retry 3 --retry-all-errors "$A_BOX_POINTER_URL") || return 1
  want=${want//[[:space:]]/}

  if [[ ! $want =~ ^/nix/store/[0-9a-z]{32}-[^/]+$ ]]; then
    log "pointer is not a store path: $want"
    return 1
  fi
  echo "$want"
}

# Errors are handled explicitly: set -e does not apply inside a function called from `||`.
install_system() {
  local want=$1
  log "fetching $want"
  nix-store --realise "$want" >/dev/null || return 1

  if ! jq -e '."org.nixos.bootspec.v1".init' "$root$want/boot.json" >/dev/null; then
    log "$want is not a NixOS system"
    return 1
  fi

  nix-env --profile "$profile" --set "$want" || return 1
  mkdir -p "$root/etc" && touch "$root/etc/NIXOS" || return 1

  log "pruning to $A_BOX_KEEP generations"
  nix-env --profile "$profile" --delete-generations "+$A_BOX_KEEP" || return 1
  nix-store --gc || return 1
}

try_update() {
  local want have
  if ! want=$(fetch_pointer); then
    log "no pointer; keeping current system"
    return 0
  fi

  have=$(current_system)
  if [[ $want == "$have" ]]; then
    log "up to date"
    return 0
  fi

  if ! install_system "$want"; then
    log "update failed; keeping current system"
    df -h / "$root"
  fi
}

# /nix/store/<hash>-linux-6.12/bzImage -> <hash>-linux-6.12-bzImage
esp_name() {
  local p=${1#/nix/store/}
  echo "${p//\//-}"
}

copy_to_esp() {
  local src=$1 name=$2
  [[ -e $esp/a-box/$name ]] && return 0
  cp "$root$src" "$esp/a-box/$name.tmp"
  # FAT has no journal: flush data before the rename makes the file visible.
  sync "$esp/a-box/$name.tmp"
  mv "$esp/a-box/$name.tmp" "$esp/a-box/$name"
}

# One Type #1 boot entry per kept generation; kernels and initrds live in /a-box.
write_entries() {
  local gen spec kernel initrd kname iname f
  local -A keep=()
  mkdir -p "$esp/loader/entries" "$esp/a-box"

  for gen in $(generations); do
    spec=$root$(readlink "$profiles/system-$gen-link")/boot.json

    kernel=$(jq -r '."org.nixos.bootspec.v1".kernel' "$spec")
    initrd=$(jq -r '."org.nixos.bootspec.v1".initrd' "$spec")
    kname=$(esp_name "$kernel")
    iname=$(esp_name "$initrd")
    copy_to_esp "$kernel" "$kname"
    copy_to_esp "$initrd" "$iname"

    jq -r --arg gen "$gen" --arg k "$kname" --arg i "$iname" '
      ."org.nixos.bootspec.v1" |
      "title \(.label)\n" +
      "version Generation \($gen)\n" +
      "sort-key a-box\n" +
      "linux /a-box/\($k)\n" +
      "initrd /a-box/\($i)\n" +
      "options init=\(.init) \(.kernelParams | join(" "))"
    ' "$spec" >"$esp/loader/entries/a-box-$gen.conf.tmp"
    mv "$esp/loader/entries/a-box-$gen.conf.tmp" "$esp/loader/entries/a-box-$gen.conf"

    keep[$kname]=1
    keep[$iname]=1
    keep[a-box-$gen.conf]=1
  done

  for f in "$esp"/a-box/* "$esp"/loader/entries/a-box-*.conf; do
    [[ -n ${keep[${f##*/}]:-} ]] || rm -f "$f"
  done
}

# The running system carries the updater it expects; install it when it differs.
refresh_updater() {
  local link new target=$esp/EFI/Linux/$A_BOX_UPDATER_FILE
  link=$(readlink_root "$(current_system)/$A_BOX_UPDATER_FILE") || return 0
  new=$root$link
  cmp -s "$new" "$target" && return 0

  log "installing new updater"
  cp "$new" "$target.tmp"
  sync "$target.tmp"
  mv "$target.tmp" "$target"
}

# A system is installed; a failing ESP step must not leave the box in emergency mode.
# Boot the newest generation that still has an entry.
boot_fallback() {
  local gen
  log "post-update step failed"
  for gen in $(generations | sort -rn); do
    if [[ -e $esp/loader/entries/a-box-$gen.conf ]] && bootctl set-oneshot "a-box-$gen.conf"; then
      log "rebooting into generation $gen"
      systemctl reboot
      sleep infinity
    fi
  done
  exit 1
}

try_update
while [[ -z $(current_system) ]]; do
  log "no system installed; retrying in 30s"
  sleep 30
  try_update
done

trap boot_fallback ERR
write_entries
refresh_updater
sync

gen=$(current_generation)
bootctl set-oneshot "a-box-$gen.conf"
log "rebooting into generation $gen"
systemctl reboot

# Hold initrd.target back until the reboot job stops this unit.
sleep infinity
