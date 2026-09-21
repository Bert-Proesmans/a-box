---
component: session-transcript-receivers
source: agent-vm-host-spec.md
spec-section: §11
tags:
- agent-vm-host
- spec-component
---

# Session Transcript & Stream Receivers

Per session, a directory holds **separate newline-delimited JSON files, one per stream**. This is explicitly **not a re-executable recording** — it exists to support human review/audit of what happened, not deterministic replay against recorded network responses.

Each line across all three files carries a common schema (timestamp, session ID, stream/event type, payload), so the files are **directly queryable via DuckDB** (`read_json_auto`, globbing across files/sessions) and importable into **SQLite** for further analysis — no bespoke tooling required.

## Per-stream transcript files

### terminal.jsonl
Timestamped stdin/stdout chunks from the session's interactive terminal. Written by the stdio-bridge unit, not a standalone receiver — see [[#terminal-transcript tap (same connection as attach)]] below.

### proxy.jsonl
Request/response summaries from [[05-network-egress-control|mitmproxy]]:
- destination host/port as requested,
- the **resolved IP address** mitmproxy actually connected to (the host does the real DNS resolution — see [[05-network-egress-control|host-side DNS resolution]] — so this is the closest thing to a guest-side DNS answer that exists),
- whether the real credential was injected for that request (the `credential_injected` flag) — deliberately **not** redacted-away like the header value itself, since knowing *when* the secret went out is the point.

Split into one file per session via mitmproxy's per-slot listen ports, since mitmproxy itself is a host-wide singleton process shared across sessions.

### bpf.jsonl
Raw [[07-bpf-monitoring|BPF events]].

## Per-stream receivers

**`bpf.jsonl` only** is written by a small, dedicated host-side receiver process (the `recv-bpf` unit, part of [[10-session-lifecycle-orchestration|host orchestration]]'s per-session unit set). `proxy.jsonl` is *not* produced this way: it's written by mitmproxy's own transcript addon (a long-lived host-wide singleton), split per-session via the slot-port mechanism, and is deliberately **not** subject to the cap/receiver discipline described below — see [[#why proxy.jsonl and the live relay are uncapped]].

### recv-bpf

- Pre-configured with exactly **one session's vsock path**. Firecracker's vsock device is a Unix-domain-socket proxy, not real kernel `AF_VSOCK` (verified against Firecracker's own `docs/vsock.md`: it "mediates between AF_UNIX sockets (host) and AF_VSOCK sockets (guest)"); guest-initiated connections on port P surface at `<uds_path>_<P>`, and each VM has a *dedicated* `uds_path`. There is therefore no cross-session ambiguity to authenticate away, and no CID-based lookup is needed or even possible — no peer-CID is exposed to the host side at all. See [[03-vmm-firecracker|Firecracker's vsock device]].
- Listens for **one guest-initiated connection, no handshake** — the opposite direction from the interactive stdio channel, which is host-initiated and does use Firecracker's `CONNECT <port>\n` handshake.
- Runs a deliberately dumb loop: read up to N bytes, write to the `.jsonl` file, sleep an interval. This read-size/interval pairing **is** the bandwidth cap; there is no separate token-bucket mechanism.
- Enforces a **hard 100 MB cap per file**: once cumulative bytes written reaches the cap, it stops reading, closes the accepted connection, closes/unlinks the listening socket, and exits.
  - No attempt is made to stop on a JSONL line boundary — the final line past the cap may be truncated/invalid.
  - No draining-and-discarding happens once capped — this is a deliberate backstop against guest-side abuse, not a data-integrity feature; the guest's own writer is intentionally left to block/fail against the closed socket.
- Has `Restart=no` (per [[10-session-lifecycle-orchestration|the per-session unit set]]): an auto-restarted receiver would silently reopen the very socket the cap enforcement just closed, defeating the mechanism.

### terminal-transcript tap (same connection as attach)

