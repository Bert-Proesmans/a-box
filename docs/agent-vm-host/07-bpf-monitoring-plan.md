---
component: bpf-monitoring-plan
source: 07-bpf-monitoring.md
tags:
- agent-vm-host
- spec-plan
---

# BPF Monitoring — Implementation Plan

## Blueprint
[[07-bpf-monitoring]] specifies an independent, in-guest audit trail — not
an enforcement mechanism — covering process exec, network syscalls, file
opens, and DNS attempts, exported to the host as a flat per-session log.
Nothing in this component exists yet. The finished state this plan builds
toward: a compiled eBPF program set plus a small libbpf/CO-RE loader that
pid1-init invokes while still root, which continuously streams
newline-delimited JSON events over an already-open vsock connection; and a
dumb, growth-bounded host-side receiver that appends those events to a
per-session log file and stops itself once its 100 MB cap is hit.

Build order follows the spec's own dependency chain: the compiled program
and loader have to exist and work standalone before they can be handed a
live vsock file descriptor; the loader has to switch from a one-shot
capture to a continuous export before it can replace the placeholder
[[04-guest-pid1-init-plan|pid1-init]] already invokes; the guest kernel
this loader ultimately runs against needs its own additive BPF/CO-RE
extension before that replacement is meaningful against a real boot; that
replacement has to happen before any end-to-end guest boot proof is
meaningful; and the host-side receiver has to exist and be provably
growth-bounded before it's worth wiring against real guest output.

