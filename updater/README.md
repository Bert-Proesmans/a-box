# updater

| File | Description |
| --- | --- |
| `default.nix` | Builds the universal updater from plain arguments, independent of the main system: minimal kernel, initrd of static tools (busybox, nix, curl, bash) and UKI, plus the installer UKI (own kernel with keyboards and Hyper-V, VMware and QEMU disk, keyboard and display drivers; initrd with disk tools, `a-box-install` and the updater UKI). Outputs `uki`, `initrd`, `kernel`, `iso` (updater), `installerIso` and `netboot` (updater UKI and `boot.ipxe`); the updater never changes `BootOrder` |
| `init.sh` | Initrd `/init`: DHCP (IPv4) and router advertisements (IPv6), Google Public DNS when the pointer host does not resolve, mounts the main root and ESP by GPT name, installs the system named by the pointer with `nixos-install --no-bootloader` (retrying every 30 s while none is installed), prunes generations, installs systemd-boot, kernels and initrds of the kept generations on the ESP, registers systemd-boot as a firmware entry outside `BootOrder`, sets `BootNext` and reboots |
| `iso.nix` | Builds a reproducible UEFI-only hybrid image (CD or disk) whose only content is an appended ESP holding the given UKI at `/EFI/BOOT/BOOTX64.EFI` |
| `installer.sh` | Installer initrd `/init`: mounts the kernel filesystems, prints usage and runs a shell; leaving the shell reboots |
| `a-box-install.sh` | `a-box-install [DISK]`: wipes and partitions DISK (ESP 1 GiB FAT32, main root ext4) or finds the partitions by GPT name, then copies the updater to `\EFI\a-box\updater.efi` behind a firmware boot entry first in `BootOrder`, and to `\EFI\BOOT\BOOTX64.EFI` |
| `udhcpc.sh` | DHCP lease script: replaces the interface's IPv4 addresses, leaving IPv6 ones; the first lease sets the default route and DNS |
| `kernel.nix` | Builds the minimal updater kernel: `allnoconfig` plus the options the updater needs and caller-supplied extra config, all built in, no modules; the build fails if an option is not honoured |
| `nix-musl-syscall.patch` | Makes nix build against musl: includes `<sys/syscall.h>` for `SYS_close_range` |
