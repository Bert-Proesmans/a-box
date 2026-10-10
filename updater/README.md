# updater

| File | Description |
| --- | --- |
| `default.nix` | Builds the universal updater from plain arguments, independent of the main system: minimal kernel, initrd of static tools (busybox, nix, curl, bash) and UKI. The UKI is installed on an ESP behind a boot entry that is first in `BootOrder`, or netbooted (UKI over UEFI HTTP boot, or kernel + initrd over PXE); the updater never changes `BootOrder` |
| `init.sh` | Initrd `/init`: DHCP (IPv4) and router advertisements (IPv6), mounts the main root and ESP by GPT name, installs the system named by the pointer with `nixos-install --no-bootloader` (retrying every 30 s while none is installed), prunes generations, installs systemd-boot, kernels and initrds of the kept generations on the ESP, registers systemd-boot as a firmware entry outside `BootOrder`, sets `BootNext` and reboots |
| `udhcpc.sh` | DHCP lease script: addresses the interface; the first lease sets the default route and DNS |
| `kernel.config` | Kernel config fragment applied on `allnoconfig`: all drivers built in, no modules; the build fails if a line is not honoured |
| `nix-musl-syscall.patch` | Makes nix build against musl: includes `<sys/syscall.h>` for `SYS_close_range` |
