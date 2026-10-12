# modules

| File | Description |
| --- | --- |
| `main.nix` | Entry module of the volatile VM host: imports the other modules, keeps GRUB off (the updater installs the bootloader on the ESP), loads the initrd disk drivers for every controller the updater supports (virtio, Hyper-V on top of NixOS's AHCI/NVMe defaults), enables the Hyper-V guest tools and the KVM modules for nested virtualisation |
| `disk.nix` | The attached disk declared once with disko (ESP, zram writeback partition, btrfs with `@nix` and `@persistent`), found by GPT name from `layout.nix`; the installer formats with the same layout |
| `ephemeral-root.nix` | Root as a zram ext4 device built in the initrd on every boot, spilling to the raw zram partition; `/nix` and `/persistent` mounted in the initrd before switch-root; weekly btrfs scrub |
| `preservation.nix` | Keeps only the machine id and ssh host keys across reboots, as symlinks into `/persistent` |
| `strict.nix` | Build fails on any shellcheck finding in generated systemd (and initrd) unit scripts and in the disko scripts; an upstream unit that fails is opted out individually, never globally |
