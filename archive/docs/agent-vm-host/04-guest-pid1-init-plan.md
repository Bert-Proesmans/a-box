---
component: guest-pid1-init-plan
source: 04-guest-pid1-init.md
tags:
- agent-vm-host
- spec-plan
---
# Guest pid1-init — Implementation Plan

## Blueprint

[[04-guest-pid1-init]] specifies the guest's entire boot path after the
kernel hands off control: a statically-linked, musl-target Rust binary that
replaces init entirely, with no shell interpreter anywhere in the boot path.
Nothing in this component exists yet. The finished state this plan builds
toward: a single pid1 binary that, in order, mounts the guest's
pseudo-filesystems and workspace, opens all three vsock channels, loads and
attaches the eBPF monitoring program while still root, configures the
agent's environment, drops every privilege and capability, and execs
directly into the agent process — never forking, never supervising, never
invoking a shell.

Build order follows the spec's own startup sequence, which is itself a
dependency chain: nothing after the filesystem/device mounts has anywhere to
write or read from; nothing after the vsock channels exist has a way to talk
to the host; the eBPF load must happen before the capability drop (not
after), because it needs root-level `CAP_BPF`+`CAP_PERFMON`; and the exec
step is necessarily last, since it replaces this process image entirely.

This plan does not build: the kernel or VMM launcher
([[03-vmm-firecracker]], already planned in
[[03-vmm-firecracker-plan]]), the overlay/rootfs image contents
([[06-workspace-and-repo-delivery]], [[09-guest-rootfs]]), the vsock↔TCP
shim binary or mitmproxy's allowlist/TLS-MITM logic
([[05-network-egress-control]]), the compiled eBPF program or its loader
internals ([[07-bpf-monitoring]]), or the Claude Code agent itself. Where a
step needs a stand-in for one of those (a placeholder shim/loader/agent
binary, throwaway disk images), that is called out explicitly as throwaway,
not as that component's real deliverable.

**Open gap check:** [[15-decisions-log]]'s "Still open" section has no item
tagged against [[04-guest-pid1-init]]. Two resolved decisions apply
directly and are folded into the relevant steps below instead of being
re-derived: "vsock syscalls in pid1-init" (uses the `nix` crate's AF_VSOCK
support, not the separate `vsock` crate — folded into Steps 2.1–2.3) and
"eBPF load privilege" (loaded while still root, before the
capability-drop step, because tracepoint/kprobe BPF needs
`CAP_BPF`+`CAP_PERFMON` — folded into Steps 3.1 and 4.2). No open gap is
flagged for this plan beyond those already-resolved decisions.

## Chunks

1. **Chunk 1 — Boot-time filesystem & workspace assembly.** The pid1 binary
   skeleton, pseudo-filesystem mounts, and the block-device/overlayfs
   workspace assembly. (Steps 1.1–1.2)
2. **Chunk 2 — Guest vsock channels.** All three vsock connections the spec
   requires: interactive stdio, the proxy shim, and the BPF exporter.
   (Steps 2.1–2.3)
3. **Chunk 3 — eBPF load while root.** Invoking the eBPF loader before any
   privilege is dropped. (Step 3.1)
4. **Chunk 4 — Environment, privilege drop, and exec.** Final
   agent-environment configuration, capability drop, and the terminal exec
   into the agent. (Steps 4.1–4.3)

---

## Chunk 1 — Boot-time Filesystem & Workspace Assembly

### Step 1.1 — pid1 binary skeleton & pseudo-filesystem mounts

First step of the whole plan — nothing precedes it. This is the binary
[[03-vmm-firecracker-plan]]'s launcher will eventually boot in place of
every placeholder init it used for its own verification.

