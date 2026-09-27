---
component: "vmm-firecracker-todo"
source: "03-vmm-firecracker-plan.md"
tags: ["agent-vm-host", "spec-todo"]
---
# VMM: Firecracker — Build Checklist

A step's top-level box is a summary — check it only once every nested box under it is checked.

## Chunk 1 — Guest kernel & first boot proof

- [x] Step 1 — Guest kernel build derivation — [[03-vmm-firecracker-plan#Step 1 — Guest kernel build derivation]]
  - [x] New Nix derivation (new top-level `.nix` file, one-file-per-concern convention) building the guest kernel via `pkgs.linuxManualConfig` directly (not `pkgs.buildLinux`)
  - [x] Fully non-modular (`CONFIG_MODULES=n`)
  - [x] Built-in support for exactly: virtio-mmio transport, virtio-block, virtio-vsock, devtmpfs, legacy 8250/16550 UART serial — no virtio-net, no virtio-console, no PCI bus/driver support
  - [x] Build-time check asserting the produced artifact is an uncompressed ELF `vmlinux`, not a compressed bzImage
  - [x] Wired into the repo's existing top-level Nix expression as an independently buildable output
  - [x] Verify: build the derivation, confirm output is an uncompressed ELF binary
- [x] Step 2 — Minimal boot proof: one root disk, captured boot log — [[03-vmm-firecracker-plan#Step 2 — Minimal boot proof: one root disk, captured boot log]]
  - [x] VMM launcher program/script configuring and starting exactly one Firecracker microVM given a kernel path and one root block-device disk image path
  - [x] Boot args point kernel at rootfs on that block device, custom init path, no initrd
  - [x] Legacy serial console output captured to a host-side log file from instance launch, no interactive attach point
  - [x] No vsock device or second/third block device configured yet; launched directly with no process-jail/sandbox wrapper
  - [x] Throwaway single-file disk image with a placeholder init that writes one recognizable marker string to console then cleanly stops
  - [x] Verify: launch a microVM via the launcher with Step 1's kernel + this throwaway image; confirm the captured boot log file contains the marker string
  - Depends on host KVM guarantee: [[02-host-platform-plan#Step 2.2 — Boot-time KVM availability verification]] (not re-derived here)

## Chunk 2 — Full workspace block-device model

- [ ] Step 3 — Full block-device model: three virtio-block devices — [[03-vmm-firecracker-plan#Step 3 — Full block-device model: three virtio-block devices]]
  - [ ] Launcher extended to accept two additional disk image paths, attached as two further virtio-block devices at fixed slots (Device 1 = root, Devices 2/3 = new) alongside the existing root device
  - [ ] Two more throwaway placeholder disk images (arbitrary small raw files) used purely to exercise the device model — no overlay-assembly logic implemented
  - [ ] Placeholder init extended: after writing its marker, enumerates block devices the guest kernel recognizes and writes count + identifiers to console before stopping
  - [ ] Verify: launch with all three disks attached; confirm captured boot log shows the placeholder recognizing exactly three virtio-block devices — no more, no fewer

## Chunk 3 — vsock control-channel transport

- [ ] Step 4 — vsock control-channel transport — [[03-vmm-firecracker-plan#Step 4 — vsock control-channel transport]]
  - [x] Launcher extended to attach a virtio-vsock device to the microVM configuration
  - [x] Launcher's configuration surface can receive/generate, per launch, a host-side socket path dedicated to that one instance (e.g. derived from a caller-supplied per-launch identifier) plus a guest context identifier — no shared cross-VM lookup mechanism
  - [ ] Placeholder init extended: opens a vsock connection on one fixed port and runs a trivial echo loop
  - [ ] Verify: launch instance, connect from host to its dedicated vsock socket path, send bytes, confirm placeholder echoes them back unchanged
  - Existing guest code already opens this connection and hands it to a real spawned agent (`echo_agent`, chunk C1 of the old plan) rather than running a trivial inline echo, and that agent prefixes every line with `echo: ` — bytes are not echoed back unchanged, so this step's literal verify condition isn't met yet (see 04's Step 2.1 caveat for the same root cause)

## Chunk 4 — Device-model completeness & console-policy guarantees

- [ ] Step 5 — Device-model completeness guard — [[03-vmm-firecracker-plan#Step 5 — Device-model completeness guard]]
  - [ ] Explicit validation pass added to the launcher, run immediately before issuing "start this instance", inspecting the fully-assembled device configuration
  - [ ] Refuses to start unless exactly three virtio-block devices + one virtio-vsock device + nothing else are present; hard-fails on any network device, virtio-console device, or anything beyond this fixed set
  - [ ] Check runs on every single launch, not just once
  - [ ] Verify (a): guard passes against the exact configuration Steps 2–4 already assemble
  - [ ] Verify (b): temporarily add a network device to a test configuration, confirm the guard refuses to launch it with a clear error naming the disallowed device, then remove that temporary test code
- [ ] Step 6 — Serial-console policy: boot-log-only, never interactive — [[03-vmm-firecracker-plan#Step 6 — Serial-console policy: boot-log-only, never interactive]]
  - [x] Audit launcher's public interface; confirm or remove any function/flag/code path allowing interactive attach to the serial console — only vsock supports interactive use
  - [x] Serial console wiring is write-only-to-a-log-file, no read/attach side exposed to callers
  - [ ] Captured boot-log file for a given launch is retained after the guest stops or fails to boot — not discarded, truncated, or overwritten on a later launch
  - [ ] Verify (a): confirm no way exists anywhere in the launcher's interface to interactively attach to the serial console
  - [ ] Verify (b): deliberately cause a boot to fail (e.g. bad kernel/init combination); confirm a readable, non-empty captured log file still exists afterward
  - `FirecrackerVM.start()` opens `console_log` with `.open("wb")`, which truncates on every call — a retried/relaunched instance reusing the same log path loses prior boot evidence; no negative-path test (deliberately-failed boot + log-still-present) exists yet either

## Related

- [[03-vmm-firecracker-plan]] — the plan note this checklist derives from.
- [[03-vmm-firecracker]] — the spec note behind the plan.
