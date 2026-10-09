# modules

| File | Description |
| --- | --- |
| `a-box.nix` | `a-box` options shared by main system and updater; read-only `layout` (partition labels, updater UKI file name) |
| `main.nix` | Imported by every main system: evaluates the updater, sets `a-box` defaults, disables GRUB, mounts root by label; exposes `system.build.a-box-updater` and `system.build.a-box-image` |
| `updater.nix` | Updater UKI whose initrd never switches root; builds the install image (ESP with systemd-boot and updater, root partition grown on first boot) |
| `update.sh` | Updater script run in the initrd: fetches the pointer, installs the system, prunes generations (retrying every 30 s while none is installed), writes boot entries, refreshes the updater, sets a one-shot entry and reboots |
