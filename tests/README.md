# tests

| File | Description |
| --- | --- |
| `update.nix` | NixOS VM test `a-box-update`, nodes `cache` and `machine`: updater UKI on the ESP of a test disk reaches the cache by name through DHCP-provided DNS, installs gen 1, installs systemd-boot and hands over with `BootNext`; gen 2 update, gen 3 update with GC of gen 1, failed update, partial download resumed into gen 4, offline boot, gen 5 on IPv6-only network (router advertisements, no DHCP, no DNS) through the Google Public DNS fallback, firmware boot order unchanged |
| `cache-key.pub` | Nix binary cache public signing key `a-box-test-1` |
| `cache-key.sec` | Nix binary cache secret signing key `a-box-test-1` |
