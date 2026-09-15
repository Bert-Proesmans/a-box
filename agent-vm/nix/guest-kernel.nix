{ pkgs }:

# Minimal, non-modular guest kernel for the agent-vm Firecracker microVMs
# (docs/agent-vm-host-spec.md §3/§9/§12). Built via nixpkgs' `buildLinux` +
# `structuredExtraConfig` config-fragment mechanism (chunk B1 of
# docs/agent-vm-host-plan.md) rather than a hand-rolled kbuild invocation.
#
# Base config is `allnoconfig` (everything off) with `enableCommonConfig =
# false` (skip nixpkgs' general-purpose-distro config additions) and
# `autoModules = false` (anything we do enable comes in built-in, never as
# a module — there's no initrd to load modules from). The fragment below
# lists every symbol we need turned on; most also pull in their own
# Kconfig-level dependencies (e.g. `select`/`depends on` chains) so the
# list only spells out the leaves, not their transitive requirements.
let
  inherit (pkgs) lib;
  inherit (lib.kernel) yes no;

  # Reuse the source tarball + version nixpkgs already has pinned for this
  # revision, rather than fetching our own kernel tarball out-of-band.
  base = pkgs.linuxKernel.kernels.linux_6_12;
in
(pkgs.buildLinux {
  pname = "agent-vm-guest-kernel";
  inherit (base) src version;

  defconfig = "allnoconfig";
  enableCommonConfig = false;
  autoModules = false;

  structuredExtraConfig = {
    # Everything we enable below is built-in ("y"), never a module ("m") -
    # autoModules = false enforces that. CONFIG_MODULES itself is left on
    # rather than forced to "n": nixpkgs' generic kernel builder
    # (generic.nix's call into build.nix) unconditionally hardcodes
    # `CONFIG_MODULES = "y"` when deciding its multi-output/install-phase
    # shape, with no supported override point - forcing "n" here just
    # desyncs that assumption from the real .config and breaks the
    # `modules_install` postInstall step. Since no driver we enable is
    # ever built as "m", this is module *support* compiled in but unused:
    # there are no .ko files, nothing to load, and no initrd is needed.
    MODULES = yes;

    # Kernel log ring buffer - not required for pid1-init's direct
    # /dev/console write, but invaluable for seeing panics/boot errors in
    # the captured console log while developing/debugging.
    PRINTK = yes;
    BUG = yes;

    # TTY + serial console. Firecracker exposes a legacy 8250/16550 UART as
    # ttyS0 (kernel arg `console=ttyS0`, spec §9) - no virtio-console.
    TTY = yes;
    SERIAL_8250 = yes;
    SERIAL_8250_CONSOLE = yes;

    # Block layer + virtio-blk, for the squashfs/ext4 root and data drives.
    BLOCK = yes;
    BLK_DEV = yes; # gates the "Block devices" submenu VIRTIO_BLK lives in
    VIRTIO_BLK = yes;

    # Firecracker's device model uses virtio over MMIO, not virtio-PCI.
    VIRTIO = yes;
    VIRTIO_MENU = yes;
    VIRTIO_MMIO = yes;
    # Firecracker instantiates virtio-mmio devices by appending
    # `virtio_mmio.device=<size>@<addr>:<irq>` to the kernel cmdline -
    # without this the driver never parses that and no device shows up.
    VIRTIO_MMIO_CMDLINE_DEVICES = yes;

    # Networking core + AF_VSOCK over virtio, for the host<->guest stdio /
    # proxy / bpf channels added in chunks C/F/G.
    NET = yes;
    VSOCKETS = yes;
    VIRTIO_VSOCKETS = yes;

    # Root/pseudo filesystems.
    DEVTMPFS = yes;
    DEVTMPFS_MOUNT = yes;
    TMPFS = yes;
    PROC_FS = yes;
    SYSFS = yes;
    OVERLAY_FS = yes;
    MISC_FILESYSTEMS = yes; # gates the submenu SQUASHFS lives in
    SQUASHFS = yes;
    SQUASHFS_ZLIB = yes; # matches the `-comp gzip` used when building images

    # Exec support for pid1-init and its children - without this the
    # kernel cannot exec `/init` at all (ENOEXEC panic).
    BINFMT_ELF = yes;

    # eBPF + tracing, for chunk G's exec/network/file-open monitoring.
    BPF = yes;
    BPF_SYSCALL = yes;
    BPF_JIT = yes;
    FTRACE = yes; # "Tracers" menuconfig gate; KPROBE_EVENTS/BPF_EVENTS live under it
    KPROBES = yes;
    KPROBE_EVENTS = yes;
    BPF_EVENTS = yes;
    PERF_EVENTS = yes;
  };

  extraMeta.description = "agent-vm minimal non-modular guest kernel (chunk B1)";
}).overrideAttrs (previousAttrs: {
  # x86's kbuild `install` target (what nixpkgs' installTargets always uses
  # for this arch, regardless of the `target` build attribute) hardcodes
  # copying `arch/x86/boot/bzImage` - there's no plain-`target = "vmlinux"`
  # install path. But `make bzImage` unconditionally compiles a plain ELF
  # `vmlinux` first (bzImage is just that plus compressed setup code), and
  # it's left sitting at the top of the build tree - copy it out too, since
  # Firecracker (at least this version) only accepts that uncompressed
  # ELF/PVH image and rejects bzImage with "Invalid Elf magic number".
  # Prepended, not appended: the isModular postInstall this is layered onto
  # `cd`s into a copied-out source tree partway through and never returns,
  # so `vmlinux` (sitting at the top of the real build tree) must be copied
  # out before that happens.
  postInstall = ''
    cp vmlinux $out/vmlinux
  ''
  + (previousAttrs.postInstall or "");
})
