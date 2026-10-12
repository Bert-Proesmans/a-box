{
  lib,
  runCommand,
  linux,
  buildLinux,
  linuxManualConfig,
}:
let
  inherit (lib.kernel) yes no freeform;

  # Allnoconfig plus these options: only what a Firecracker x86_64 guest needs, all built in, no
  # modules. buildLinux fails the build when kconfig does not honour an option.
  resolved = buildLinux {
    pname = "a-box-guest-kernel";
    inherit (linux) src version;

    defconfig = "allnoconfig";
    enableCommonConfig = false;
    autoModules = false;

    structuredExtraConfig = {
      MODULES = no;
      # Makes the options below visible that kconfig hides without it (io_uring, namespaces, ...).
      EXPERT = yes;

      # Firecracker boots an ELF vmlinux (PVH entry) with ACPI tables and kvm-clock. Its devices are
      # virtio-mmio, not PCI; ACPI initialisation needs PCI anyway.
      "64BIT" = yes;
      SMP = yes;
      # Firecracker allows 32 vCPUs at most; the guests' vCPU count is the host's to choose.
      NR_CPUS = freeform "32";
      X86_LOCAL_APIC = yes;
      X86_IO_APIC = yes;
      X86_X2APIC = yes;
      HYPERVISOR_GUEST = yes;
      PARAVIRT = yes;
      KVM_GUEST = yes;
      PVH = yes;
      ACPI = yes;
      PCI = yes;
      # Devices come from ACPI; the MP table and virtio_mmio.device= on the command line are the
      # legacy paths Firecracker deprecates.
      X86_MPPARSE = no;
      VIRTIO_MMIO_CMDLINE_DEVICES = no;
      HIGH_RES_TIMERS = yes;
      NO_HZ_IDLE = yes;

      # Console: Firecracker's 8250 serial port, the only output of the guest
      PRINTK = yes;
      PRINTK_TIME = yes;
      TTY = yes;
      SERIAL_8250 = yes;
      SERIAL_8250_CONSOLE = yes;
      SERIAL_8250_NR_UARTS = freeform "1";
      SERIAL_8250_RUNTIME_UARTS = freeform "1";
      VT = no;
      UNIX98_PTYS = yes;

      # Root: read-only erofs on a virtio-blk drive over virtio-mmio
      BLOCK = yes;
      BLK_DEV = yes;
      VIRTIO_MENU = yes;
      VIRTIO_MMIO = yes;
      VIRTIO_BLK = yes;
      MISC_FILESYSTEMS = yes;
      EROFS_FS = yes;

      # Userspace: static ELF binaries and #! scripts, writable tmpfs mounts
      BINFMT_ELF = yes;
      BINFMT_SCRIPT = yes;
      DEVTMPFS = yes;
      DEVTMPFS_MOUNT = yes;
      PROC_FS = yes;
      PROC_SYSCTL = yes;
      SYSFS = yes;
      SHMEM = yes;
      TMPFS = yes;
      MULTIUSER = yes;
      FUTEX = yes;
      EPOLL = yes;
      EVENTFD = yes;
      SIGNALFD = yes;
      TIMERFD = yes;
      POSIX_TIMERS = yes;
      FILE_LOCKING = yes;
      ADVISE_SYSCALLS = yes;

      # Host link: AF_VSOCK to the host, loopback TCP for the forwarder that serves the guest's
      # proxy variables. No network device, no IPv6.
      NET = yes;
      NETDEVICES = yes;
      INET = yes;
      IPV6 = no;
      UNIX = yes;
      VSOCKETS = yes;
      VIRTIO_VSOCKETS = yes;
      VSOCKETS_LOOPBACK = no;

      # Less kernel surface for what runs in the guest
      IO_URING = no;
      AIO = no;
      NAMESPACES = no;
      MODIFY_LDT_SYSCALL = no;
      X86_VSYSCALL_EMULATION = no;

      # Hardening; a kernel oops ends the guest instead of leaving it half alive
      CPU_MITIGATIONS = yes;
      STACKPROTECTOR = yes;
      STACKPROTECTOR_STRONG = yes;
      VMAP_STACK = yes;
      FORTIFY_SOURCE = yes;
      HARDENED_USERCOPY = yes;
      SLAB_FREELIST_RANDOM = yes;
      SLAB_FREELIST_HARDENED = yes;
      INIT_ON_ALLOC_DEFAULT_ON = yes;
      PANIC_ON_OOPS = yes;
    };
  };

  # buildLinux builds with CONFIG_MODULES="y" hardcoded (generic.nix), so it would expect a module tree.
  # linuxManualConfig is the builder one layer down; there `config` is respected.
  # It installs the bzImage only; Firecracker loads the vmlinux ELF, so keep that too.
  build =
    (linuxManualConfig {
      inherit (resolved) version src configfile modDirVersion;
      pname = "a-box-guest-kernel";

      config = {
        CONFIG_MODULES = "n";
        CONFIG_RUST = "n";
      };
    }).overrideAttrs
      (old: {
        postInstall = (old.postInstall or "") + ''
          cp vmlinux $out/vmlinux
        '';
      });
in
runCommand "a-box-guest-vmlinux" { passthru = { inherit build; }; } ''
  cp ${build}/vmlinux $out
''
