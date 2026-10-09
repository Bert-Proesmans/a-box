# publish

| File | Description |
| --- | --- |
| `default.nix` | Packages `publish.sh` as `a-box-publish` (coreutils, curl, findutils, gnused, rclone; nix from the host) |
| `publish.sh` | Signs the closure of `TOPLEVEL` into a staging cache, skipping paths upstream serves; uploads NARs, then narinfos, then the pointer |
