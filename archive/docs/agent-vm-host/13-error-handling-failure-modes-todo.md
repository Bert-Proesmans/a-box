---
component: error-handling-failure-modes-todo
source: 13-error-handling-failure-modes-plan.md
tags:
- agent-vm-host
- spec-todo
---
# Error Handling & Failure Modes — Todo

A step's top-level box is a summary checkbox: check it only once every nested box under it is checked.

## Chunk 1 — Launch-time failure behavior: atomicity, surfacing, and fatal-vs-best-effort classification

- [ ] Step 1.1 — [[13-error-handling-failure-modes-plan#Step 1.1 — Real-graph launch-atomicity proof and failure-surfacing verification|Real-graph launch-atomicity proof and failure-surfacing verification]]
  - [ ] Write a `needs_kvm` integration test (standalone module, marked via plain comment/docstring — no shared marker infra built here)
  - [ ] Stage 1: launch one real session via the launch CLI, confirm it reaches active cleanly
  - [ ] Stage 2: stop it, then pre-occupy the recv-bpf helper's dedicated vsock UDS path for a fresh session id (bind and hold open a UDS at the exact path a new launch would use)
  - [ ] Stage 3: call launch for that new session id; confirm the whole target transaction fails to start, every unit in the session's graph shows inactive (no orphaned half-started session), the concurrency slot is not left held, and launch's CLI output names the specific failing unit (recv-bpf) with its `systemctl status`/journal content distinctly
  - [ ] Stage 4: release the held socket, retry launch for the same session id, confirm it now succeeds
  - [ ] If the surfacing check reveals generic (not unit-specific) output, fix the existing failure-surfacing code minimally rather than building a second mechanism
  - [ ] Verify: run the test, confirm all four stages produce the outcomes above

- [ ] Step 1.2 — [[13-error-handling-failure-modes-plan#Step 1.2 — Fatal-vs-best-effort failure classification proof|Fatal-vs-best-effort failure classification proof]]
  - [ ] Write two `needs_kvm`+`needs_root` integration tests, run back to back
  - [ ] Test (a) fatal/hugepage exhaustion: shrink the real kernel-reported hugetlbfs pool below what a new session's guest RAM requires (without changing the CLI config's accounting); launch a session; confirm the real jailer/firecracker InstanceStart-equivalent call fails for lack of hugepages, the whole launch transaction fails atomically with the same no-orphaned-units/slot-not-leaked signature as Step 1.1, and failure-surfacing output includes the real Firecracker-level error text; restore the pool and confirm a subsequent launch succeeds normally
  - [ ] Test (b) best-effort/`kvm-pit` placement failure: induce the poststart script's thread-migration step to fail for real (e.g. make the delegated cgroup's `cgroup.procs` temporarily unwritable for that one invocation); launch a session; confirm the poststart script logs its move-failed outcome distinctly and the VM unit still reaches active with the session fully usable; if the VM unit instead fails to start, report this as a confirmed real gap rather than patching the script
  - [ ] Verify: run both scenarios, confirm the fatal case matches Step 1.1's atomic-failure signature exactly, and the best-effort case leaves the session fully functional with only a log entry (or the gap above is a confirmed finding)

## Chunk 2 — Stop-cascade convergence

- [ ] Step 2.1 — [[13-error-handling-failure-modes-plan#Step 2.1 — Stop-cascade convergence proof across all three triggers|Stop-cascade convergence proof across all three triggers]]
  - [ ] Write one `needs_kvm` integration test harness against freshly-launched real sessions, one per scenario (not shared)
  - [ ] Scenario 1: manual `systemctl stop` on the target
  - [ ] Scenario 2: a short `RuntimeMaxSec=` timeout expiring on its own
  - [ ] Scenario 3: the real recv-bpf receiver's 100 MB cap hit by driving real guest BPF-event volume past the threshold
  - [ ] Scenario 4: the real terminal-transcript tap's 100 MB cap hit by driving real terminal output past the threshold
  - [ ] Scenario 5: the real idle-timer watchdog firing after a short overridden silence threshold with no activity on any of the three streams
  - [ ] For each scenario, capture and compare: final systemd state of every unit in the session's graph (all inactive), whether any process from the graph is still running at the OS level (none), and whether the concurrency slot is released (must be, in every case)
  - [ ] Assert the five outcome signatures are identical to each other in every respect
  - [ ] Verify: run the harness, confirm all five scenarios converge on the identical teardown signature