This plan does not build: pid1-init's own boot sequence, mounts, or vsock
transport ([[04-guest-pid1-init]], already planned in
[[04-guest-pid1-init-plan]] — that plan's Step 3.1 already invokes a
placeholder loader and hands it an open BPF-export vsock connection; this
plan's job is to build the real program/loader that placeholder stands in
for), the VMM/device model, per-VM dedicated vsock socket scheme, or the
baseline guest kernel itself ([[03-vmm-firecracker]], planned in
[[03-vmm-firecracker-plan]] — this plan's Step 3.2 additively extends that
baseline kernel's build, without modifying it), the full per-session
systemd unit graph, `.target` wrapping, or stop-cascade wiring
([[10-session-lifecycle-orchestration]], not yet planned), the other two
transcript streams or the DuckDB/SQLite query story
([[11-session-transcript-receivers]], not yet planned), mitmproxy/egress
control ([[05-network-egress-control]]), or the capability-drop step itself
([[08-in-guest-hardening]], already built in
[[04-guest-pid1-init-plan#Step 4.2 — Drop privileges|Step 4.2]] of the
pid1-init plan). Where a step needs a stand-in for one of those, that is
called out explicitly as throwaway or out-of-scope, not as that
component's real deliverable.

**Open gap check:** [[15-decisions-log]]'s "Still open" section has no item
tagged directly against [[07-bpf-monitoring]]. One resolved decision
applies directly and is folded into Step 3.3 below instead of being
re-derived: "eBPF load privilege" — the loader runs while pid1-init is
still root, strictly before the capability drop, because tracepoint/kprobe
BPF program types need `CAP_BPF`+`CAP_PERFMON` together.

**Guest kernel prerequisites — settled, this component's own
responsibility:** [[07-bpf-monitoring#Guest kernel prerequisites|the spec
now states explicitly]] that CO-RE relocation and tracepoint/kprobe
capture need `CONFIG_BPF`, `CONFIG_BPF_SYSCALL`, `CONFIG_DEBUG_INFO_BTF`,
`CONFIG_KPROBES`, `CONFIG_KPROBE_EVENTS`, `CONFIG_BPF_EVENTS`, and
`CONFIG_PERF_EVENTS`, layered additively onto
[[03-vmm-firecracker-plan#Step 1 — Guest kernel build derivation|the
baseline guest kernel derivation]], which stays minimal and standalone by
design — this plan does not modify it. Step 3.2 below builds that additive
kernel-config extension as this component's own deliverable, no longer an
open gap.
## Chunks
1. **Chunk 1 — Guest eBPF toolchain & process/network capture.** Stand up
   the C/libbpf/CO-RE build, and capture the first two of the four
   signal categories. (Steps 1.1–1.2)
2. **Chunk 2 — File & DNS capture, unified export schema.** Capture the
   remaining two signal categories and settle the common NDJSON envelope.
   (Steps 2.1–2.2)
3. **Chunk 3 — Continuous vsock export, kernel extension & pid1-init
   integration.** Turn the loader into a long-running exporter, additively
   extend the guest kernel with the BPF/CO-RE support it needs, and wire
   it into the real boot path in place of the placeholder. (Steps 3.1–3.3)
4. **Chunk 4 — Host-side `bpf.jsonl` receiver.** The growth-bounded
   receiver, proved standalone and then end to end against real guest
   output. (Steps 4.1–4.2)
## Chunk 1 — Guest eBPF Toolchain & Process/Network Capture

### Step 1.1 — Build toolchain, skeleton, and process-exec capture
First step of the whole plan — nothing precedes it. This produces the
first working, provable slice of the eventual eBPF program: exec capture,
printed rather than exported, so the toolchain and capture mechanics are
proved before anything talks to vsock.

```text
You are building a component of a Firecracker-based guest VM subsystem, from
its specification, from scratch. Nothing has been implemented for this
component yet.

Specification facts to ground this task in: this component is an
independent, in-guest audit trail of process, network, file, and DNS
activity — it observes and logs, it never enforces or blocks anything. It
is written in C using libbpf with CO-RE (Compile Once – Run Everywhere),
deliberately not Rust/Aya or Go/cilium-ebpf, specifically because C/libbpf/
CO-RE has the fewest moving toolchain parts to reproduce inside a
reproducible build: clang, libbpf, and bpftool are all mainstream,
well-established packages, whereas the Rust and Go paths each need an
extra, less mainstream toolchain layer (a pinned nightly compiler plus a
special linker, or a separate codegen step, respectively).

Specification fact for this task, settled rather than open: the spec
states the exact kernel-side prerequisites CO-RE and tracepoint/kprobe
capture need — CONFIG_BPF, CONFIG_BPF_SYSCALL, CONFIG_DEBUG_INFO_BTF,
CONFIG_KPROBES, CONFIG_KPROBE_EVENTS, CONFIG_BPF_EVENTS, CONFIG_PERF_EVENTS
— layered additively onto the baseline guest kernel derivation built
elsewhere in this project, which stays minimal and unmodified. This plan
builds that kernel extension itself, later, in Step 3.2 — not here. For
this first step, develop and prove the program against any ordinary Linux
host with those prerequisites present (most current mainstream
distributions qualify); do not attempt to build or modify any guest kernel
in this step.

Task: set up a new build for a compiled eBPF program plus a small,
statically-linkable libbpf-based userspace loader, in this repo's
convention for a C/libbpf toolchain component. For this first step, give
the pair exactly this behavior:

- The eBPF program attaches to the kernel's process-execution tracepoint
  (or equivalent stable attach point) and captures each exec event: at
  minimum the executed path/command and its arguments.
- The loader loads and attaches this program, reads captured events as
  they occur, and for each one prints a single JSON object to its own
  standard output, followed by a newline (newline-delimited JSON — one
  complete, self-contained JSON object per line, no pretty-printing across
  lines). Each object must carry at least: a timestamp, an event-type
  discriminator (identifying this as a process-exec event), and the
  captured command/argument payload.
- The loader runs until manually interrupted; it does not exit on its own
  after one event.

Structure the code so each later capture category (network syscalls, file
opens, DNS attempts) can be added as its own attach point feeding the same
event pipeline and the same NDJSON output, without restructuring what you
produce here.

Verify by building the program and loader, running the loader with
sufficient privilege to load BPF programs on a suitable Linux host, and
executing a handful of ordinary shell commands in another terminal while
it runs. Confirm one well-formed JSON line appears per command executed,
containing that command's path/arguments, and that no line is emitted for
activity that isn't a process exec.
```
### Step 2.1 — File-open capture, distinguishing read vs. write

Builds on Chunk 1's exec and network capture. Adds the third of the four
signal categories, with the read/write distinction the spec explicitly
calls for.

```text
Context already built: an eBPF program plus libbpf-based loader that
captures process-exec and network connect/sendto events, each printed to
the loader's standard output as one NDJSON line per event, tagged with an
event-type discriminator.

Specification fact for this task: this component also captures file
opens, and specifically distinguishes read-mode opens from write-mode
opens — not just "a file was opened," but which access mode was
requested.

Task: extend the eBPF program and loader from the previous steps to also
attach to the kernel's file-open path (a stable tracepoint/kprobe attach
point for the open/openat family of syscalls) and capture each file-open
event: at minimum the path being opened and whether it was opened for
reading, writing, or both. Emit each as its own NDJSON line on the
loader's existing standard-output stream, using the same common envelope
(timestamp, event-type discriminator, payload) as the existing event
types, with an event-type value that distinguishes file-open events from
exec and network events, and a payload field that makes the read-vs-write
distinction explicit and unambiguous to a downstream reader.

Verify by running the loader with sufficient privilege on a suitable Linux
host and, in another terminal, performing a handful of file opens in
distinct modes (for example: reading an existing file, creating/writing a
new file, and opening a file for both). Confirm one NDJSON line appears
per open, with the correct path and the correct read/write mode recorded
for each, alongside the exec and network events from earlier steps still
firing correctly for comparison.
```

Note: numbering above intentionally continues the plan's chunk.step
scheme; this is Chunk 2's first step (2.1), following Chunk 1's 1.1–1.2.

### Step 1.2 — Network syscall capture (connect/sendto)

Builds on Step 1.1's exec capture and NDJSON pipeline. Adds the second
signal category, described in the spec as belt-and-suspenders given there
is no virtio-net device in this design at all.

```text
Context already built: an eBPF program plus libbpf-based loader that
captures process-exec events and prints one NDJSON line per event (with a
timestamp, an event-type discriminator, and a payload) to the loader's
standard output, running continuously.

Specification fact for this task: this component also captures network
syscalls — specifically `connect` and `sendto` — as a belt-and-suspenders
signal. There is no virtio-net device anywhere in this guest design, so
under normal operation this category should almost never fire; when it
does, it means something attempted to open a raw socket or otherwise
bypass the intended proxy path, which is exactly the misbehavior this
capture exists to catch.

Task: extend the eBPF program and loader from the previous step to also
attach to the kernel's `connect` and `sendto` syscall entry points (stable
tracepoint/kprobe attach points) and capture each occurrence: at minimum
the calling process, the syscall name, and whatever destination
information (address/port, or as much of it as is readily available at
that attach point) is present in its arguments. Emit each as its own
NDJSON line on the loader's existing standard-output stream, using the
same common envelope (timestamp, event-type discriminator, payload) as
the exec events, with an event-type value that distinguishes network
events from exec events.

Verify by running the loader with sufficient privilege on a suitable Linux
host and, in another terminal, both running ordinary commands (to confirm
exec events still fire) and making a couple of outbound network
connections (for example, connecting to a local test listener). Confirm
one NDJSON line appears per `connect`/`sendto` call observed, correctly
tagged as a network event and distinct from the exec events also still
firing.
```

---

## Chunk 2 — File & DNS Capture, Unified Export Schema

(Step 2.1, file-open capture, is listed above under Chunk 1's heading
sequence for numbering continuity; it is this chunk's first step.)

### Step 2.2 — DNS-attempt capture and the common export schema

Builds on Steps 1.1–2.1's three capture categories. Closes out capture
coverage with the fourth category and settles the shared envelope every
event type now uses.

```text
Context already built: an eBPF program plus libbpf-based loader capturing
process-exec, network connect/sendto, and file-open (read-vs-write)
events, each printed as one NDJSON line to the loader's standard output,
using a common envelope of timestamp, event-type discriminator, and
payload.

Specification facts for this task: this component also captures DNS
attempts, as the fourth and final signal category — a deliberate canary,
not a functional necessity, since this guest has no virtio-net device and
therefore no working IP stack for a DNS query to actually resolve
anything over. A well-behaved session, using the proxy path this guest is
designed around, should generate zero DNS attempts; any DNS attempt that
appears at all means some tool is bypassing that path, independent of any
allowlist/proxy policy enforcement.

This event pipeline does not need to know, and must not try to determine,
which agent session it belongs to — session identification is handled
entirely downstream, by whichever host-side process accepts this loader's
exported connection (each session's connection arrives on a dedicated,
per-session channel, so there is no ambiguity to resolve on the guest
side). Do not add a session identifier field to the common envelope.

Task: extend the eBPF program and loader once more to attach to the
guest's DNS-resolution attempt path (for example, the resolver's own
name-lookup call, or an equivalent stable attach point that fires when
something tries to resolve a hostname) and capture each attempt: at
minimum the hostname being looked up, if available, and which process
triggered it. Emit it as its own NDJSON line using the same common
envelope, with its own distinct event-type value.

While making this change, review and, if needed, tighten the shared
envelope (timestamp, event-type discriminator, payload) so all four event
types now use it consistently and predictably — same field names and
timestamp format across all four — since this is the last capture
category this component adds; from here on, every later step consumes
this schema as fixed and already-decided.

Verify by running the loader with sufficient privilege on a suitable Linux
host. Trigger a hostname lookup (for example, via a tool that performs its
own resolution rather than going through a configured proxy) and confirm
one correctly-tagged DNS-attempt NDJSON line appears. Re-run a quick smoke
check across all four categories together (an exec, a network connect, a
file open, and a DNS lookup) and confirm each produces exactly one
correctly-tagged, schema-consistent NDJSON line, with no category
producing zero or duplicate lines.
```

---

## Chunk 3 — Continuous vsock Export & pid1-init Integration
### Step 3.1 — Continuous export over a handed-off connection

Builds on Chunk 2's complete four-category capture and finalized schema.
Turns the loader from a "prints to its own stdout" tool into the actual
exporter the spec describes, matching the hand-off contract
[[04-guest-pid1-init-plan#Step 3.1 — Invoke the eBPF loader before
privilege drop|the pid1-init plan's Step 3.1]] already established for its
placeholder loader.

```text
Context already built: an eBPF program plus libbpf-based loader capturing
all four signal categories this component specifies (process exec,
network connect/sendto, file opens with read/write distinction, and DNS
attempts), each emitted as one NDJSON line on a fixed common schema
(timestamp, event-type discriminator, payload), currently printed to the
loader's own standard output.

Specification fact for this task: in the real boot sequence, this
program's output does not go to its own stdout — it is exported to the
host over a dedicated vsock connection, as newline-delimited JSON. A
separate component (this guest's pid1-init process) is responsible for
opening that vsock connection and starting this loader; this loader does
not open the connection itself. What this loader needs to do is accept an
already-open, already-connected output channel (handed to it as an
inherited, already-open file descriptor — a standard, language-agnostic
process hand-off mechanism, not a path or address this loader has to open
itself) and write its NDJSON stream onto that channel instead of its own
stdout, continuously, for as long as it runs. Unlike every previous step
in this plan, this loader must never exit on its own once started;
running is its entire job.

Task: change the loader so that, instead of writing NDJSON lines to its
own standard output, it writes them to a specific inherited, already-open
file descriptor passed to it at startup (for example, via a fixed,
documented file-descriptor number, or an equivalent well-known hand-off
convention for this language/toolchain) — falling back to its own standard
output only when no such descriptor is supplied, so the previous steps'
standalone verification path still works unmodified. Confirm the loader
never exits once it starts capturing (short of an unrecoverable error),
since a later step depends on it running for the guest's entire session
lifetime.

Verify two ways: (a) re-run the previous steps' standalone checks
(exec/network/file/DNS events on stdout) to confirm nothing regressed
when no hand-off descriptor is given; (b) write a small standalone test
harness that opens a connected pair of file descriptors (for example, a
Unix domain socket pair or a pipe), starts the loader with one end handed
off as its export descriptor, triggers a few events of each of the four
kinds, and confirms well-formed NDJSON lines arrive on the *other* end of
that pair — proving the hand-off mechanism itself works before any real
vsock connection is involved.
```

### Step 3.2 — Extend the guest kernel with BPF/CO-RE support

Builds on nothing produced earlier in *this* chunk directly — it runs
independently of Step 3.1's hand-off mechanism. It must land before Step
3.3, the first step that runs the real loader against a real guest boot.

```text
Context already built: [[03-vmm-firecracker-plan#Step 1 — Guest kernel
build derivation|a baseline guest kernel derivation]], deliberately minimal
— built via `pkgs.linuxManualConfig`, non-modular, producing an
uncompressed ELF `vmlinux`, with built-in support for exactly virtio-mmio,
virtio-block, virtio-vsock, devtmpfs, and the legacy 8250/16550 serial
driver. That derivation is meant to stand alone and stay buildable on its
own; this task does not modify it.

Specification fact for this task: [[07-bpf-monitoring#Guest kernel
prerequisites|the spec states]] that CO-RE relocation and tracepoint/kprobe
capture need, additively, kernel support this baseline does not include:
`CONFIG_BPF`, `CONFIG_BPF_SYSCALL` (BPF subsystem and syscall support),
`CONFIG_DEBUG_INFO_BTF` (kernel-embedded BTF, required for CO-RE
relocation without shipping a separate external BTF file), `CONFIG_KPROBES`,
`CONFIG_KPROBE_EVENTS` (kprobe attach points), and `CONFIG_BPF_EVENTS`,
`CONFIG_PERF_EVENTS` (tracepoint/kprobe BPF attachment goes through the
perf_event subsystem). This is this component's own responsibility to
provide, per the spec — not a change to the baseline kernel derivation
itself.

Task: add a second kernel-build derivation, additive to and built from the
same base configuration as the existing minimal one, that turns on exactly
the CONFIG options listed above on top of everything the baseline already
enables — do not remove or change any of the baseline's existing options.
Give this variant a distinct build output name/attribute so callers can
tell it apart from the baseline minimal kernel and choose which one to
launch a guest with. The baseline derivation itself must remain unchanged
and independently buildable exactly as it was before this task.

Verify: (a) build both kernel variants and confirm the baseline is
unaffected (still builds, still an uncompressed ELF `vmlinux`, still
lacking the new options); (b) build and boot the new variant (a trivial
placeholder init is fine for this check) and confirm the running guest
exposes `/sys/kernel/btf/vmlinux` (proof `CONFIG_DEBUG_INFO_BTF` took
effect) and can successfully load one trivial no-op BPF program of each
type this component needs — one kprobe-attached, one tracepoint-attached
— proving CO-RE relocation and both attach-point kinds work end to end
before Step 3.3 wires the real loader against this kernel.
```

### Step 3.3 — Replace the pid1-init placeholder loader

Builds directly on Step 3.1's continuous, hand-off-driven exporter and
Step 3.2's BPF-capable kernel variant. Final step of this chunk: wires the
real program into the real boot path, replacing the throwaway placeholder
[[04-guest-pid1-init-plan#Step 3.1 — Invoke the eBPF loader before
privilege drop|the pid1-init plan's Step 3.1]] built and verified.

```text
Context already built: an eBPF program plus libbpf-based loader capturing
all four signal categories on a fixed common NDJSON schema, which now
writes its output continuously onto an inherited, already-open file
descriptor handed to it at startup, and never exits on its own once
capturing. Separately, a BPF-capable guest kernel variant exists,
additive to the baseline minimal kernel, with CO-RE/BTF and
kprobe/tracepoint support confirmed working.

Specification facts for this task: a separate, already-built component
(this guest's pid1-init process) invokes this loader as one of its own
boot setup steps, while pid1-init is still running as root, strictly
before it drops any privilege — this ordering is settled and not to be
re-derived; see the resolved "eBPF load privilege" decision in
[[15-decisions-log]]: tracepoint/kprobe BPF program types specifically
need `CAP_BPF` and `CAP_PERFMON` together, and it is not worth chasing a
narrower capability grant for a process that drops every capability
moments later anyway. pid1-init already opens a dedicated vsock connection
to the host for BPF event export and, in its current placeholder form,
hands that open connection to a stand-in loader that merely reports
whether `CAP_BPF`/`CAP_PERFMON` are present and writes one marker before
exiting. Your job in this task is to be the real thing that placeholder
stood in for — the placeholder's own internals are not this task's
concern, only its observable contract: invoked as a direct child process,
handed the open BPF-export vsock connection, while pid1-init is still
root, before any capability drop.

Task: wire this component's compiled program and loader (from all
previous steps in this plan) into the real boot path in place of the
placeholder loader pid1-init currently invokes — using the exact same
hand-off contract already established (direct child-process invocation,
no shell involved; the open BPF-export vsock connection passed as this
loader's inherited export descriptor, per the previous step's hand-off
mechanism). Do not modify pid1-init's own sequencing, privilege-drop
timing, or any of its other steps — this task only swaps which binary
gets invoked at the point that sequencing already calls for the loader.

Verify by launching a full guest boot through the existing VMM launcher,
configured to boot Step 3.2's BPF-capable kernel variant (not the
launcher's default baseline kernel), with this real program/loader in
place of the placeholder. From the host, connect to the instance's
dedicated vsock socket path on the BPF-export port and confirm
well-formed NDJSON lines arrive continuously as guest activity happens,
correctly tagged across at least a few of the four event categories
(trigger some exec activity and a file open or two inside the guest to
exercise this). Separately, confirm the loader is still invoked strictly
before pid1-init's capability-drop step completes (for example, by
confirming its startup marker/behavior still precedes that step's own
boot-console marker, the same ordering check the pid1-init plan already
relies on) — this ordering must hold with the real loader exactly as it
did with the placeholder.
```
## Chunk 4 — Host-Side `bpf.jsonl` Receiver

### Step 4.1 — Standalone, growth-bounded receiver

Builds on nothing produced earlier in this plan directly — it is a
host-side counterpart developed and proved independently, ready to be
pointed at the real guest export once Chunk 3 exists. Grounded in
[[11-session-transcript-receivers#recv-bpf|recv-bpf's design]]: a
deliberately dumb, per-session, growth-bounded append loop.

```text
You are building the host-side half of a guest-to-host audit-event export
pipeline. The guest side (a separate component, already built) streams
newline-delimited JSON event lines outward over a per-session vsock
connection; nothing on the host reads or persists them yet.

Specification facts to ground this task in: this is a small, dedicated
receiver process, one per running session, and it is deliberately dumb —
no database, no real-time alerting pipeline, no parsing or validation of
event contents. Its entire job: accept exactly one guest-initiated
connection on a socket path dedicated to one specific session (there is no
multi-session ambiguity to resolve — each session already gets its own
dedicated host-side socket from a lower layer this task does not build),
then run a simple loop — read up to some bounded chunk size, append
exactly what was read to a per-session output file, sleep briefly, repeat.
This read-size/sleep-interval pairing is itself the only bandwidth
limiting in place; there is no separate token-bucket or rate-limiter
mechanism.

Enforce a hard cap of 100 MB written per output file: once cumulative
bytes written reaches the cap, stop reading, close the accepted
connection, close and remove the listening socket, and exit. Do not
attempt to stop exactly on a newline/JSON-line boundary — a final,
truncated partial line past the cap is acceptable and expected. Do not
drain-and-discard once capped — once the cap is hit, the guest's own
writer is deliberately left to block or fail against the now-closed
socket; this is an intentional abuse backstop, not a data-integrity
feature, so no attempt should be made to keep the guest side happy past
the cap.

Per the settled host-orchestration-language decision (see
[[10-session-lifecycle-orchestration]]: host-side per-unit helper
processes are small scripts in that chosen orchestration language, not a
separate compiled binary per session), implement this receiver as such a
script. It must be invocable directly, taking as input at least: which
socket path to listen on, and which output file path to append to. Do
not build any process-supervision, restart, or systemd-unit wiring around
it — a later, separate component owns launching and supervising this
script as part of a session's process set; this task only builds the
script itself, runnable stand-alone.

Verify by running the script directly against a throwaway Unix domain
socket path and throwaway output file path. From a separate test process,
connect to that socket and write a range of test payloads: (a) a modest
amount of well-formed NDJSON-shaped data, confirming it lands byte-for-
byte in the output file; (b) enough data to cross the 100 MB cap deliberately, confirming the
script stops accepting further bytes at the cap, the accepted connection
and listening socket both end up closed, the script exits, and the output
file's size does not meaningfully exceed the cap.
```

### Step 4.2 — End-to-end proof against real guest output
Final step of the plan. Builds on Step 3.3's real guest-side export and
Step 4.1's standalone receiver — the first point at which both halves of
this component run together, closing out
[[07-bpf-monitoring]]'s stated finished state.

```text
Context already built: on the guest side, a compiled eBPF program plus
loader, invoked by pid1-init while still root, continuously exporting all
four captured event categories as NDJSON onto the guest's dedicated
BPF-export vsock connection, running on a BPF-capable guest kernel variant
additive to the baseline minimal kernel. On the host side, a standalone
receiver script that accepts one guest-initiated connection on a dedicated
per-session socket path, appends everything it reads to a per-session
output file, and stops itself once that file hits a 100 MB cap.

Specification fact for this task: nothing built so far has actually run
these two halves against each other — the guest side was proved by
connecting a test client directly to its vsock port, and the receiver was
proved by feeding it synthetic bytes over a throwaway socket, not a real
guest connection. This task's only job is to prove the real pairing works
end to end, and that the fail-closed cap behavior still holds against real
(not synthetic) guest traffic. This task does not add any new capture
category, change the NDJSON schema, or change the cap policy — all of
that is already decided and fixed.

Also specification-relevant: per this component's violation-response
policy, none of this pipeline ever kills or blocks a session on its own —
captured events are only ever logged for later human review, never acted
on automatically. This task's verification should not attempt to add any
such enforcement; confirm only that events are captured and persisted, not
that anything is blocked because of them.

Task: launch a full guest boot through the existing VMM launcher,
configured to boot the BPF-capable kernel variant from Chunk 3's Step 3.2,
with the real eBPF program/loader in place (from this plan's Chunk 3), and
start the standalone receiver script (from Step 4.1) pointed at that
specific instance's dedicated BPF-export socket path and a fresh
per-session output file path, before or as the guest boots. No new code
should be needed for this step beyond, at most, small glue to launch both
pieces together for the purpose of this verification — if the two halves
already compose without any changes, that itself is the deliverable to
confirm.

Verify by, while the guest is running, triggering guest activity spanning
all four captured categories (run a shell command, perform a file open in
each read/write mode, attempt an outbound network connection, and trigger
a hostname lookup) and confirming each shows up as a well-formed,
correctly-tagged NDJSON line in the receiver's output file, in
close-to-real-time (not only after the guest stops). Separately, run a
second pass that deliberately generates enough guest-side activity to
push the output file's size toward the 100 MB cap, and confirm the
receiver still stops itself, closes its socket, and exits exactly as it
did in Step 4.1's standalone test — now proven against a real guest
connection instead of a synthetic one. This closes the plan: every stated
piece of [[07-bpf-monitoring]] — four-category in-guest capture, root-
before-drop load ordering, continuous vsock export, and a growth-bounded,
log-only host-side receiver — is now implemented and provable together.
```
## Related
- [[07-bpf-monitoring]] — the spec note this plan derives from, including
  its "Guest kernel prerequisites" section that Step 3.2 implements.
- [[15-decisions-log]] — the resolved "eBPF load privilege" decision folded
  into Step 3.3; also records the "Package registry strategy" and other
  still-open items that are not relevant to this spec.
- [[04-guest-pid1-init-plan]] — Step 3.1 (placeholder eBPF loader
  invocation) is what Step 3.3 replaces; Step 4.2 (capability drop) is the
  boundary the real loader must still precede.
- [[03-vmm-firecracker-plan]] — Step 1 (guest kernel build) is the minimal,
  standalone baseline this plan's Step 3.2 additively extends with
  BPF/CO-RE support, without modifying it; Step 4 (vsock transport,
  dedicated per-VM socket) is the transport Step 3.3 and Step 4.2 rely on.
- [[11-session-transcript-receivers]] — owns the full `recv-bpf` design
  (dedicated-socket authentication, dumb read-loop, 100 MB cap,
  `Restart=no`) this plan's Chunk 4 implements a standalone version of.
- [[10-session-lifecycle-orchestration]] — owns the per-session systemd
  unit set that will eventually launch and supervise the Step 4.1
  receiver script; owns the settled host-orchestration-language decision
  that script follows.
- [[13-error-handling-failure-modes]] — confirms the log-and-alert-only,
  never-auto-kill violation policy this plan's Step 4.2 verification
  respects rather than works around.
- [[08-in-guest-hardening]] — the capability-drop step this component's
  load ordering must precede, already built elsewhere; not re-derived
  here.
- [[05-network-egress-control]] — the proxy path whose bypass this
  component's network/DNS capture exists to catch as a canary.