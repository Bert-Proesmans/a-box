---
component: error-handling-failure-modes
source: agent-vm-host-spec.md
spec-section: §13
tags:
- agent-vm-host
- spec-component
---
# Error Handling & Failure Modes

## Launch-time atomicity

A session's unit graph — VM unit + two receivers + stdio bridge + idle
timer, all wrapped by one `.target` (see [[10-session-lifecycle-orchestration|session lifecycle & host orchestration]]) —
starts as a single systemd transaction.

`BindsTo=`/`Requires=`-family dependencies mean a failure in any required
unit (e.g. jailer failing to set up its chroot, a [[11-session-transcript-receivers|receiver]]
failing to bind its vsock UDS path) fails the whole
`systemctl start agentvm-session-<id>.target` transaction. There is no
orphaned half-started session and no manual cleanup path to write and
maintain.

`launch` surfaces the failing unit's `systemctl status`/journal output to
the user; nothing is retried automatically.

## Stop cascades

Three independent triggers converge on the same mechanism: the unit
graph's `BindsTo=` relationship, VM unit → the two [[11-session-transcript-receivers|receivers]] + stdio bridge.

1. **Manual `stop`** — a direct `systemctl stop` on the target/VM unit.
2. **Session wall-clock timeout** — `RuntimeMaxSec=` on the VM unit
   itself.
3. **A receiver or the stdio bridge stopping on its own** — whether from
   hitting its 100 MB cap (intentional; see [[11-session-transcript-receivers|growth-bounding]]),
   the idle watchdog stopping it deliberately (intentional; see
   [[11-session-transcript-receivers|inactivity watchdog]]), or an unrelated crash
   (unintentional).

All three converge on "the VM unit stops," because `BindsTo=` doesn't
distinguish *why* a bound unit went inactive. This is a deliberate
fail-closed posture for case 3's intentional half (matches "backstop
against abuse"), but it means an unrelated bug in a small receiver can
take down a whole agent session — raising the bar on keeping those
receivers minimal and well-tested (see [[14-testing-strategy|testing strategy]]),
which was the reasoning for keeping them as separate, dumb processes in
the first place ([[11-session-transcript-receivers|the receiver design]]).

## Best-effort vs. fatal failures

Not every failure should block a launch or kill a session — the spec
draws an explicit line between the two.

### Fatal (fails the launch transaction)

- Hugetlbfs pool exhaustion (surfaces as a Firecracker API/`InstanceStart`
  error) — see [[12-production-hardening|hugepage pool]].
- Chroot/uid setup failure (jailer).
- A [[11-session-transcript-receivers|receiver]] failing to bind its vsock path.
- The shared git-service/mitmproxy singletons ([[10-session-lifecycle-orchestration|session lifecycle & host orchestration]])
  not being up (`Requires=`+`After=` on those).

### Best-effort, non-fatal (logged, session proceeds)

- The `kvm-pit` cgroup-placement poststart script (see
  [[12-production-hardening|kvm-pit cgroup placement]]) failing to find or
  move the thread. #open-question
  - It affects CPU-accounting precision, not correctness or isolation —
    a failure here degrades an accounting nicety rather than the session
    itself.
  - This is a spec-level decision made for completeness; revisit if
    empirical testing (see [[14-testing-strategy|testing strategy]]) shows
    the placement is reliable enough to be a hard requirement instead.

## BPF violations

Unchanged from [[07-bpf-monitoring|BPF monitoring's violation-handling policy]]: log + alert only, never an
automatic kill on a BPF-observed event in this version.

## Related

- [[10-session-lifecycle-orchestration]] — owns the unit graph, `.target`
  wrapping, and the `BindsTo=`/`Requires=` dependency structure that both
  launch atomicity and stop cascades are built on.
- [[11-session-transcript-receivers]] — owns the receivers and stdio
  bridge whose growth-cap and idle-watchdog behavior are two of the three
  stop-cascade triggers.
- [[07-bpf-monitoring]] — owns the BPF violation detection referenced
  above.
- [[12-production-hardening]] — owns the hugepage pool exhaustion failure
  mode and the `kvm-pit` cgroup-placement script discussed as a
  best-effort failure.
- [[14-testing-strategy]] — the launch-atomicity and receiver-robustness
  scenarios described here are exercised by that layer's integration
  tests.
