---
component: testing-strategy
source: agent-vm-host-spec.md
spec-section: §14
tags:
- agent-vm-host
- spec-component
---
# Testing Strategy

## Test markers

Repo-wide convention, tracked in `todo.md`:

- `needs_kvm` — requires `/dev/kvm`.
- `needs_root` — elevated privileges (loop-mounts, BPF load, cgroup/jailer
  operations).
- `needs_bpf` — BPF load capability.

Unmarked tests run anywhere, including CI without virtualization.

Layered approach, consistent with the rest of the project: fakes for unit
tests, real KVM for integration.

## Unit tests, no VM needed

### Receiver read-loop cap logic

Byte counting, close-on-cap, no line-boundary special-casing, tested
against a fake socket. Covers the [[11-session-transcript-receivers|receiver growth-bounding]]
mechanism.

### Idle-watchdog mtime-comparison logic

Tested against a fake clock and fake files. Covers the
[[11-session-transcript-receivers|inactivity watchdog]] mechanism.

### Unit-file/target rendering

Rendering of the session unit graph against fixture session IDs.
Covers [[10-session-lifecycle-orchestration|session lifecycle & host orchestration]].

### Jailer invocation argv

Pure functions for the jailer invocation argv, mirroring the existing
`build_cap_drop_plan` pattern. Relates to [[08-in-guest-hardening|in-guest hardening]]
and [[12-production-hardening|process isolation]].

## `needs_kvm` integration tests

Run on this host's fixture kernel/rootfs.

### Hugepage boot-time benchmark

`2M` vs `None` boot-time comparison. Covers [[12-production-hardening|the hugepage pool]].

### Growth-bounding

A receiver fed past 100 MB stops reading and the file caps at exactly
that size; JSONL up to the cap remains valid, the tail may not. Covers
[[11-session-transcript-receivers|receiver growth-bounding]].

### Idle watchdog

A session with no traffic on any of the three streams is stopped at the
10-minute mark; an active one isn't. Covers [[11-session-transcript-receivers|the inactivity watchdog]].

### Launch-atomicity

Inject a failure in one required unit (e.g. an already-bound vsock path)
and confirm the whole target fails to start with no leftover running
units. Covers [[13-error-handling-failure-modes|launch-time atomicity]]
and [[10-session-lifecycle-orchestration|launch-atomicity]].

## `needs_kvm`+`needs_root` integration tests

### `kvm-pit` placement

Boot a VM, confirm the poststart script finds and moves the thread,
confirm via `cpu.stat`/`systemd-cgtop` that its CPU time now attributes to
the VM's cgroup. This specifically tests the two open risks flagged at
[[12-production-hardening|kvm-pit cgroup placement]], rather than assuming
them away. #open-question

### Cgroup delegation

Confirm `Delegate=yes` and jailer's own `--cgroup-version 2` nested
cgroup coexist without one clobbering the other's limits. Relates to
[[12-production-hardening|process isolation model]].

## `doctor` subcommand tests

Unit-tested output formatting against fake `spectre-meltdown-checker`,
`systemctl`, and hugepage-pool outputs; one `needs_root` smoke test
against the real host tools. Covers the `doctor` subcommand described in
[[12-production-hardening|production hardening & resource control]].

## Scope note

Per-chunk step-by-step test breakdown (what a test asserts, fixture
shape, etc.) lives in `todo.md`'s K4/K5 entries and is not duplicated
here — this note states the strategy and lists the scenarios this design
work introduced; `todo.md` remains the execution checklist.

## Related

- [[10-session-lifecycle-orchestration]] — unit-graph rendering and
  launch-atomicity are both tested against its design.
- [[11-session-transcript-receivers]] — growth-bounding and idle-watchdog
  logic are the two largest unit/integration test groups here.
- [[12-production-hardening]] — hugepage pool, `kvm-pit` placement, and
  cgroup delegation tests all validate mechanisms it owns.
- [[13-error-handling-failure-modes]] — launch-atomicity testing directly
  validates the fail-closed behavior described there.
- [[07-bpf-monitoring]] — `needs_bpf` marker exists for BPF-load-capable
  tests relevant to this component.
