---
component: session-lifecycle-orchestration
source: agent-vm-host-spec.md
spec-section: §10
tags:
- agent-vm-host
- spec-component
---

# Session Lifecycle & Host Orchestration

How sessions are launched, resourced, timed-out, and torn down — and the core architectural decision that there is no central daemon: systemd owns process lifecycle, and the CLI just steers it.

## Orchestration language

- **Language: Python**, chosen for mature libraries around calling Firecracker's REST API (over its control Unix socket), subprocess/tool wrapping (git, nix, mkfs, mount), and general orchestration maturity.
- It now backs a **CLI plus a handful of small per-unit helper scripts, not a daemon** (see below).

## Resource allocation

- **Fixed small default per guest — 250 MiB RAM** (decided; sized to fit hugetlbfs 2M-page pool allocation — see [[12-production-hardening|Production Hardening & Resource Control]]).
- vCPU count still an example (e.g. 1–2 vCPU) — not configurable per task in this version.
- The host enforces a **host-wide cap on concurrent VMs**, rejecting new launches beyond it until a running session finishes (see Configuration below).

## Timeouts

- Every session has a **fixed maximum wall-clock duration** (an adjustable default, e.g. a few hours), enforced declaratively via systemd's `RuntimeMaxSec=` on the VM's own unit — no periodic reap process is needed for this.
- A session can also be **killed manually at any time** via the CLI.
- A separate, shorter **inactivity timeout** also applies — see [[11-session-transcript-receivers|Session Transcript & Stream Receivers]] (the idle timer).

## No central daemon — the CLI steers systemd directly

### Superseded design decision

- The originally-specified single long-running host daemon owning all session state is **dropped**.
- Chunk K5's [[12-production-hardening|jailer]] + systemd wiring already gives each session's process lifecycle, resource limits, restart/cleanup and log capture to systemd; a second, custom-built supervisor duplicating that job added a layer with no independent value, and a second place for the two to disagree.
- Precedent: a security audit of a jailer-less firecracker setup independently converged on "jailer plus systemd system-service/cgroup-v2 supervision" as the target architecture — see `agent-vm/README.md`'s external references.
- Full context in [[15-decisions-log|Decisions Log & Remaining Open Items]].

### Per-session unit graph

Launching a session instantiates a templated set of systemd units, `agentvm-session-<id>-*`, started together as one transaction via a wrapping target:

- **`agentvm-session-<id>.target`** — groups everything below. `systemctl start` on this one unit launches the whole session atomically (see [[13-error-handling-failure-modes|Error Handling & Failure Modes]]).
- **`agentvm-session-<id>-vm.service`** — [[12-production-hardening|jailer]], execing firecracker, chrooted, dedicated uid/gid. `RuntimeMaxSec=<timeout>` enforces the session wall-clock cap declaratively. `BindsTo=` the three helper units below (any one of them stopping — including a deliberate self-stop — stops this unit too, see [[13-error-handling-failure-modes|the stop cascade]]); `After=` the same three, so they're listening before the VM boots and starts talking.
- **`agentvm-session-<id>-recv-proxy.service`** — the guest-initiated proxy-tunnel relay to mitmproxy ([[05-network-egress-control|Network Egress Control]]; *not* a transcript writer — see [[11-session-transcript-receivers|Session Transcript & Stream Receivers]]).
- **`agentvm-session-<id>-recv-bpf.service`** — the guest-initiated [[07-bpf-monitoring|BPF]] transcript receiver — one of [[11-session-transcript-receivers|the per-session transcript receivers]]. `PartOf=agentvm-session-<id>-vm.service` (stopping the VM stops these too — one-way, the reverse of `BindsTo=`).
- **`agentvm-session-<id>-stdio.service`** — the interactive stdio bridge: host-initiated connection to the guest's interactive vsock port, `attach.sock` fan-out, and the `terminal.jsonl` tee ([[11-session-transcript-receivers|the terminal transcript]]). `PartOf=` the VM unit, same as the receivers.
- **`agentvm-session-<id>-idle.timer`** + **`.service`** — the inactivity watchdog ([[11-session-transcript-receivers|the idle timer]]). `PartOf=` the VM unit (torn down with the session).