```text
You are building a component of a Firecracker-based guest VM subsystem, from
its specification, from scratch. Nothing has been implemented for this
component yet.

Specification facts to ground this task in: this component is a
statically-linked (musl target) Rust binary that replaces pid1 entirely —
there is no traditional init system, and no shell interpreter is present as
pid1 or anywhere else in the boot path. It boots directly from the kernel
with no initrd. It does not fork or supervise child processes at any point
in its life; every later step in this component either runs inline or execs
directly.

A settled build decision, already resolved and not to be re-derived: the
kernel auto-mounts devtmpfs itself before this binary ever runs. Do not
mount devtmpfs a second time — doing so fails with EBUSY.

Task: create a new statically-linked (musl target) Rust binary crate, in
this repo's existing convention for such crates, that will serve as the
guest's pid1. For this first step, give it exactly this behavior on start:

- Mount procfs at its conventional mount point.
- Mount sysfs at its conventional mount point.
- Mount a tmpfs for temporary storage.
- Do not mount devtmpfs — it is already mounted by the kernel before this
  process starts.
- After the mounts succeed, write a single distinct, recognizable marker
  string identifying this step to the process's standard output (which at
  this stage is still whatever the kernel wired up as console output), then
  block indefinitely without exiting — there is nothing further for this
  binary to do until later steps are implemented.

Structure the code so each later boot stage (device/workspace mounts, vsock
connections, privilege drop, exec) can be added as its own clearly separated
step in the same startup sequence, without restructuring what you produce
here.

Verify by building this binary for the musl target and launching it as the
guest's init through the existing VMM launcher, pointed at the existing
guest kernel build, with a throwaway root disk image containing just this
binary. Confirm the captured boot log shows: the marker string, and no
mount-related errors (in particular, no EBUSY from devtmpfs).
```

### Step 1.2 — Block-device mounts & overlayfs workspace assembly

