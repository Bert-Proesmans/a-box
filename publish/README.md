# publish

| File | Description |
| --- | --- |
| `default.nix` | Packages `stage.sh` as `a-box-stage` (coreutils, curl, findutils; nix from the host) and `upload.sh` as `a-box-upload` (coreutils, rclone), returned as `{ stage, upload }` |
| `stage.sh` | Stages the closure of `TOPLEVEL` into a directory for `a-box-upload`: a signed zstd binary cache, skipping paths upstream serves, plus the pointer; needs the signing key, no storage credentials |
| `upload.sh` | Uploads a stage with rclone: NARs, then narinfos and `nix-cache-info`, then the pointer; needs storage credentials only |
