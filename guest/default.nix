# Firecracker boots `kernel` with `bootArgs`, `rootfs` attached as its read-only root drive:
#
#   kernel ─────────────────┐
#   tools ─┬─ init ─┐       │
#          └────────┴─ rootfs
#
# `init` is the one attribute that decides what the guest does; replace it with
# `guest.overrideScope (final: prev: { init = ...; })`, an executable store path (give a script
# `final.tools` as interpreter and tools).
{
  lib,
  newScope,
  pkgsStatic,

  # Certificate (PEM) of the CA that signs what the host proxy presents to the guest. It is the
  # guest's only trust root, baked into the image: rotating the CA means building a new image.
  proxyCa,

  # Busybox applets on the guest's PATH.
  applets ? [
    "sh"
    "cat"
    "echo"
    "env"
    "ls"
    "mkdir"
    "cp"
    "mv"
    "rm"
    "ln"
    "chmod"
    "chown"
    "grep"
    "sed"
    "head"
    "tail"
    "wc"
    "id"
    "ps"
    "kill"
    "sleep"
    "dmesg"
    "mount"
    "umount"
    "ip"
    "stty"
    "reboot"
  ],
}:
lib.makeScope newScope (self: {
  inherit applets proxyCa;

  # Static binaries: no libc or other closure in the image.
  busybox = pkgsStatic.busybox;
  # Without OpenSSL and readline, which a forwarder does not need. VSOCK needs no flag; tools.nix
  # checks that socat has it.
  socat = pkgsStatic.socat.overrideAttrs (old: {
    buildInputs = [ ];
    configureFlags = (old.configureFlags or [ ]) ++ [
      "--disable-openssl"
      "--disable-readline"
    ];
  });

  # Substitutes a script's @placeholders@ and shellchecks it.
  mkScript = self.callPackage ./mk-script.nix { };

  tools = self.callPackage ./tools.nix { };

  # PID 1, the one file that decides what the guest does. The stub echoes console input.
  init = self.mkScript {
    src = ./init.sh;
    replacements.tools = "${self.tools}";
  };

  # The vmlinux ELF Firecracker loads as `kernel_image_path`.
  kernel = self.callPackage ./kernel.nix { };

  # The read-only image Firecracker attaches as the root drive (`is_root_device`, `is_read_only`).
  rootfs = self.callPackage ./rootfs.nix { };

  # Kernel command line. Firecracker adds `root=/dev/vda`, `ro` and `pci=off` itself, and replaces
  # its own default command line (which turns the serial port off) with this one.
  bootArgs = lib.concatStringsSep " " [
    "console=ttyS0"
    "reboot=k"
    "panic=1"
    "rootfstype=erofs"
    "init=/init"
  ];
})