Builds on Step 1.1's mount groundwork. Depends on the three-block-device
model at fixed slots established in
[[03-vmm-firecracker-plan#Step 3 — Full block-device model: three virtio-block devices]],
and the device layout defined by [[06-workspace-and-repo-delivery]]: device 1
is the guest's own rootfs (already mounted by the kernel via boot
parameters, not by this binary), device 2 is a read-only workspace checkout,
device 3 is a small read-write overlay.

```text
Context already built: a statically-linked (musl target) Rust pid1 binary
that mounts procfs, sysfs, and a tmpfs, then blocks after writing a marker.
It does not touch devtmpfs (already mounted by the kernel).

Specification facts for this task: the guest is booted with three
virtio-block devices at fixed slots. Device 1 already serves as the guest's
root filesystem via kernel boot parameters — this binary does not mount it.
Device 2 is a read-only filesystem image holding a workspace checkout.
Device 3 is a small, read-write filesystem image acting as a writable
overlay. This binary's job is to mount device 2 read-only, mount device 3
read-write, and combine them with the kernel's overlay filesystem support so
that the merged, writable result is what the rest of the boot sequence and
the eventual agent process see as the working directory tree. What ends up
on devices 2 and 3 before boot, and how they're built, is out of scope here
entirely.

Task: extend the pid1 binary from the previous step to, after its existing
pseudo-filesystem mounts:

- Mount the guest's second virtio-block device, read-only, at an internal
  mount point.
- Mount the guest's third virtio-block device, read-write, at a second
  internal mount point.
- Use the kernel's overlay filesystem to combine the second device
  (lower, read-only) and the third device (upper, read-write) into one
  merged, writable workspace mount point.
- After all mounts succeed, write a marker string identifying this step,
  including the merged mount point path, to the boot console, then continue
  to block indefinitely as before (later steps still don't exist).

Verify by building throwaway, arbitrary-content disk images for devices 2
and 3 (no real workspace contents needed — this task proves the mount and
overlay mechanics, not what's on them) and launching the extended binary
through the existing VMM launcher with the full three-disk configuration.
Confirm the captured boot log shows the merged-mount-point marker, and
independently confirm (for example by having the marker also report a
file that exists only in the read-write upper device, or a write performed
during boot to prove the merged view is genuinely writable) that the
overlay is mounted read-write end to end.
```

---

## Chunk 2 — Guest vsock Channels

### Step 2.1 — Interactive stdio vsock connection

Builds on Chunk 1's completed filesystem/workspace assembly. Depends on the
per-VM dedicated vsock socket and guest context identifier established in
[[03-vmm-firecracker-plan#Step 4 — vsock control-channel transport]]. Uses
the `nix` crate's AF_VSOCK support per the resolved "vsock syscalls in
pid1-init" decision in [[15-decisions-log]].

```text
Context already built: a pid1 binary that mounts procfs, sysfs, a tmpfs,
and assembles a merged, writable overlay workspace from two virtio-block
devices, then blocks.

Specification facts for this task: there is no virtio-net device in this
guest — virtio-vsock is the only channel in or out. One dedicated vsock
port on this channel carries the interactive stdin/stdout stream that will,
much later in this boot sequence, become the agent process's own standard
input and output. This task only establishes that connection; wiring it
into an exec'd process is a later step and out of scope here.

A settled dependency choice for this task: perform the vsock connection
using this language's mainstream POSIX-syscall-wrapper library's AF_VSOCK
support, rather than adding a second, narrower vsock-specific dependency —
one syscall-wrapper dependency in the tree is deliberate, not an oversight.

Task: extend the pid1 binary from the previous step to open a vsock
connection to the host on one fixed, well-known port dedicated to the
interactive stdio channel. Hold the resulting connection open (do not close
it) — a later step in this same sequence will duplicate it onto the
eventual agent process's standard input and output at exec time. For this
step's own verification, temporarily echo anything received on this
connection straight back on it, so the channel's liveness can be proven
before any later step consumes it for real.

Verify by launching the guest through the existing VMM launcher, which
gives this instance its own dedicated host-side vsock socket path. From the
host, connect to that socket, address the fixed stdio port, send some
bytes, and confirm they're echoed back unchanged. Leave the temporary echo
behavior in place — a later step will replace it when the connection is
actually wired into the exec'd agent.
```

### Step 2.2 — Guest-side proxy-shim channel

Builds on Step 2.1. The vsock↔TCP shim binary itself (translating a
loopback TCP proxy target to the dedicated proxy vsock port) is
[[05-network-egress-control|already built by network egress control]], not
by this task — this step only launches and wires it.

```text
Context already built: a pid1 binary that assembles the workspace overlay,
then opens and holds a dedicated vsock connection for the interactive
stdio channel (currently just echoing for its own verification).

Specification facts for this task: because there is no virtio-net device,
any HTTP client expecting a `host:port` proxy target needs a local loopback
endpoint to talk to. A separate, already-built guest-side program handles
the actual vsock↔TCP translation for the proxy channel — this task's job is
only to start that program as a child process pointed at the right vsock
port and confirm it comes up, not to reimplement the translation itself.
Because no shell interpreter exists anywhere in this boot path, this
program must be started by directly executing its binary path — never
through a shell or any `sh -c`-style indirection.

Task: extend the pid1 binary from the previous step to, after establishing
the stdio connection, start the guest-side proxy-shim program as a child
process, configured to bind a loopback TCP port and translate traffic on it
to a second fixed, well-known vsock port dedicated to proxy traffic. Do not
wait for or supervise this child process afterward — pid1 does not
supervise children anywhere in this design; simply launch it and move on.
For this step, since the real shim binary belongs to a different component,
build and use a throwaway placeholder program that mimics only the
observable contract needed here: on start, it binds the given loopback port
and, on any incoming connection there, writes a recognizable marker to its
own output before closing.

Verify by launching the guest through the existing VMM launcher. Confirm
(for example, via a boot-console marker this task adds once the child
process spawns successfully) that the placeholder shim process was started
and its bound loopback port is reachable from inside the guest. Separately,
connect to the instance's dedicated vsock socket path on the proxy port
from the host and confirm a connection attempt reaches the placeholder
shim's translated loopback side.
```

### Step 2.3 — BPF-exporter vsock connection

Builds on Steps 2.1–2.2. Unlike the proxy channel, this connection is held
directly by pid1-init itself (using the same `nix` crate AF_VSOCK approach
as Step 2.1), because a later step must hand the open connection off to the
eBPF loader.

```text
Context already built: a pid1 binary that assembles the workspace overlay,
holds an open stdio vsock connection, and launches a guest-side proxy-shim
child process wired to a second dedicated vsock port.

Specification facts for this task: a third, separate vsock port is
dedicated to exporting eBPF monitoring events to the host as
newline-delimited JSON. Unlike the proxy channel, this connection is
established directly by this binary itself (not by launching a separate
child process) — a later step in this same sequence, not part of this
task, will invoke the eBPF loader and needs this connection already open
and ready to hand off. Use the same AF_VSOCK mechanism already used for the
stdio connection in an earlier step.

Task: extend the pid1 binary from the previous step to open a third vsock
connection to the host on a third fixed, well-known port dedicated to BPF
event export. Hold this connection open alongside the stdio connection —
do not close either. For this step's own verification only (since the real
eBPF loader doesn't exist yet in this sequence), temporarily echo anything
received on this connection straight back on it, the same stopgap already
used to verify the stdio connection.

Verify by launching the guest through the existing VMM launcher. From the
host, connect to the instance's dedicated vsock socket path, address the
BPF-export port, send some bytes, and confirm they're echoed back
unchanged — alongside re-confirming the stdio and proxy-shim channels from
the previous two steps still both work in the same boot. This closes out
the chunk: all three vsock channels the specification requires are now
simultaneously live in one guest boot.
```

---

## Chunk 3 — eBPF Load While Root

### Step 3.1 — Invoke the eBPF loader before privilege drop

Builds on Chunk 2's live BPF-export connection. Ordering here is load-bearing
and directly follows the resolved "eBPF load privilege" decision in
[[15-decisions-log]]: this must run strictly before the capability-drop step
(Step 4.2), while pid1-init is still root.

```text
Context already built: a pid1 binary that assembles the workspace overlay
and holds three live vsock connections — stdio, a proxy-shim child process
wired to its own port, and a directly-held BPF-export connection currently
echoing for its own verification.

Specification facts for this task: this binary invokes a separate,
already-built eBPF loader program (compiled program plus a libbpf-based
loader binary) as one of its own setup steps, to load and attach the
guest's eBPF monitoring programs. Per the resolved "eBPF load privilege"
decision in [[15-decisions-log]], this must happen while this binary is
still running as root, strictly before any capability-dropping step —
tracepoint/kprobe BPF program types specifically need `CAP_BPF` and
`CAP_PERFMON` together, and it isn't worth chasing a narrower capability
grant for a process that drops every capability moments later anyway.
Because no shell interpreter exists anywhere in this boot path, the loader
must be started by directly executing its binary path, never through a
shell.

Task: extend the pid1 binary from the previous step to, after the vsock
connections are established and before any privilege is dropped (privilege
dropping doesn't exist yet in this sequence — that's a later step), invoke
the eBPF loader as a direct child process, still running as root, and hand
it the already-open BPF-export vsock connection from the previous step so
the loader can write its events directly onto that connection once it
starts capturing. The compiled eBPF program and the real loader's internals
belong to a different component and are out of scope here — for this task,
build and use a throwaway placeholder loader binary that mimics only the
observable contract needed: on start, it checks whether it is running with
`CAP_BPF` and `CAP_PERFMON`, writes a marker to the boot console reporting
whether both are present, writes one further marker onto the handed-off
BPF-export connection, and then exits (the real loader would instead keep
running and exporting events continuously, but that behavior is out of
scope here).

Verify by launching the guest through the existing VMM launcher. Confirm
the captured boot log shows the placeholder loader reporting both
`CAP_BPF` and `CAP_PERFMON` present (proving it was invoked while this
binary was still root, before any capability drop). Separately, connect to
the instance's dedicated vsock socket path on the BPF-export port from the
host and confirm the placeholder's marker arrives over that same
connection, proving the hand-off actually works end to end.
```

---

## Chunk 4 — Environment, Privilege Drop, and Exec

### Step 4.1 — Configure the agent's environment

Builds on Chunk 1's workspace mount point and Step 2.2's proxy-shim loopback
address.

```text
Context already built: a pid1 binary that assembles the workspace overlay,
holds live stdio and BPF-export vsock connections, has launched the
guest-side proxy-shim child process, and — while still root — has invoked
the eBPF loader placeholder and handed it the BPF-export connection.

Specification facts for this task: before the eventual agent process
starts, its environment must be prepared with: an `HTTP_PROXY` and
`HTTPS_PROXY` value pointing at the loopback address and port the
guest-side proxy shim (started in an earlier step) is bound to; a
placeholder API credential value (the real credential is injected
host-side, later, on the proxy path — this binary only ever sets a
placeholder string, never a real key); and a working directory set to the
merged, writable overlay workspace assembled in an earlier step.

Task: extend the pid1 binary from the previous step to build, in memory,
the exact set of environment variables and working directory that the
eventual agent process will be started with: `HTTP_PROXY`/`HTTPS_PROXY`
set to the proxy shim's loopback address, a placeholder credential
environment variable set to an obviously-fake fixed string, and a working
directory path pointing at the overlay workspace mount point. Do not start
any process with this environment yet — that is a later step. For this
step's own verification, write all of these prepared values to the boot
console as a marker before continuing.

Verify by launching the guest through the existing VMM launcher and
confirming the captured boot log shows the exact prepared `HTTP_PROXY`/
`HTTPS_PROXY` value, the placeholder credential marker (and never a real
credential, since none exists at this stage), and the workspace working
directory path.
```

### Step 4.2 — Drop privileges

Builds on Step 4.1. Must occur strictly after Chunk 3's eBPF load — see the
ordering guarantee in [[15-decisions-log]]. This is the deliberate full
extent of in-guest hardening; see [[08-in-guest-hardening]] for why no
seccomp or namespace isolation is layered on top.

```text
Context already built: a pid1 binary that has assembled the workspace,
established all three vsock channels, invoked the eBPF loader while still
root, and prepared (but not yet applied) the agent's environment,
credential placeholder, and working directory.

Specification fact for this task: after everything that needs root is
already done (in particular, strictly after the eBPF load in an earlier
step — never before it, per the resolved ordering in
[[15-decisions-log]]), this binary drops privileges permanently: it
switches its effective and real user (and group) to a dedicated,
unprivileged guest user, and strips every Linux capability from itself.
This is the deliberate full extent of in-guest hardening — no seccomp
filtering, no additional namespace isolation is added here or anywhere
else in this component.

Task: extend the pid1 binary from the previous step to, immediately after
the environment-preparation step, switch its user and group identity to a
dedicated unprivileged account and drop every capability from its
effective, permitted, and inheritable capability sets, leaving it with no
elevated privilege of any kind. For this step's own verification (since
the real exec into the agent is the next and final step), write a marker
to the boot console reporting the resulting user/group identity and
confirming the capability sets are now empty, before continuing.

Verify by launching the guest through the existing VMM launcher and
confirming the captured boot log shows the unprivileged user/group
identity and empty capability sets — and that this marker appears only
after the eBPF-load marker from the previous step, never before it.
```

### Step 4.3 — exec into the agent

Chunk 4's final step, and the last step of the whole plan. Builds on every
prior step: the stdio connection (Step 2.1), the prepared environment
(Step 4.1), and the completed privilege drop (Step 4.2).

```text
Context already built: a pid1 binary that has assembled the workspace,
established all three vsock channels, invoked the eBPF loader while root,
prepared the agent's environment/credential/working directory, and dropped
every privilege and capability.

Specification fact for this task: this binary never forks or supervises —
its very last action is to replace its own process image, via exec,
directly with the agent process, using the environment, placeholder
credential, and working directory prepared in an earlier step, with its
standard input and output wired to the stdio vsock connection established
earlier in this sequence. There is no supervision after this point: if the
agent process exits, this pid1 process is gone with it. The real agent
binary belongs to a different component and is out of scope here — for
this task, build and use a throwaway placeholder program that mimics only
the observable contract needed: on start, it echoes anything it reads from
its standard input back to its standard output, and prints its received
environment variables and working directory once before doing so.

Task: extend the pid1 binary from the previous step to perform its final
action: duplicate the held stdio vsock connection onto the placeholder
agent process's standard input and output, then exec directly into the
placeholder binary with the prepared environment and working directory —
replacing this process's own image entirely, never forking.

Verify end to end: launch the guest through the existing VMM launcher.
From the host, connect to the instance's dedicated vsock socket path on
the stdio port, and confirm: the placeholder's environment/working-
directory dump arrives first, then anything sent from the host is echoed
back by the placeholder — proving the full chain from vsock connection,
through environment/workspace preparation and privilege drop, to the final
exec, works as one continuous, unprivileged, shell-free boot sequence.
This closes the plan: every step of [[04-guest-pid1-init]]'s startup
sequence is now implemented and provable.
```

## Related

- [[04-guest-pid1-init]] — the spec note this plan derives from.
- [[15-decisions-log]] — "vsock syscalls in pid1-init" (folded into Steps
  2.1–2.3) and "eBPF load privilege" (folded into Steps 3.1 and 4.2)
  resolved decisions; no open item tagged against this spec.
- [[03-vmm-firecracker-plan]] — Step 3 (three-block-device model) and
  Step 4 (vsock transport, per-VM dedicated socket) are the device-model
  dependencies Steps 1.2 and 2.1–2.3 rely on; this component's real binary
  will eventually replace every placeholder init that plan used for its
  own verification.
- [[02-host-platform-plan]] — the `/dev/kvm` boot-time verification guard
  (Step 2.2) every guest boot in this plan's verification steps relies on.
- [[06-workspace-and-repo-delivery]] — owns the three-block-device content
  layout (device 2 read-only checkout, device 3 writable overlay) that
  Step 1.2 mounts and overlays.
- [[05-network-egress-control]] — owns the guest-side vsock↔TCP shim binary
  launched (not built) in Step 2.2, and the `HTTP_PROXY`/`HTTPS_PROXY`
  target it configures in Step 4.1.
- [[07-bpf-monitoring]] — owns the compiled eBPF program and loader
  internals invoked (not built) in Step 3.1.
- [[08-in-guest-hardening]] — explains why Step 4.2's capability drop is
  the deliberate full extent of in-guest hardening.