`terminal.jsonl` is written by the stdio-bridge unit (`agentvm-session-<id>-stdio.service`) rather than a third standalone receiver, since that unit already holds the one persistent, host-initiated interactive stdio connection (needed regardless, to support `attach`/`detach`) and taps its traffic.

- Recording happens **regardless of attach state**; detaching a CLI client never touches the underlying guest connection or any other attached client.
- The same 100 MB hard-cap policy described under [[#recv-bpf]] applies to this tap as well.

> **Resolved** (decisions log, chunk C3): the interactive stdio channel and the terminal-transcript tap are literally the same vsock connection observed from the host side — one host-initiated connection, tapped for recording and fanned out to N attach clients, no guest-side change beyond pid1's existing design. Implemented in `session_manager.py`: a single background reader thread owns the only `recv()` calls on `stdio_sock`, logging every chunk to `terminal.jsonl` and broadcasting it to whichever attach clients are currently connected; attach clients themselves are handled by separate per-client threads that only ever call `sendall()` on `stdio_sock`, so there's no reader contention. Proved end-to-end in `test_session_manager_kvm.py` — see [[14-testing-strategy|integration tests]].

### why proxy.jsonl and the live relay are uncapped

Two different things are involved here, and both are deliberately uncapped:

1. **`recv-proxy`** (part of [[05-network-egress-control|the egress control path]]'s per-slot listener set) is a pure byte relay carrying the guest's actual live HTTP(S) traffic to mitmproxy. Capping it like a transcript receiver would silently sever an in-progress legitimate transfer (e.g. cloning a large repo through the allowlisted git entry) — a functional regression, not a safety win.
2. **mitmproxy's own addon** is what writes `proxy.jsonl`, and it stays uncapped so that exactly the scenario this audit trail exists to catch — a large or sustained exfiltration attempt — is never the reason its own tail gets truncated.

`bpf.jsonl` and `terminal.jsonl`, by contrast, are comparatively low-volume, compact event/byte streams where a 100 MB abuse backstop doesn't carry the same risk of discarding the most important record.

## Inactivity watchdog

Independent of, and in addition to, the total wall-clock session timeout (`RuntimeMaxSec=`, per [[10-session-lifecycle-orchestration|the per-session unit set]]): a session is stopped after **10 minutes with no output activity on any of the three transcript streams combined** — total silence across all three, not a per-channel independent timeout.

### mtime-as-signal mechanism

Chosen to need **no new IPC**:
- Each receiver (`recv-bpf`) and the stdio bridge only ever write their `.jsonl` file when real bytes arrive.
- Each creates/touches its file immediately on startup (before any real byte), so "nothing has happened *yet*" at session start doesn't read as already-idle.
- The file's own mtime *is* the last-activity signal, for free — no shared state, no polling protocol between processes.

`agentvm-session-<id>-idle.timer` fires a lightweight check roughly every **60 seconds**: take `max(mtime)` across the three `.jsonl` files; if `now - max(mtime) > 600s`, stop one of the three receiver/bridge units. The `BindsTo=` cascade already wired for the VM unit does the rest — see [[13-error-handling-failure-modes|stop cascade semantics]] and [[10-session-lifecycle-orchestration|the stop cascade]] — so the watchdog itself needs no "stop the VM" logic of its own.

## Related

- [[05-network-egress-control]] — mitmproxy is the writer of `proxy.jsonl` and owns the per-slot listen ports this section splits transcripts on.
- [[07-bpf-monitoring]] — source of the raw events written to `bpf.jsonl`.
- [[10-session-lifecycle-orchestration]] — owns the systemd unit set (`recv-bpf`, stdio-bridge, idle timer) and the `BindsTo=` stop cascade the idle watchdog triggers.
- [[13-error-handling-failure-modes]] — defines the stop cascade semantics the idle watchdog relies on.
- [[14-testing-strategy]] — integration tests proving the stdio tap/attach fan-out design end-to-end.
