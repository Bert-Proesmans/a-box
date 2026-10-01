{ pkgs }:

# Minimal, non-modular guest kernel for Firecracker microVMs.
# Built via nixpkgs' buildLinux + structuredExtraConfig (kernel config
# fragments), not a hand-rolled kbuild invocation.
#
# Firecracker rejects the default bzImage ("Invalid Elf magic number" at
# InstanceStart) - it wants the uncompressed vmlinux ELF. `make bzImage`
# builds vmlinux anyway as an intermediate step; copied out below.
let
  inherit (pkgs) lib;
  inherit (lib.kernel) yes no;

  base = pkgs.linuxKernel.kernels.linux_6_12; # pinned kernel source + version

  # buildLinux (generic.nix) resolves structuredExtraConfig into a real
  # .config - only the .config is wanted, not this derivation's build.
  #
  # generic.nix hardcodes CONFIG_MODULES="y" calling build.nix, ignoring
  # whatever is configured here, no override point: `.override {config
  # = ...}` is silently discarded (nothing in generic.nix reads it), and
  # even build.nix's own override gets clobbered the instant generic.nix's
  # makeOverridable wrapping re-decorates the result (checked directly
  # against lib.makeOverridable's source).
  #
  # `.configfile` below is its own derivation - reading it doesn't build
  # the (mislabeled-modular) kernel this produces.
  resolvedConfig = pkgs.buildLinux {
    pname = "agent-vm-guest-kernel";
    inherit (base) src version;

    defconfig = "allnoconfig"; # everything off; enable only what's listed
    enableCommonConfig = false; # skip nixpkgs' distro-kernel additions
    autoModules = false; # never "m" - no initrd to load modules from

    structuredExtraConfig = {
      MODULES = no; # respected below via linuxManualConfig, not here

      # boot log, for panics in the captured console
      PRINTK = yes;
      BUG = yes;

      # ttyS0 UART console (`console=ttyS0`) - no virtio-console
      TTY = yes;
      SERIAL_8250 = yes;
      SERIAL_8250_CONSOLE = yes;

      # virtio-blk root/data drives
      BLOCK = yes;
      BLK_DEV = yes; # gates the submenu VIRTIO_BLK lives in
      VIRTIO_BLK = yes;

      # Firecracker uses virtio-mmio, not virtio-pci
      VIRTIO = yes;
      VIRTIO_MENU = yes;
      VIRTIO_MMIO = yes;
      VIRTIO_MMIO_CMDLINE_DEVICES = yes; # parses Firecracker's
      # `virtio_mmio.device=<size>@<addr>:<irq>` cmdline arg

      # AF_VSOCK over virtio: host<->guest stdio/proxy/bpf (chunks C/F/G)
      NET = yes;
      VSOCKETS = yes;
      VIRTIO_VSOCKETS = yes;

      # root + pseudo filesystems
      DEVTMPFS = yes;
      DEVTMPFS_MOUNT = yes;
      TMPFS = yes;
      PROC_FS = yes;
      SYSFS = yes;
      OVERLAY_FS = yes;
      MISC_FILESYSTEMS = yes; # gates the submenu SQUASHFS lives in
      SQUASHFS = yes;
      SQUASHFS_ZSTD = yes; # matches image builders' `-comp zstd`

      BINFMT_ELF = yes; # exec /init - without it, ENOEXEC panic

      # eBPF + tracing (chunk G: exec/network/file-open monitoring)
      BPF = yes;
      BPF_SYSCALL = yes;
      BPF_JIT = yes;
      FTRACE = yes; # gates KPROBE_EVENTS/BPF_EVENTS
      KPROBES = yes;
      KPROBE_EVENTS = yes;
      BPF_EVENTS = yes;
      PERF_EVENTS = yes;
    };
  };

  # linuxManualConfig = callPackage build.nix {} (nixpkgs' own name for
  # it) - one layer below generic.nix's hardcoding, `config` respected.
  kernel = pkgs.linuxManualConfig {
    inherit (resolvedConfig) version src configfile modDirVersion;
    pname = "agent-vm-guest-kernel";

    # non-modular: single "out" output, no modules_install machinery.
    # FW_LOADER/RUST mirror generic.nix's own hardcoded values.
    config = {
      CONFIG_MODULES = "n";
      CONFIG_FW_LOADER = "y";
      CONFIG_RUST = "n";
    };

    extraMeta.description = "agent-vm minimal non-modular guest kernel";
  };
in
kernel.overrideAttrs (previousAttrs: {
  # x86's install target always copies arch/x86/boot/bzImage, regardless
  # of `target` - grab vmlinux (built anyway, see file header) by hand.
  # Non-modular means no competing postInstall block, so order is moot.
  postInstall = (previousAttrs.postInstall or "") + ''
    cp vmlinux $out/vmlinux
  '';
})
