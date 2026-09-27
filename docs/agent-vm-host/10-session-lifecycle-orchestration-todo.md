---
component: session-lifecycle-orchestration-todo
source: 10-session-lifecycle-orchestration-plan.md
tags:
- agent-vm-host
- spec-todo
---
# Session Lifecycle & Host Orchestration — Todo

A step's top-level box is a summary checkbox; check it only when every nested box under it is checked.

## Chunk 1 — Host-Wide Configuration

- [ ] Step 1.1 — Config file schema, loader, and defaults — [[10-session-lifecycle-orchestration-plan#Step 1.1 — Config file schema, loader, and defaults]]
  - [ ] Build a config-loading library (Python) defining a schema for the four knobs — `max_concurrent_sessions`, default guest RAM (MiB), default vCPU count, default session wall-clock timeout — with sensible built-in defaults for each
  - [ ] Load and parse a config file at a stable path under `$XDG_CONFIG_HOME` (e.g. `$XDG_CONFIG_HOME/agentvm/config.toml`, falling back to the XDG default base directory)
  - [ ] Merge file-provided values over the built-in defaults
  - [ ] Validate `max_concurrent_sessions` and vCPU count are positive integers and RAM size is a positive multiple of 2 MiB, raising a clear, specific error identifying the failed field
  - [ ] Fresh load on every call, no state cached across calls
  - [ ] Verify: no config file present → loader returns exactly the four built-in defaults
  - [ ] Verify: config file overriding only `max_concurrent_sessions` → confirm override plus the other three untouched defaults
  - [ ] Verify: invalid value for each of the three validated fields in turn (negative `max_concurrent_sessions`, zero vCPU count, RAM size not a multiple of 2 MiB) → each produces a distinct, clearly-identified validation error, not a silent fallback or generic crash

## Chunk 2 — Per-Session Systemd Unit Graph

- [ ] Step 2.1 — Session directory/metadata conventions and the target + VM-unit skeleton — [[10-session-lifecycle-orchestration-plan#Step 2.1 — Session directory/metadata conventions and the target + VM-unit skeleton]]
  - [ ] Define the on-disk session-state convention: per-session directory (e.g. `/var/lib/agentvm/sessions/<id>/`) holding `metadata.json` (repo, pinned commit, launch timestamp, write-once) and a runtime params file consumed via `EnvironmentFile=` (slot index, device paths, RAM/vCPU/timeout) — hand-write a stand-in for this task's own verification
  - [ ] Build `agentvm-session@.target`: plain target, no `ExecStart=`, groups start/stop as one transaction
  - [ ] Build `agentvm-session-vm@.service`: `ExecStart=` runs a minimal placeholder jailer/firecracker invocation (short wrapper script sleeping a token duration, exit 0, explicitly flagged as a stand-in), reading RAM/vCPU/timeout from `EnvironmentFile=` (falling back to Step 1.1's config defaults if absent), `RuntimeMaxSec=` from the resolved timeout
  - [ ] Wire `agentvm-session-vm@.service` as `PartOf=`+dependency of `agentvm-session@.target`
  - [ ] `Restart=no` on the VM unit
  - [ ] Verify: install both template units; hand-write a test instance directory + `params.env` (short timeout, e.g. 5s); `systemctl start agentvm-session@<test-id>.target`; confirm the VM unit reaches active, then confirm systemd stops it once `RuntimeMaxSec=` elapses, and confirm the target follows it down
  - [ ] Verify: start a second test instance with a normal-length timeout; `systemctl stop agentvm-session@<test-id-2>.target` manually; confirm the VM unit stops immediately
- [ ] Step 2.2 — Host-wide singleton dependency wiring (git-service, and the missing mitmproxy unit) — [[10-session-lifecycle-orchestration-plan#Step 2.2 — Host-wide singleton dependency wiring (git-service, and the missing mitmproxy unit)]]
  - [ ] (a) Add `Requires=agentvm-git-service.service` and `After=agentvm-git-service.service` to `agentvm-session-vm@.service`
  - [ ] (b) Build the missing `agentvm-mitmproxy.service`: long-lived, restart-on-failure singleton; `ExecStart=` runs the mitmproxy engine program with `--mode regular@<port>` repeated once per slot from `0` to `max_concurrent_sessions - 1` (via Step 1.1's config loader) at a fixed base port; no `Requires=`/`After=`/`BindsTo=` edge pointing at this unit from within its own file
  - [ ] (c) Add `Requires=agentvm-mitmproxy.service` and `After=agentvm-mitmproxy.service` to `agentvm-session-vm@.service`
  - [ ] Verify: stop both singletons if running, attempt `systemctl start agentvm-session@<test-id>.target`, confirm it fails to bring up the VM unit with both singletons down (or, if they auto-start via `Requires=`, confirm they start first and the VM unit waits until both are active)
  - [ ] Verify: start both singletons manually, confirm `agentvm-session-vm@.service` now starts cleanly
  - [ ] Verify: stop the target (session), confirm both singletons remain running, untouched
- [ ] Step 2.3 — `recv-bpf` and stdio placeholder helper units — [[10-session-lifecycle-orchestration-plan#Step 2.3 — `recv-bpf` and stdio placeholder helper units]]
  - [ ] Build `agentvm-session-recv-bpf@.service` and `agentvm-session-stdio@.service`, each `Restart=no`, `ExecStart=` a placeholder script that touches a fixed-path file (`bpf.jsonl` / `terminal.jsonl` respectively) then sleeps indefinitely until signaled to stop
  - [ ] State plainly in output that these `ExecStart=` scripts are throwaway stand-ins, not 11-session-transcript-receivers' real deliverable
  - [ ] Add `BindsTo=agentvm-session-recv-bpf@%i.service agentvm-session-stdio@%i.service` and matching `After=` to `agentvm-session-vm@.service`
  - [ ] Add `PartOf=agentvm-session-vm@%i.service` on each of the two new units
  - [ ] Verify: start the target for a test instance, confirm all three units (VM, recv-bpf, stdio) reach active, with the two helpers active before the VM unit per `After=`
  - [ ] Verify: manually `systemctl stop` just `agentvm-session-recv-bpf@<test-id>.service`, confirm the VM unit and the stdio unit both stop (`BindsTo=` cascade)
  - [ ] Verify: fresh test instance, manually stop the VM unit directly, confirm both helper units stop too (`PartOf=` cascade) and the target follows
- [ ] Step 2.4 — `recv-proxy` real unit and slot acquire/release wiring — [[10-session-lifecycle-orchestration-plan#Step 2.4 — `recv-proxy` real unit and slot acquire/release wiring]]
  - [ ] Build `agentvm-session-recv-proxy@.service`, `Restart=no`, `ExecStart=` runs the real slot-aware relay binary (05-network-egress-control-plan Step 5.3), reading this session's vsock UDS path and assigned slot index from `EnvironmentFile=` (hand-write a test value)
  - [ ] Add `BindsTo=`+`After=` for this unit to `agentvm-session-vm@.service` alongside the two from Step 2.3
  - [ ] Add `PartOf=agentvm-session-vm@%i.service` on this new unit
  - [ ] Add `ExecStartPre=` on `agentvm-session-vm@.service` calling 05's allocator to acquire a slot for this session id, recording the result into `EnvironmentFile=` (or confirming an already-recorded slot matches an existing allocation)
  - [ ] Add `ExecStopPost=` on the same unit releasing that slot back to the allocator and clearing its slot-assignment-file entry, regardless of why the unit stopped
  - [ ] Verify: real slot pool (small, e.g. size 2, via Step 1.1 config); start a test instance's target, confirm all three helper units + VM unit reach active, the relay is reachable on the assigned slot's mitmproxy port, and the slot-assignment file shows this session's id against that port
  - [ ] Verify: stop the target manually, confirm the slot-assignment file entry clears
  - [ ] Verify: second test instance dies via a short `RuntimeMaxSec=` instead of a manual stop, confirm the slot is still released (`ExecStopPost=` fires regardless of stop trigger)
  - [ ] Verify: manually stop just `agentvm-session-recv-proxy@<test-id>.service`, confirm the VM unit and the other two helpers all cascade down
- [ ] Step 2.5 — Idle-timer watchdog wiring — [[10-session-lifecycle-orchestration-plan#Step 2.5 — Idle-timer watchdog wiring]]
  - [ ] Build `agentvm-session-idle@.timer` (fires `agentvm-session-idle@.service` on a recurring ~60-second interval, started/stopped alongside the target) and `agentvm-session-idle@.service` (`ExecStart=` a placeholder that only logs a timestamped "watchdog tick" line and exits cleanly, must not stop anything yet)
  - [ ] Add `PartOf=agentvm-session-vm@%i.service` to both the timer and the service
  - [ ] Do not add any `BindsTo=`/`Requires=` edge from the VM unit pointing at either of these
  - [ ] Verify: start a test instance's target, confirm the idle timer and its service are both active alongside the other four units
  - [ ] Verify: manually `systemctl stop agentvm-session-idle@<test-id>.service`, confirm the VM unit and the other three helper units are unaffected (one-way direction)
  - [ ] Verify: manually stop the VM unit directly, confirm the idle timer and service both stop too, alongside the other three helpers (downward `PartOf=` cascade)
- [ ] Step 2.6 — Full unit-graph atomic-launch and stop-cascade proof — [[10-session-lifecycle-orchestration-plan#Step 2.6 — Full unit-graph atomic-launch and stop-cascade proof]]
  - [ ] Write an integration-test harness (matching this repo's testing conventions) exercising the complete graph from Steps 2.1–2.5 together, with no code changes to any unit
  - [ ] (a) Normal launch: every unit starts cleanly, confirm all six units (target, VM, three helpers, idle timer+service as one pair) reach active as one transaction
  - [ ] (b) Induced failure in one helper unit's placeholder `ExecStart=` (exit non-zero instead of sleeping, test-only) before the VM unit starts: confirm the whole target transaction fails and no unit is left running
  - [ ] (c) Each of the three `BindsTo=` helper units stopped individually after a clean launch: confirm the VM unit and remaining helpers all cascade down every time
  - [ ] (d) Short `RuntimeMaxSec=` timeout expiring: confirm the same full cascade (including the idle timer pair) as a manual stop
  - [ ] (e) Manual `stop` on the target: confirm identical cascade behavior to (c) and (d)
  - [ ] Verify: run the harness, confirm all five scenarios pass with the exact unit-state outcomes described; confirm scenario (b) leaves the session directory's slot allocation untouched — determine whether `ExecStartPre=` for that failed launch never ran or its own failure is covered by transaction rollback, and confirm no slot leak either way

## Chunk 3 — The CLI

- [ ] Step 3.1 — `launch` — [[10-session-lifecycle-orchestration-plan#Step 3.1 — `launch`]]
  - [ ] (1) Load config via Step 1.1
  - [ ] (2) Count currently-active `agentvm-session@*.target` units, reject immediately (clear "at capacity" message, no session directory created, no slot acquired, no unit started) if already at `max_concurrent_sessions`
  - [ ] (3) Generate a new opaque session id
  - [ ] (4) Invoke 06-workspace-and-repo-delivery-plan Step 1.1's mirror tool for the requested repository, resolve the commit to pin (mirror's default branch tip unless a specific commit/ref was requested)
  - [ ] (5) Invoke the device-2 and device-3 build tools to produce this session's two workspace images
  - [ ] (6) Create the session directory (Step 2.1 convention), write `metadata.json` (repo, pinned commit, launch timestamp) and the `EnvironmentFile=` (device paths, RAM/vCPU/timeout resolved from config)
  - [ ] (7) Run `systemctl start agentvm-session@<id>.target`
  - [ ] (8) Return immediately without waiting for the session to finish
  - [ ] On failure of step (7): surface the failing unit's `systemctl status`/journal output; explicitly release any slot this launch's `ExecStartPre=` may have acquired before the transaction failed (check whether systemd's rollback already ran `ExecStopPost=`, release here only if the VM unit never started at all)
  - [ ] Verify: `max_concurrent_sessions` set low (e.g. 1), no sessions running: launch one session, confirm it reaches active with a real device-2/device-3 image pair built from a real (throwaway test) mirror and commit, a populated `metadata.json`, and the mirror actually fetched (a second launch against the same repo picks up a new commit if added upstream in between)
  - [ ] Verify: with that session still running, attempt a second `launch`, confirm it is rejected before anything is created — no new session directory, no slot acquired, nothing started
  - [ ] Verify: stop the first session, confirm a subsequent `launch` now succeeds
- [ ] Step 3.2 — `list`, `review`, `transcript` — [[10-session-lifecycle-orchestration-plan#Step 3.2 — `list`, `review`, `transcript`]]
  - [ ] `list`: run `systemctl list-units` filtered to the `agentvm-session@*.target` convention, join each live unit's instance id against that session's `metadata.json`, print a table (session id, repo, commit, launch time, current systemd state)
  - [ ] `review`: given a session id (active or stopped), locate its device-3 image path and repo/commit from `metadata.json`, invoke 06-workspace-and-repo-delivery-plan Step 4.1's diff tool, print its unified-diff output directly (no custom pager)
  - [ ] `transcript`: given a session id and optionally a stream name (`terminal`/`proxy`/`bpf`), locate that session's transcript directory (Step 2.1 convention), print/stream the matching `.jsonl` file(s) verbatim; if a named file doesn't exist yet, report that plainly rather than erroring opaquely
  - [ ] Verify: one session still running, one already stopped: confirm `list` shows correct state for both
  - [ ] Verify: run `review` against the stopped session (which had changes written to its device 3 via a manual test write while it ran), confirm a real unified diff against the pinned commit prints
  - [ ] Verify: run `transcript` against either session, confirm it prints whatever placeholder-created zero-length `bpf.jsonl`/`terminal.jsonl` files Step 2.3's placeholders already touch into existence
- [ ] Step 3.3 — `attach`/`detach` — [[10-session-lifecycle-orchestration-plan#Step 3.3 — `attach`/`detach`]]
  - [ ] Extend Step 2.3's placeholder `agentvm-session-stdio@.service` script to also bind a Unix domain socket at a fixed conventional path (`attach.sock`, Step 2.1 convention), and, for this task's own verification only, echo anything written by any connected client back to that same client (stand-in for the real N-client fan-out/tee behavior)
  - [ ] Build `attach` CLI subcommand: given a session id, connect to that session's `attach.sock`, wire the connection to the CLI process's own stdin/stdout for raw passthrough until the user detaches (fixed escape sequence) or the connection closes
  - [ ] Build `detach` as the client-side action ending that local passthrough loop without touching the underlying socket or the unit — closes the CLI's own connection only, never signals `agentvm-session-stdio@.service`
  - [ ] Verify: launch a session (Step 3.1), `attach` to it, type a few bytes, confirm they echo back through the placeholder
  - [ ] Verify: `detach`, then `attach` again to the same still-running session, confirm the socket is still reachable and independent of the earlier client having disconnected
- [ ] Step 3.4 — `stop` and the `doctor` stub — [[10-session-lifecycle-orchestration-plan#Step 3.4 — `stop` and the `doctor` stub]]
  - [ ] Build `stop` CLI subcommand: given a session id, run `systemctl stop agentvm-session@<id>.target`, wait for completion, report the resulting state — relying entirely on Chunk 2's already-proven cascade and slot-release mechanics, no new teardown logic
  - [ ] Build `doctor` CLI subcommand as an explicit no-op: prints a message stating host health checks are not yet implemented (naming 12-production-hardening as the future owner), exits successfully, touches no session state and no systemd unit
  - [ ] Do not implement any `reap` command or alias
  - [ ] Verify: launch a session, run `stop` against it, confirm the target and every one of its units (VM, three helpers, idle timer pair) reach inactive, and its concurrency slot shows released in the slot-assignment file
  - [ ] Verify: run `doctor`, confirm it exits 0, prints its explicit not-yet-implemented message, and neither starts, stops, nor queries any `agentvm-session-*` unit
  - [ ] Verify: confirm no `reap` command exists in the CLI's help output

## Chunk 4 — Concurrency-Cap Proof

- [ ] Step 4.1 — Concurrency-cap enforcement under real concurrent launches — [[10-session-lifecycle-orchestration-plan#Step 4.1 — Concurrency-cap enforcement under real concurrent launches]]
  - [ ] Write an integration-test harness: set `max_concurrent_sessions` to a small number greater than one (e.g. 3) via Step 1.1's config file
  - [ ] Launch sessions up to that cap one at a time, confirming each succeeds and that `list` shows the correct growing count of active sessions
  - [ ] Attempt one more `launch` beyond the cap, confirm it is rejected with no session directory created and no slot acquired (cross-check the slot allocator's own state shows no new allocation either)
  - [ ] Stop one of the at-cap sessions, confirm its slot becomes available again (slot-assignment file) and a subsequent `launch` now succeeds, landing in the now-free slot
  - [ ] Stop all remaining sessions, confirm `list` shows zero active sessions and the slot allocator reports its pool fully free
  - [ ] Verify: run the harness end to end, confirm every stage behaves as described, with particular attention to the moment of rejection at the cap — no partial session directory, no orphaned metadata file, no slot leaked

## Related

- [[10-session-lifecycle-orchestration]] — the spec this plan implements.
- [[10-session-lifecycle-orchestration-plan]] — the plan this checklist tracks.
