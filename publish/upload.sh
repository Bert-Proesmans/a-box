# Usage: a-box-upload STAGE
#
# Uploads a directory staged by a-box-stage with rclone: NARs, then narinfos and nix-cache-info,
# then the pointer. Needs storage credentials only: no nix, no signing key.
#
# Env:
#   A_BOX_CACHE_DEST     rclone destination of the binary cache root, e.g. b2:bucket/nix-cache
#   A_BOX_POINTER_DEST   rclone destination of the pointer file, e.g. b2:bucket/nix-cache/a-box/example

stage=$1

# NARs before narinfos, pointer last: a reader never sees a reference before its data.
# An existing object already describes the same path; re-uploading would only add B2 versions.
rclone copy --ignore-existing --include '/nar/**' "$stage/nix-cache" "$A_BOX_CACHE_DEST"
rclone copy --ignore-existing --include '/*.narinfo' "$stage/nix-cache" "$A_BOX_CACHE_DEST"
rclone copyto --ignore-existing "$stage/nix-cache/nix-cache-info" "$A_BOX_CACHE_DEST/nix-cache-info"
rclone rcat "$A_BOX_POINTER_DEST" <"$stage/pointer"
echo "pointer $A_BOX_POINTER_DEST -> $(cat "$stage/pointer")"
