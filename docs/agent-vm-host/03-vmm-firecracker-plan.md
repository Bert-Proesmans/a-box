---
component: "vmm-firecracker-plan"
source: "03-vmm-firecracker.md"
tags: ["agent-vm-host", "spec-plan"]
---

# VMM: Firecracker — Implementation Plan

## Blueprint

[[03-vmm-firecracker]] specifies a guest boot and device model, not a
process. Nothing in this component exists yet. The finished state this plan
builds toward: a VMM launcher that can bring up one Firecracker microVM
instance presenting *exactly* the device set the spec allows — three
virtio-block devices, one virtio-vsock device, one legacy UART serial
console used only for boot-log capture — and structurally never a
virtio-net device, virtio-console device, PCI bus, or virtiofs share. The
guest boots a custom non-modular kernel directly into a custom pid1, with
no initrd handoff.

Build order follows the spec's own dependency chain: nothing boots without
a kernel first; nothing after that is provable without a minimal one-disk
boot proof; the full three-disk device model and the vsock transport are
each independently provable extensions of that proof; and the two
"guarantee" steps (device-model completeness, serial-console policy) close
the loop by making the spec's structural-absence claims machine-checked
instead of merely true-by-omission.

This plan does not build: the real pid1 binary ([[04-guest-pid1-init]]),
the real rootfs image or overlay semantics ([[09-guest-rootfs]],
[[06-workspace-and-repo-delivery]]), the vsock↔TCP proxy shim or BPF export
protocols riding on top of the vsock transport ([[05-network-egress-control]],
[[07-bpf-monitoring]]), or jailer/systemd process isolation
([[12-production-hardening]]). Where a step needs a stand-in for one of
those (a placeholder init binary, throwaway disk images), that is called
out explicitly as throwaway, not as that component's real deliverable.

**Open gap check:** [[15-decisions-log]]'s "Still open" section has no item
tagged against [[03-vmm-firecracker]] — the only decisions-log entry
relating to this spec are the resolved "Guest kernel build specifics" entry
(folded into Step 1) and the resolved "Transcript stream delivery" entry's
dedicated-`uds_path`-per-VM detail (folded into Step 4). No open gap is
flagged for this plan beyond those already-resolved decisions.

## Chunks

1. **Chunk 1 — Guest kernel & first boot proof.** Build the custom kernel,
   then prove it boots to a placeholder pid1 with one root block device and
   a captured boot log. (Steps 1–2)
2. **Chunk 2 — Full workspace block-device model.** Extend to the spec's
   full three virtio-block devices per guest. (Step 3)
3. **Chunk 3 — vsock control-channel transport.** Attach the vsock device
   with the per-VM dedicated socket scheme, prove the transport end to end
   with a trivial echo. (Step 4)
4. **Chunk 4 — Device-model completeness & console-policy guarantees.**
   Turn "no virtio-net, ever" and "serial console is boot-log-only" into
   machine-checked guarantees instead of assumptions. (Steps 5–6)

---

## Step 1 — Guest kernel build derivation

Chunk 1, first step. Foundation — no prior step exists yet.

```text
You are building a component of a Firecracker-based guest VM subsystem, from
its specification, from scratch. Nothing has been implemented for this
component yet.

Specification facts to ground this task in: the guest boots a custom Linux
kernel directly into a custom pid1 process — no traditional init system, no
initrd handoff. Firecracker's device model is deliberately minimal: it
offers virtio-block, virtio-net, virtio-vsock, virtio-balloon/rng/pmem, and
one legacy UART serial console — notably, no virtio-console, no PCI bus, and
no shared-memory/virtiofs. Because there is no PCI bus, all virtio devices
are presented to the guest over MMIO transport, not PCI.

A settled build decision for this kernel: build it with `pkgs.linuxManualConfig`
directly, not `pkgs.buildLinux` (which hardcodes `CONFIG_MODULES=y` with no
override point). Configure it as fully non-modular (`CONFIG_MODULES=n`, no
loadable module support of any kind). Firecracker rejects a compressed
`bzImage` outright at instance start ("Invalid Elf magic number"), so the
kernel build must produce, and a build-time check must confirm, an
uncompressed ELF `vmlinux` — not whatever packaged image format the kernel
build's default output step would otherwise produce.

Task: add a new Nix derivation, in a new top-level `.nix` file following
this repo's one-file-per-concern module convention, that builds this guest
kernel. Give it built-in (non-modular) support for exactly: the virtio-mmio
transport, virtio-block, virtio-vsock, devtmpfs, and the legacy 8250/16550
UART serial driver. Do not enable virtio-net, virtio-console, or any PCI
bus/driver support — the device model this kernel targets never presents
those, and this kernel should not be capable of using them even if a future
misconfiguration tried to attach one. Add a build-time check (part of the
derivation or a companion check) asserting the produced artifact is ELF, not
a compressed image.

Wire this new derivation into this repo's existing top-level Nix expression
as an independently buildable output, the way other standalone build
artifacts in this repo are already exposed, so it can be built on its own
before anything else in this subsystem exists.

Verify by building the derivation and confirming its output is an
uncompressed ELF binary. This kernel is the one load-bearing artifact every
later step in this component boots — nothing after this step can be
verified without it.
```

