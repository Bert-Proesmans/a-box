# modules

| File | Description |
| --- | --- |
| `main.nix` | Imported by the main system: root mounted by its GPT name from `layout.nix`, initrd disk drivers for every controller the updater supports (virtio, Hyper-V on top of NixOS's AHCI/NVMe defaults), GRUB disabled because the updater installs the bootloader on the ESP |
