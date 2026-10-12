# guest

| File | Description |
| --- | --- |
| `default.nix` | `lib.makeScope` package set of the Firecracker guest image, independent of the main system and callable with the one argument `proxyCa` (the host proxy's CA certificate): the busybox applets on the guest's `PATH`, the static `busybox` and `socat`, `tools`, `init`, and the three artifacts the host consumes, `kernel`, `rootfs` and `bootArgs` |
| `kernel.nix` | Builds the guest kernel: `allnoconfig` plus what a Firecracker x86_64 guest needs (ACPI boot, virtio-mmio block, vsock, 8250 serial console, erofs, tmpfs, hardening), all built in, no modules; the build fails if an option is not honoured; the result is the `vmlinux` ELF itself |
| `tools.nix` | Builds the guest's only executables: one busybox binary with a symlink per allowed applet, and socat with VSOCK support; copied out of their packages so that the closure is the path itself |
| `rootfs.nix` | Builds the read-only erofs image: the closure of `init` and `tools` under `/nix/store`, empty mountpoints, `/init`, `/bin` and the trust store holding the proxy CA alone; reproducible, one file |
| `init.sh` | PID 1 of the guest, a stub echo server: points the TLS clients at the image's trust store, mounts the writable tmpfs paths, prints a banner on the serial console and echoes input lines back; the one file to replace with the real guest setup |
| `mk-script.nix` | `mkScript { src; replacements; }`: substitutes the `@placeholders@` of a busybox shell script and fails the build on any shellcheck (busybox dialect) finding |

## Interface

The host consumes four attributes and nothing else:

- `kernel`: store path that is the `vmlinux` ELF; Firecracker's `kernel_image_path`.
- `rootfs`: store path of the erofs image file; Firecracker drive with `is_root_device = true`, `is_read_only = true`. Firecracker adds `root=/dev/vda ro` and `pci=off` to the command line itself.
- `bootArgs`: the kernel command line (`boot_args`). It replaces Firecracker's default command line, which switches the serial port off.
- `proxyCa`: the CA certificate the image trusts; the host proxy refuses to start with a key that does not belong to it.

## Guest

- Boot: Firecracker with ACPI and virtio-mmio devices (its default; no `--enable-pci`). `reboot=k` makes a guest reboot a Firecracker exit (Firecracker's `kernel-policy.md`); the stub ends with `reboot -f`.
- Console: `ttyS0` is the only output. The kernel enables 1 UART.
- Root: read-only erofs, mounted by the kernel; `/dev` is devtmpfs, mounted by the kernel. `init` mounts tmpfs on `/tmp`, `/run`, `/var`, `/home` and `/root`; everything else is read-only.
- Store: `/nix/store` holds the closure of `init` and `tools` only.
- PATH: `/bin`, which is `tools`: the applets named in the `applets` argument of `default.nix`, each a symlink to the one busybox binary, and `socat`. The busybox binary itself holds every applet.
- Kernel: no modules, no network device, no IPv6, no namespaces, no io_uring, 32 CPUs at most. `AF_VSOCK` and loopback TCP are built in.

## Replacing init

`init` is the only attribute that decides what the guest does. Replace it with `guest.overrideScope (final: prev: { init = ...; })`; the new value is an executable store path, e.g. `final.mkScript { src = ./my-init.sh; replacements.tools = "${final.tools}"; }`. It runs as PID 1 and has to mount `/proc`, `/sys` and the tmpfs paths itself. Extra executables go into `tools` through `applets` or a replaced `tools`; `rootfs` takes the closure of both.

## Trust

The proxy CA certificate (`proxyCa`, `keys/guest-proxy-ca.pem` for the real image) is the guest's only trust root, baked in at build time: `/etc/ssl/certs/ca-certificates.crt`, also reachable as `/etc/ssl/certs/ca-bundle.crt` and `/etc/ssl/cert.pem`. Rotating the CA means building a new image. The host proxy terminates every TLS connection of the guest with a certificate for the requested host, signed by that CA. `init` exports `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE` and `NODE_EXTRA_CA_CERTS` pointing at the file; a replacement init does the same.

## Reaching the host proxy

The host serves the guest's proxy on vsock port 3128 of CID 2. `socat` in `tools` forwards loopback TCP to it; `init` does not start it. A replacement init runs, as root:

```sh
ip link set lo up
socat TCP-LISTEN:3128,bind=127.0.0.1,fork,reuseaddr VSOCK-CONNECT:2:3128 &
```

and gives the agent `HTTP_PROXY=http://127.0.0.1:3128` and `HTTPS_PROXY=http://127.0.0.1:3128`. The guest has no DNS: clients send host names to the proxy, plain http as absolute-URI requests and https as `CONNECT host:443`. What the proxy allows is the host's policy for this instance; the rest is answered 403 and logged.
