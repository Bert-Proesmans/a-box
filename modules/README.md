# modules

| File | Description |
| --- | --- |
| `main.nix` | Entry module of the volatile VM host: imports the other modules, keeps GRUB off (the updater installs the bootloader on the ESP), loads the initrd disk drivers for every controller the updater supports (virtio, Hyper-V on top of NixOS's AHCI/NVMe defaults), enables the Hyper-V guest tools and the KVM modules for nested virtualisation |
| `disk.nix` | The attached disk declared once with disko (ESP, zram writeback partition, btrfs with `@nix` and `@persistent`), found by GPT name from `layout.nix`; the installer formats with the same layout |
| `ephemeral-root.nix` | Root as a zram ext4 device built in the initrd on every boot, spilling to the raw zram partition; `/nix` and `/persistent` mounted in the initrd before switch-root; weekly btrfs scrub |
| `preservation.nix` | Keeps only the machine id and ssh host keys across reboots, as symlinks into `/persistent` |
| `strict.nix` | Build fails on any shellcheck finding in generated systemd (and initrd) unit scripts and in the disko scripts; an upstream unit that fails is opted out individually, never globally |
| `guests.nix` | Firecracker microVM guests numbered 1..max: one option set for the bound (`a-box.guests`) and the per-guest policy (`policy.<n>.domains."host[:port]".inject`), static users (`a-box-vm-n`, `a-box-proxy-n`, `a-box-entry-n`, `a-box-log-n`) and runtime directories, the `a-box-guest@n` unit template with its resource slice and sandbox, the `a-box-log@n` console logger that records each guest's serial console to size-rotated files in `/persistent`, and the root-only secrets directories the proxy reads; control is plain `systemctl` |
| `guest-proxy/` | Per-guest mitmproxy forward proxy `a-box-proxy@n` doing full TLS interception behind a vsock-fed entry socket, with a kernel-enforced loopback entry and SSRF guard (nftables and `IPAddressDeny`), an allowlist, credential-injection and access-log addon (`guard.py`, `addon.py`) unit-tested at build time (`test_guard.py`), and the proxy CA key loaded from `/persistent/a-box/secrets/proxy-ca.pem` |