## Step 2 — Minimal boot proof: one root disk, captured boot log

Chunk 1, second step. Builds directly on Step 1's kernel artifact — this is
the first step that actually launches a Firecracker microVM.

Launching any Firecracker microVM needs a working, host-verified `/dev/kvm`;
that guarantee is [[02-host-platform-plan#Step 3 — /dev/kvm / nested-virt runtime guarantee]],
not re-derived here.

```text
Context already built: a Nix derivation producing an uncompressed ELF
`vmlinux` guest kernel, non-modular, with built-in virtio-mmio, virtio-block,
virtio-vsock, devtmpfs, and 8250/16550 serial support — no virtio-net,
virtio-console, or PCI support at all.

Specification facts for this task: the guest boots this kernel directly into
a custom pid1 with no initrd — root comes from a virtio-block device, not an
initramfs. Exactly one of the guest's three eventual virtio-block devices is
the rootfs device ("Device 1"); the other two are addressed in a later step
and are out of scope here. The legacy UART serial console exists solely for
early kernel boot log capture, for diagnosing boot failures — it is a single
unmultiplexed byte stream and must never be used interactively.

This task assumes a working, already-verified `/dev/kvm` on the host it
runs on (nested-virt is a separate host-platform guarantee, already
established) — do not re-derive or re-check that here.

Task: build a VMM launcher — a small program or script, in whatever
language/tooling matches this repo's existing conventions for host-side
orchestration code — that can configure and start exactly one Firecracker
microVM instance given: a path to the kernel built in the previous step, and
a path to a disk image to attach as the guest's sole root block device.
Boot arguments must point the kernel at a root filesystem on that block
device and specify a custom init path (no traditional init system) with no
initrd anywhere in the boot path. Configure Firecracker's legacy serial
console such that its output stream is captured to a host-side log file
starting at instance launch, with no interactive attach point exposed for
it. Do not configure a vsock device or any second/third block device yet —
those are later steps. Do not run this launcher through any process-jail or
sandboxing wrapper — that belongs to a later, separate hardening step, not
this one; launch Firecracker directly.

To exercise and verify this launcher, also build a throwaway single-file
disk image containing nothing but a trivial placeholder init program (not
the subsystem's real pid1 — that is built by a separate, later component).
This placeholder's only job: on boot, write one distinct, recognizable
marker string to its console output, then cleanly stop.

Verify: launch a microVM instance through the new launcher, pointed at the
Step 1 kernel and this throwaway disk image. Confirm the host-side captured
boot log file contains the placeholder's marker string. This is the first
point at which this component produces genuinely working, end-to-end
functionality: a real kernel booting through a real launcher into a real
(if placeholder) pid1, with its boot output durably captured on the host.
```

## Step 3 — Full block-device model: three virtio-block devices

Chunk 2, single step. Builds directly on Step 2's launcher and placeholder
init.

```text
Context already built: a VMM launcher that configures and starts a
Firecracker microVM with one root virtio-block device, a custom-kernel /
custom-pid1 boot path (no initrd), and a captured serial boot log. A
throwaway placeholder init program boots inside it and writes a marker to
the console.

Specification fact for this task: each guest gets three virtio-block
devices, used together to assemble the guest's workspace via overlayfs.
What each of the three devices holds and how they're layered into an
overlay is out of scope for this task entirely — that is
[[06-workspace-and-repo-delivery]]'s job, on top of whatever this task
produces. This task's job is narrower: prove the device model itself
presents three virtio-block devices to the guest, at fixed, stable device
slots, regardless of what ends up on them.

Task: extend the launcher from the previous step to accept two additional
disk image paths, attached as two further virtio-block devices alongside
the existing root device, at fixed device slots the guest can rely on
(Device 1 = root, from the previous step; Devices 2 and 3 = the two added
here). For this task, use two more throwaway placeholder disk images —
arbitrary small raw files, with no meaningful content — purely to exercise
the device model; do not attempt to implement any overlay assembly logic.

Extend the throwaway placeholder init program from the previous step: after
writing its marker, have it enumerate the block devices the guest kernel
actually recognizes and write the count and identifiers it finds to the
console output, before stopping.

Verify: launch a microVM instance through the extended launcher with all
three disk images attached. Confirm the captured boot log shows the
placeholder recognizing exactly three virtio-block devices — no more, no
fewer — matching the spec's "three virtio-block devices per guest"
requirement.
```

## Step 4 — vsock control-channel transport

Chunk 3, single step. Builds directly on Step 3's three-disk launcher.

```text
Context already built: a VMM launcher that starts a Firecracker microVM
with three virtio-block devices at fixed slots, a custom-kernel /
custom-pid1 boot path, and a captured serial boot log. A throwaway
placeholder init program boots inside it, writes a marker, enumerates block
devices, and stops.

Specification facts for this task: virtio-vsock is the sole interactive/
control channel into and out of the guest — there is no virtio-net device
anywhere, so vsock is the only path in or out. Three separate logical uses
will eventually ride this one transport, each over its own vsock port:
interactive stdin/stdout, HTTP(S) proxy traffic, and BPF event export. This
task builds only the transport itself, not any of those three protocols —
that is later components' job ([[04-guest-pid1-init]] for the guest side of
stdio; [[05-network-egress-control]] for the proxy traffic;
[[07-bpf-monitoring]] for BPF export).

A settled design decision relevant here, from [[15-decisions-log]]: each VM
instance gets one dedicated host-side listening socket for its vsock
device — not a shared, multi-VM socket disambiguated by guest CID lookup.
Whatever host-side receiver eventually reads from a given socket path can
therefore trust which session/VM a connection belongs to purely by which
dedicated socket path accepted it.

Task: extend the launcher from the previous step to attach a virtio-vsock
device to the microVM configuration. Give the launcher's configuration
surface a way to receive or generate, per launch, a host-side socket path
dedicated to that one instance (for example, derived from a caller-supplied
per-launch identifier) and a guest context identifier for that instance.
Do not build any shared cross-VM lookup mechanism — one instance, one
dedicated socket, full stop.

Extend the throwaway placeholder init program once more: immediately after
its existing boot-log work, have it open a vsock connection on one fixed,
arbitrary port and run a trivial echo loop — anything received on that
connection is written straight back — so the transport is provable
end-to-end independent of any real protocol.

Verify: launch a microVM instance through the extended launcher. From the
host, connect to the instance's dedicated vsock socket path, send some
bytes, and confirm the placeholder echoes them back unchanged. This proves
the vsock transport itself works before any of the three real logical
channels are layered onto it.
```

## Step 5 — Device-model completeness guard

Chunk 4, first step. Builds on Steps 2–4's launcher; does not add any new
guest-visible device.

```text
Context already built: a VMM launcher capable of starting a Firecracker
microVM with three virtio-block devices, one virtio-vsock device (each
instance getting its own dedicated host-side socket), a custom-kernel /
custom-pid1 boot path, and a captured, non-interactive serial boot log.

Specification fact this task enforces: there is no IP stack path out of the
guest, and this is true *by construction*, not by a firewall rule that could
be misconfigured or bypassed later — it is meant to be structurally absent
at the device-model level. Today that absence exists only because the
launcher happens not to configure a network device; nothing stops a future
change from adding one by accident.

Task: add an explicit validation pass to the launcher, run immediately
before it issues the actual "start this instance" action, that inspects the
fully-assembled device configuration for that launch and refuses to start
the instance unless it sees exactly: three virtio-block devices, one
virtio-vsock device, and nothing else — in particular, hard-failing if a
network device of any kind, a virtio-console device, or any device beyond
this fixed set is present in the configuration about to be sent to
Firecracker. This check must run on every single launch, not just be
exercised once.

Verify: (a) confirm the guard passes when run against the exact
configuration Steps 2–4 already assemble; (b) temporarily add a network
device to a test configuration and confirm the guard refuses to launch it
with a clear error identifying the disallowed device, then remove that
temporary test code — it exists only to prove the guard actually guards
something, not as a permanent part of the launcher.
```

## Step 6 — Serial-console policy: boot-log-only, never interactive

Chunk 4, second and final step. Builds on Step 2's boot-log capture and
Step 5's completeness guard; this is the last step of the plan.

```text
Context already built: a VMM launcher, guarded by an explicit device-model
completeness check (three block devices, one vsock device, nothing else),
that captures each launch's legacy serial console output to a host-side log
file from the moment the instance starts.

Specification fact this task locks down as policy, not just as today's
incidental behavior: the legacy UART serial console exists solely for early
kernel boot log capture, for debugging boot failures. It is a single
unmultiplexed byte stream and must never be used for anything interactive —
that role belongs entirely to the vsock channel built in an earlier step.
Boot failures surfaced through this captured log are handled downstream by
[[13-error-handling-failure-modes]]; this task's job is only to guarantee
the log is captured and preserved for that consumer, not to implement any
diagnosis of it.

Task: (a) audit the launcher's public interface and confirm — or, if one
exists, remove — any function, flag, or code path that would let a caller
attach interactively to the serial console; the launcher's only supported
interactive/control surface must be the vsock channel. Serial console
wiring must be write-only-to-a-log-file, with no corresponding read/attach
side exposed to callers. (b) Ensure the captured boot-log file for a given
launch is retained after the guest instance stops or fails to boot, rather
than being discarded, truncated, or overwritten on a later launch, since a
failure diagnosis may need to inspect it after the fact.

Verify: (a) confirm there is no way, anywhere in the launcher's interface,
to interactively attach to the serial console — only the vsock channel
supports interactive use. (b) Deliberately cause a boot to fail (for
example, point the launcher at a kernel/init combination that cannot
complete boot) and confirm a readable, non-empty captured log file still
exists afterward, ready for [[13-error-handling-failure-modes]] to consume.

This closes the plan: the device model presents exactly what
[[03-vmm-firecracker]] specifies (Steps 2–4), and both structural guarantees
the spec claims — no network path out, and a boot-log-only serial console —
are machine-checked (Steps 5–6), not assumed.
```

## Related

- [[03-vmm-firecracker]] — the spec this plan implements.
- [[15-decisions-log]] — resolved "Guest kernel build specifics" folded into
  Step 1; resolved dedicated-`uds_path`-per-VM detail (from the transcript
  delivery decision) folded into Step 4. No open item is tagged against
  this spec.
- [[02-host-platform-plan]] — Step 3 (`/dev/kvm` / nested-virt runtime
  guarantee) is the host-platform dependency Step 2's first microVM launch
  relies on.
- [[04-guest-pid1-init]] — the real pid1 binary that will eventually replace
  every throwaway placeholder init used for verification in this plan.
- [[06-workspace-and-repo-delivery]] — owns the overlay semantics of
  Devices 2 and 3, attached only as raw block devices in Step 3.
- [[09-guest-rootfs]] — owns the real rootfs image that will eventually
  replace the throwaway Device 1 image used in Step 2.
- [[05-network-egress-control]] and [[07-bpf-monitoring]] — the two
  non-interactive logical uses that will ride the vsock transport proven in
  Step 4, alongside interactive stdio.
- [[11-session-transcript-receivers]] — consumes the dedicated-`uds_path`-
  per-VM scheme established in Step 4 to authenticate which session a
  vsock connection belongs to.
- [[13-error-handling-failure-modes]] — consumes the captured, preserved
  boot log guaranteed by Step 6.
- [[12-production-hardening]] — owns jailer/systemd process isolation,
  deliberately not built anywhere in this plan.
