---
component: session-transcript-receivers-todo
source: 11-session-transcript-receivers-plan.md
tags:
- agent-vm-host
- spec-todo
---
# Session Transcript & Stream Receivers — Todo

A step's top-level box is a summary checkbox: check it only once every nested box under it is checked.

## Chunk 1 — `recv-bpf` real wiring & cap-cascade proof

- [ ] Step 1.1 — [[11-session-transcript-receivers-plan#Step 1.1 — `recv-bpf`: real receiver wiring & cap-cascade proof|`recv-bpf`: real receiver wiring & cap-cascade proof]]
  - [ ] Replace `agentvm-session-recv-bpf@.service`'s placeholder `ExecStart=` with 07-bpf-monitoring-plan's Step 4.1 receiver script invocation
  - [ ] Pass session's dedicated BPF-export vsock UDS path and output path `<session_dir>/bpf.jsonl` via the existing `EnvironmentFile=` convention
  - [ ] Make no changes to the receiver script's own internals (read-loop, cap logic, exit behavior)
  - [ ] Note (don't patch) whether the script creates `bpf.jsonl` at zero length before accepting a connection
  - [ ] Verify: launch a real session through 10's real launch/stop CLI, drive guest activity producing BPF events, confirm `bpf.jsonl` fills in near real time
  - [ ] Verify: drive activity past the 100 MB cap, confirm the `recv-bpf` unit exits per its cap logic and 10's `BindsTo=` cascade tears down the VM unit and other helpers

## Chunk 2 — Terminal-transcript tap (`session_manager.py`)

- [ ] Step 2.1 — [[11-session-transcript-receivers-plan#Step 2.1 — Terminal tap core: reader thread, tee, and growth cap|Terminal tap core: reader thread, tee, and growth cap]]
  - [x] On startup, before any read: create `terminal.jsonl` in the session directory at zero length
  - [x] Establish the host-initiated vsock connection via the `CONNECT <port>\n` handshake against the session's dedicated per-VM UDS path
  - [x] Run one background reader thread owning the only `recv()` calls: append each chunk verbatim to `terminal.jsonl`, call a broadcast function against an in-memory attach-client list (left empty for this step)
  - [ ] Track cumulative bytes written; at the 100 MB cap, stop reading, close the connection, exit
  - [ ] Add no restart logic (unit already has `Restart=no`)
  - [x] Verify: point the script at a real guest's stdio vsock port directly; confirm `terminal.jsonl` exists at zero length before any output arrives
  - [x] Verify: confirm guest output is appended verbatim as it streams
  - [ ] Verify: confirm pushing output past the 100 MB cap stops the reader, closes the connection, and exits
  - `session_manager.py`'s `TerminalRecorder`/reader-thread plumbing already exists (pre-existing chunk C2/C3 work) — only the 100 MB growth cap and its unit's `Restart=no` wiring (that unit doesn't exist yet either) are actually missing
- [x] Step 2.2 — [[11-session-transcript-receivers-plan#Step 2.2 — Attach-socket fan-out to N clients|Attach-socket fan-out to N clients]]
  - [x] Bind `attach.sock` at the fixed path from 10's Step 2.1 convention
  - [x] Accept multiple simultaneous client connections, one thread per client
  - [x] On connect: register a callback into Step 2.1's broadcast list so the reader thread immediately begins delivering output to this client
  - [x] On client input: `sendall()` directly onto the shared guest connection (never `recv()` from it)
  - [x] On disconnect: deregister the callback, close only this client's own socket, leave the guest connection and every other client untouched
  - [x] Verify: run against a real guest connection; attach two simultaneous clients; send input from one, confirm it reaches the guest via an observable effect
  - [x] Verify: confirm both clients receive the same broadcast output
  - [x] Verify: disconnect one client, confirm the other keeps receiving output uninterrupted and the guest connection is unaffected
- [ ] Step 2.3 — [[11-session-transcript-receivers-plan#Step 2.3 — Real-graph wiring, attach-state independence, and cap-cascade proof|Real-graph wiring, attach-state independence, and cap-cascade proof]]
  - [ ] Replace `agentvm-session-stdio@.service`'s placeholder `ExecStart=` with `session_manager.py` from Steps 2.1–2.2, parameterized via the shared `EnvironmentFile=` convention
  - [ ] Leave 10's Step 3.3 attach/detach CLI unchanged (socket contract is unchanged)
  - [ ] Verify (via 10's real launch/attach/detach/stop CLI): `terminal.jsonl` records guest output regardless of attach state
  - [ ] Verify: attach, detach, re-attach mid-session — detach never interrupts recording or the guest connection; re-attach immediately sees live output (not a replay); `terminal.jsonl` keeps accumulating through the gap
  - [ ] Verify: drive guest output past the 100 MB cap, confirm 10's `BindsTo=` cascade tears down the full session as a concrete result of the terminal tap's cap

## Chunk 3 — `proxy.jsonl` transcript addon

- [ ] Step 3.1 — [[11-session-transcript-receivers-plan#Step 3.1 — `proxy.jsonl` transcript addon|`proxy.jsonl` transcript addon]]
  - [ ] Build a mitmproxy addon: for every completed flow, resolve `session_id`/`session_dir` via the local arrival port (`flow.client_conn.sockname`) looked up against the slot-assignment file
  - [ ] If no current mapping exists for that port, drop the event for that flow (no retry/backoff)
  - [ ] For a resolved flow, construct one NDJSON line: timestamp, resolved `session_id`, stream/event-type discriminator, destination host/port as requested, resolved destination IP, `credential_injected` boolean
  - [ ] Append the line to `<session_dir>/proxy.jsonl` with no cap of any kind
  - [ ] Wire the addon into `agentvm-mitmproxy.service`'s existing `ExecStart=` addon-loading arguments (no new unit, no rebuild of existing addons)
  - [ ] Verify: two acquired slots, two concurrent guest-shaped clients; an allowed request through each slot produces a correctly-tagged `proxy.jsonl` line in its own session's directory only, never cross-appearing
  - [ ] Verify: resolved IP / `credential_injected` values match 05's Step 4.1 behavior (true for the Anthropic destination, false for the git-loopback destination)
  - [ ] Verify: push one session's proxy traffic well past 100 MB, confirm `proxy.jsonl` keeps growing uncapped and no connection is closed by this addon

## Chunk 4 — Inactivity watchdog

- [ ] Step 4.1 — [[11-session-transcript-receivers-plan#Step 4.1 — Idle-watchdog mtime-comparison logic|Idle-watchdog mtime-comparison logic]]
  - [ ] Build a pure function: given the three file paths (missing file = maximally stale, not an error), an injectable clock callable, an injectable mtime-lookup callable, and a threshold parameter (default 600s)
  - [ ] Compute `max(mtime)` across the three paths via the injected lookup and return whether `now - max(mtime)` exceeds the threshold
  - [ ] Function performs no I/O of its own — only the injected dependencies touch a clock or filesystem
  - [ ] Verify: exercise with fake clocks/mtimes only (no real files, no real sleeping); confirm not-idle when all three mtimes are recent
  - [ ] Verify: confirm idle once the max mtime is older than the threshold
  - [ ] Verify: confirm a missing file is treated as maximally stale without raising an error
- [ ] Step 4.2 — [[11-session-transcript-receivers-plan#Step 4.2 — Idle-watchdog real wiring & stop-cascade trigger|Idle-watchdog real wiring & stop-cascade trigger]]
  - [ ] Replace `agentvm-session-idle@.service`'s placeholder `ExecStart=` with a real check script reading the session directory path from `EnvironmentFile=`
  - [ ] Call Step 4.1's pure function against the three real file paths using a real clock and a real stat-based mtime lookup
  - [ ] Only when the function reports idle: `systemctl stop` exactly one of the three `BindsTo=` helper units for this session (fixed choice)
  - [ ] Add no new stop-cascade logic of its own
  - [ ] Leave the timer's ~60-second recurrence interval unchanged
  - [ ] Accept the idle threshold as an overridable parameter (default 600s)
  - [ ] Note (don't resolve) whether 07's recv-bpf receiver creates `bpf.jsonl` at zero length before accepting its guest connection
  - [ ] Verify: launch a real session, generate activity on all three streams, confirm the watchdog does not stop it
  - [ ] Verify: let a second session go fully silent on all three streams; with a short overridden threshold, confirm the watchdog fires at approximately that threshold and the full cascade tears down the entire session
