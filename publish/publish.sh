# Usage: a-box-publish TOPLEVEL
#
# Signs the closure of TOPLEVEL into a staging binary cache with nix copy, seeding it with narinfos
# fetched from upstream so those paths are skipped. Uploads new NARs, then narinfos and
# nix-cache-info, with rclone, and writes the toplevel store path to the pointer file last.
#
# Env:
#   A_BOX_SIGNING_KEY    secret key file (nix-store --generate-binary-cache-key)
#   A_BOX_CACHE_DEST     rclone destination of the binary cache root, e.g. b2:bucket/nix-cache
#   A_BOX_POINTER_DEST   rclone destination of the pointer file, e.g. b2:bucket/a-box/example
#   A_BOX_UPSTREAM       cache whose paths are not uploaded; empty uploads everything
#                        (default https://cache.nixos.org)

toplevel=$(realpath "$1")
upstream=${A_BOX_UPSTREAM-https://cache.nixos.org}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage=$work/cache
mkdir "$stage"

nix-store --query --requisites "$toplevel" >"$work/closure"

# Seed the stage with upstream's narinfos. nix copy treats those paths as present,
# so it only packs and signs the rest. A failed lookup only costs an extra upload.
if [[ -n $upstream ]]; then
  while read -r path; do
    hash=${path#/nix/store/}
    hash=${hash%%-*}
    printf 'url = "%s/%s.narinfo"\noutput = "%s/%s.narinfo"\n' "$upstream" "$hash" "$stage" "$hash"
  done <"$work/closure" >"$work/curl.conf"
  curl --parallel --parallel-max 32 --fail --remove-on-error --silent --config "$work/curl.conf" || true
fi
find "$stage" -name '*.narinfo' -printf '%f\n' | sort >"$work/seeded"

nix --extra-experimental-features nix-command \
  copy --to "file://$stage?compression=zstd&secret-key=$A_BOX_SIGNING_KEY" "$toplevel"

# New narinfos and the NARs they reference.
find "$stage" -name '*.narinfo' -printf '%f\n' | sort | comm -23 - "$work/seeded" >"$work/narinfos"
(cd "$stage" && xargs -r sed -n 's/^URL: //p' <"$work/narinfos") >"$work/nars"
echo "$(wc -l <"$work/narinfos") of $(wc -l <"$work/closure") paths to upload"

# NARs before narinfos, pointer last: a reader never sees a reference before its data.
# An existing object already describes the same path; re-uploading would only add B2 versions.
rclone copy --ignore-existing --files-from "$work/nars" "$stage" "$A_BOX_CACHE_DEST"
rclone copy --ignore-existing --files-from "$work/narinfos" "$stage" "$A_BOX_CACHE_DEST"
rclone copyto --ignore-existing "$stage/nix-cache-info" "$A_BOX_CACHE_DEST/nix-cache-info"
echo "$toplevel" | rclone rcat "$A_BOX_POINTER_DEST"
echo "pointer $A_BOX_POINTER_DEST -> $toplevel"
