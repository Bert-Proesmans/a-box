# tests

| File | Description |
| --- | --- |
| `update.nix` | NixOS VM test `a-box-update`, nodes `cache` and `machine`: updater UKI on the ESP of a test disk installs gen 1, installs systemd-boot and hands over with `BootNext`; gen 2 update, gen 3 update with GC of gen 1, failed update, partial download resumed into gen 4, offline boot, firmware boot order unchanged |
| `cache-key.pub` | Nix binary cache public signing key `a-box-test-1` |
| `cache-key.sec` | Nix binary cache secret signing key `a-box-test-1` |
