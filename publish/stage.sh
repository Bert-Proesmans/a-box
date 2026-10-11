# Usage: a-box-stage TOPLEVEL OUT
#
# Stages everything publishing TOPLEVEL uploads into the new directory OUT, for a-box-upload:
#   OUT/nix-cache  binary cache of TOPLEVEL's closure minus the paths upstream serves:
#                  signed narinfos, zstd NARs, nix-cache-info
#   OUT/pointer    TOPLEVEL's store path
# Needs the nix store and the signing key, no storage credentials.
#
# Env:
#   A_BOX_SIGNING_KEY    secret key file (nix-store --generate-binary-cache-key)
#   A_BOX_UPSTREAM       cache whose paths are not staged; empty stages everything
#                        (default https://cache.nixos.org)

toplevel=$(realpath "$1")
upstream=${A_BOX_UPSTREAM-https://cache.nixos.org}

# Absolute: the nix copy store URL needs it.
mkdir "$2"
out=$(realpath "$2")
stage=$out/nix-cache
mkdir "$stage"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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
find "$stage" -name '*.narinfo' -printf '%f\n' >"$work/seeded"

nix --extra-experimental-features nix-command \
  copy --to "file://$stage?compression=zstd&secret-key=$A_BOX_SIGNING_KEY" "$toplevel"

# The seeded narinfos are upstream's: drop them, so the stage holds only what to upload.
(cd "$stage" && xargs -r rm -- <"$work/seeded")
echo "$(find "$stage" -name '*.narinfo' | wc -l) of $(wc -l <"$work/closure") paths staged"

echo "$toplevel" >"$out/pointer"