All of the above have **`Restart=no`** — nothing self-heals; a stopped unit is a decision, not a hiccup to paper over (an auto-restarted receiver would undo its own cap enforcement — see [[11-session-transcript-receivers|the transcript receivers' growth-bounding policy]]).

### Host-wide singleton services

Started independently of any session and outliving all of them:

- `agentvm-git-service.service` — see [[06-workspace-and-repo-delivery|Workspace & Repository Delivery]].
- `agentvm-mitmproxy.service` — see [[05-network-egress-control|Network Egress Control]].

Every session's VM unit has `Requires=`+`After=` (not `BindsTo=`/`PartOf=`) pointing at both — a one-way "must be up before I start" dependency that does not couple their lifetime to any one session.

### The CLI is a thin wrapper around systemd, not an RPC client to a custom daemon

- **`launch`** renders the unit set for a new session ID and runs `systemctl start agentvm-session-<id>.target`. Returns as soon as that call returns — it does not block for the session's duration.
- **`list`** queries `systemctl list-units 'agentvm-session-*'` plus each session's own metadata file (repo, commit, launch time) for display.
- **`attach`/`detach`** connect directly to the running session's `attach.sock` (path derived from the session ID, no lookup needed) for raw stdin/stdout passthrough ([[11-session-transcript-receivers|the stdio bridge]]) — no control-socket round trip needed first, since there's no daemon to ask.
- **`stop`** runs `systemctl stop` on the target (cascades through the unit graph above) — graceful-then-SIGKILL is `TimeoutStopSec=`/`KillMode=` on the unit, not hand-rolled.
- **`review`/`transcript`** read the session's on-disk transcript directory directly ([[11-session-transcript-receivers|the transcript directory layout]]) — nothing but systemd was ever holding this state, so there's no RPC boundary to cross.
- **`doctor`** ([[12-production-hardening|host health checks]]) runs local host checks only — never touches any session's units.
- The former **`reap`**/manual-timeout-check command is **dropped**: `RuntimeMaxSec=` makes it structurally unnecessary.

### Session registry

- There is **no daemon-mutated JSON file**.
- `systemctl list-units`/`show` against the `agentvm-session-*` naming convention **is** the authoritative live-state source.
- A thin per-session metadata file (repo, pinned commit, launch timestamp — written once at launch, never mutated) supplies the fields systemd doesn't track.
- The old design's "crash recovery" concern (reconciling a stale registry after a daemon restart) **doesn't apply here**: there is no separate long-lived process whose crash could desync from reality, since systemd's own unit state *is* reality.

## Concurrency model

**Not applicable under the design above — struck.** Each per-session process (jailer/firecracker, the two receivers, the stdio bridge, the idle timer) is its own OS process, supervised independently by systemd; there is no shared event loop or single process to describe a concurrency model for.

## Configuration

- Host-wide knobs (`max_concurrent_sessions`, default resource sizing, default timeout) live in a config file (e.g. `$XDG_CONFIG_HOME/agentvm/config.toml`), read by the CLI **on each invocation** (there is no long-lived process to read it once at startup).
- Chosen over environment variables since more host-wide knobs are expected over time (default resource sizing, allowlist entries) and a file scales better than a pile of env vars.
- `max_concurrent_sessions` is enforced by `launch` counting currently-active `agentvm-session-*.target` units before starting a new one — rejecting (no units created, nothing started — see [[13-error-handling-failure-modes|Error Handling & Failure Modes]]) if already at the cap.

## Related

- [[11-session-transcript-receivers|Session Transcript & Stream Receivers]] — the three per-session transcript streams (proxy, BPF, terminal) whose systemd units are defined here.
- [[12-production-hardening|Production Hardening & Resource Control]] — jailer wiring, uid/gid allocation, and the 250 MiB / hugetlbfs sizing rationale.
- [[13-error-handling-failure-modes|Error Handling & Failure Modes]] — the atomic-launch transaction, the stop cascade (`BindsTo=`/`PartOf=`), and cap-rejection behavior detailed here are specified in full there.
- [[05-network-egress-control|Network Egress Control]] and [[06-workspace-and-repo-delivery|Workspace & Repository Delivery]] — the two host-wide singleton services this design depends on but does not own the lifecycle of.
- [[15-decisions-log|Decisions Log & Remaining Open Items]] — records the superseded single-daemon design this section replaces.
