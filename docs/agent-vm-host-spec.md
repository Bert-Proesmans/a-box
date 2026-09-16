# Isolated LLM Code-Agent VM Host — Specification

## 1. Purpose & Scope

A single physical/virtual host runs short-lived, RAM-resident KVM microVMs, each
booting a minimal guest that runs exactly one Claude Code agent session against
one task on one repository. The host is the sole mediator between each guest
and the outside world.

- **Usage model:** single developer, personal use. No multi-tenant isolation
  requirements beyond containing the agent itself.
- **Threats defended against:**
  - Data exfiltration (prompt injection / bad judgment sending secrets or code
    to an unintended destination).
  - Damage from arbitrary code execution the agent performs.
  - Runaway or unexpected resource/network usage from an unsupervised agent.
- **Reproducibility requirement:** sessions are **not** deterministically
  re-executable. The system produces a **playback-only transcript** (terminal
  I/O, proxy traffic, BPF events) sufficient for human review/audit after the
  fact — not byte-for-byte replay against recorded network responses.

## 2. Host Platform

- Host OS is NixOS (see `llm-host.nix` in this repo), already configured with
  disko-managed btrfs storage (`@nix`, `@persistent` subvolumes), a zram root
  wiped every boot, and `boot.kernelModules = [ "kvm-amd" "kvm-intel" ]` for
  **nested virtualization** — this host itself appears to run as a guest
  (`virtualisation.hypervGuest.enable = true`), so nested virt must remain
  enabled at that outer hypervisor layer for `/dev/kvm` to be usable here.
- No new dedup/snapshot filesystem (ZFS/btrfs-CoW) is required for this
  subsystem specifically — see §6.3 for how image reuse is achieved instead.
  Continue using the existing btrfs pool for general storage.
- **cgroup v2 only, never v1.** This host mounts the unified v2 hierarchy
  exclusively (verified: `/sys/fs/cgroup/cgroup.controllers` present, no v1
  hierarchy mounted). Every cgroup-touching piece of this subsystem (jailer's
  `--cgroup-version`, systemd unit resource directives, the `kvm-pit`
  poststart placement, §12.4) must target v2 — no v1 fallback path is to be
  built or supported.

## 3. VMM: Firecracker

Firecracker's device model is deliberately minimal (virtio-block, virtio-net,
virtio-vsock, virtio-balloon/rng/pmem, and one legacy UART serial console; no
virtio-console, no PCI, no shared-memory/virtiofs). This shapes the design:

- **No virtio-net device is attached to any guest, at all.** There is no IP
  stack path out of the guest by construction, not by firewall rule.
- **virtio-vsock is the only interactive/control channel.** It carries, over
  separate vsock ports per session:
  1. Interactive stdin/stdout (replaces the need for a serial console as the
     agent's terminal).
  2. HTTP(S) proxy traffic (guest → host-local proxy).
  3. BPF event export (guest → host receiver).
- **The legacy UART serial console is retained only for early kernel boot log
  capture**, for debugging boot failures — it is a single unmultiplexed byte
  stream and is not used for anything interactive.
- Guests boot a custom kernel directly into a custom pid1 (no traditional
  init system, no initrd handoff).
- Three virtio-block devices per guest (see §6).

## 4. Guest pid1-init

A custom, statically-linked (musl target) **Rust** binary, replacing
traditional init entirely. No shell interpreter is present as pid1 or in the
boot path.

Startup sequence:
1. Mount required pseudo-filesystems (proc, sysfs, devtmpfs, tmpfs for /tmp).
2. Mount the three virtio-block devices and assemble the workspace via
   overlayfs (§6).
3. Establish the vsock connections: stdin/stdout, proxy shim, BPF exporter.
4. Load and attach the eBPF programs by invoking the libbpf-based loader
   (§7) as a setup step.
5. Configure the agent's environment (`HTTP_PROXY`/`HTTPS_PROXY` pointing at
   the local vsock-backed proxy shim — see §5.2; placeholder API credential;
   working directory).
6. Drop privileges: setuid to an unprivileged user and strip all Linux
   capabilities. (See §8 for why this is the extent of in-guest hardening.)
7. `exec` into the Claude Code agent.

## 5. Network Egress Control

### 5.1 Guest-side transport

Since there is no virtio-net, any HTTP client library expecting a
`host:port` proxy target needs a local endpoint. The guest runs a minimal
**vsock↔TCP shim** (e.g. `socat`, which supports `AF_VSOCK`) bound to
loopback, translating `127.0.0.1:<port>` to the host-side vsock proxy port.
`HTTP_PROXY`/`HTTPS_PROXY` point at this loopback address.

### 5.1.1 DNS resolution — deliberately absent in the guest

With `HTTP_PROXY`/`HTTPS_PROXY` set, a well-behaved client never resolves
the destination hostname itself: for HTTPS it sends `CONNECT
api.anthropic.com:443` to the proxy verbatim (the hostname travels as a
string, never through `getaddrinfo()`), and for plain HTTP it sends an
absolute-URI request line straight to the proxy. Resolution happens exactly
once, on the host, inside mitmproxy, using the host's own resolver. The
guest's C library is never in that path for legitimate traffic.

Consequently, the guest's `/etc/resolv.conf` ships **empty (or pointing at
`127.0.0.1` with nothing listening there)**, so any lookup fails fast
(`ECONNREFUSED`) rather than hanging on a timeout. This is not an oversight
to fix — it falls straight out of "no virtio-net device exists": even a
correctly configured resolver would have no interface to send a query over.

It doubles as a **canary**: a correctly-behaved session should generate
*zero* DNS attempts. Any that appear mean some tool isn't honoring the proxy
configuration — exactly why "DNS attempts" is one of the four things BPF
captures (§7.1), independent of allowlist/proxy enforcement.

> **Implementation note:** verify every tool in the Nix closure (git, pip,
> npm if added later) actually honors `http_proxy`/`https_proxy` for *all*
> of its network paths — some package managers have had bugs or separate
> code paths that fall back to direct resolution before honoring proxy
> config. Worst case here is a loud failure (BPF-flagged, request never
> leaves the guest), not silent exfiltration, but it's worth a smoke test
> per tool during image build.

### 5.2 Host-side proxy: mitmproxy

- **mitmproxy** (Python) performs full **TLS MITM**, exactly like a corporate
  forward proxy (Zscaler/Squid-with-SSL-bump style): it terminates TLS from
  the guest and re-encrypts to the real destination.
- The proxy's CA certificate is **baked into the guest's Nix image trust
  store at build time** (not provisioned at runtime). Rotating the CA means
  rebuilding the image.
- **Policy: allowlist of domains/destinations only.** Everything not
  explicitly permitted is blocked and logged.
- **Credential injection:** the guest is configured with a placeholder API
  key. A mitmproxy addon replaces the `Authorization` header with the real
  Anthropic API key only for the allowlisted Anthropic API destination, on
  the way out. The real key never exists in guest memory or filesystem.
- Chosen over a custom Rust proxy or Squid specifically for feature fit:
  mitmproxy already provides scriptable allowlisting and header rewriting
  with minimal custom code, despite not matching the Rust/Go/C preference
  order for the rest of the stack.
- Runs as its own host-wide singleton systemd service, independent of any
  session's lifecycle — see §10.1.

### 5.3 What's on the allowlist

- Anthropic API endpoint (for Claude Code) — credential-injected as above,
  reached as normal internet HTTPS, TLS-MITM'd.
- The host-local git service (§6.1) — allowlisted not by domain but as an
  exact **`127.0.0.1:<GIT_PORT>` loopback entry**, since mitmproxy itself is
  a host process and that address is the host's own loopback interface,
  where the git service actually listens. No fake internal hostname or DNS
  rewriting is needed. All *other* loopback/private-range targets stay
  denied, so the proxy can't be turned into an SSRF pivot onto other
  host-local services. The guest never reaches github.com directly.
- Package registries: **not decided yet** — may go through a local
  caching/pull-through mirror (matching the git approach) or be
  domain-allowlisted direct-to-internet, decided per ecosystem as they're
  added. The allowlist mechanism must support either kind of destination per
  entry.

## 6. Workspace & Repository Delivery

### 6.1 Host-local git mirroring

- The host keeps **full local mirror clones** of relevant repositories (not
  shallow, not on-demand-per-file) to cut latency and enable local
  dedup/reuse.
- **Sync timing:** the host fetches/updates its local mirror from upstream
  **on-demand, immediately before each task launch** — not on a periodic
  background timer. Every session starts from fresh upstream state, and
  launch time includes one fetch.
- The guest **never reaches GitHub directly.** It gets **restricted,
  read-only git-protocol access** (browsing branch history and file history
  — fetch/log/clone, no push/receive-pack) to a host-local git server
  serving the mirror.

#### 6.1.1 How the guest actually reaches it

- The host runs **`git-http-backend`** bound to `127.0.0.1:<GIT_PORT>`,
  serving the mirror over **plain HTTP** — no TLS needed since this leg
  never leaves the host's own loopback. It's configured to expose only the
  `upload-pack` service (fetch/clone/`ls-remote`); `receive-pack` is not
  wired up at all. **That is the actual read-only enforcement — it lives in
  the git server's config, not the proxy.** Runs as its own host-wide
  singleton systemd service, independent of any session's lifecycle — see
  §10.1.
- Device 2 (§6.2) is built as a **shallow clone (`--depth=1`)** of the
  pinned commit from the local mirror, not a bare file export. This gives
  the guest a real (tiny) `.git` directory with exactly one remote
  configured: `http://127.0.0.1:<GIT_PORT>/<repo>.git` — the host-local
  service above, never GitHub. Startup cost barely changes versus a flat
  checkout (still one commit's worth of objects), but the agent's own git
  client can now extend history on demand.
- When the agent runs `git fetch`/`git log --all`/`git blame`, the request
  takes the same path as every other guest HTTP request: guest git client →
  loopback vsock↔TCP shim → vsock → mitmproxy on the host → (allowlisted
  loopback target) → the git service. Being plain HTTP, mitmproxy doesn't
  even need to MITM this leg — it reads the request in the clear, logs it,
  and forwards it.
- **Defense in depth:** mitmproxy additionally rejects any request whose
  path contains `git-receive-pack` to this destination, even though the
  backend doesn't expose that service anyway. BPF's exec/network/file-open
  logging (§7.1) gives an independent audit trail on top of both.
- **Why not a 4th block device mounting the bare mirror directly
  (`file://`)?** That would give the guest low-level filesystem access to
  every ref/tag/packfile with no protocol-level gatekeeping and no request
  log, and would reintroduce a "how do we keep this fresh right before
  launch without rebuilding an image" problem — the on-demand HTTP fetch
  avoids both: the guest pulls only what it actually asks for, and every
  pull is logged. This is the origin of the earlier requirement that the
  agent must not reach a git process that manages the full history/blob
  store directly.
- Server-side wrapping of `git-http-backend` (CGI runner vs. a small custom
  wrapper) remains an open implementation choice — see §15.

### 6.2 Three-block-device layout per guest

| # | Device | Contents | Read-only? | Reuse scope |
|---|--------|----------|------------|-------------|
| 1 | OS/toolchain rootfs | Nix-built closure (see §9) | Read-only | Shared across **all** sessions; rebuilt only when the tool allowlist changes |
| 2 | Workspace checkout | Filesystem image (squashfs/erofs) built from a checkout of the local mirror at a pinned commit | Read-only | Shared across **all concurrently-running tasks on that commit**; rebuilt per commit |
| 3 | Per-task writable overlay | Small empty ext4 image | Read-write | Per-task only |

The guest mounts device 2 (lower) and device 3 (upper) via **overlayfs
inside the guest**, producing the merged, writable workspace view. This
achieves zero-copy reuse of both the toolchain and the checked-out code
across multiple concurrent agents — sharing happens at the read-only-image
level (the same backing file attached read-only to many VMs at once), not
via host-side CoW filesystem tricks.

### 6.3 Result extraction & review

- **No automatic git integration.** Nothing is applied to any branch,
  committed, or pushed automatically.
- After a session ends, the host loop-mounts **only device 3** (the small
  writable overlay) to extract the changed files.
- The extracted result is presented as a **terminal-based diff** (standard
  unified diff / `git diff` against the pinned base commit, viewable via
  existing tools like `delta`/`less`) for manual review. This fits the
  terminal-first interaction model used throughout.

## 7. BPF Monitoring

### 7.1 Guest side

- Written in **C using libbpf with CO-RE** (Compile Once – Run Everywhere),
  not Rust/Aya or Go/cilium-ebpf — chosen specifically because it has the
  fewest moving toolchain parts to reproduce inside a Nix build (`clang`,
  `libbpf`, `bpftool` are all mainstream, well-established nixpkgs
  packages/derivations; Aya needs a pinned nightly Rust toolchain plus
  `bpf-linker`, cilium/ebpf needs an extra `bpf2go` codegen layer).
- The compiled eBPF program + small libbpf-based loader binary is invoked by
  the Rust pid1-init as one of its setup steps (§4, step 4).
- **Captured events:**
  - Process exec (`execve` + args) — every command the agent/shell runs.
  - Network syscalls (`connect`/`sendto`) — belt-and-suspenders, since no
    virtio-net exists; catches any attempt to open a raw socket or otherwise
    bypass the intended vsock/proxy path.
  - File opens, **distinguishing read vs. write mode**.
  - DNS attempts (also belt-and-suspenders, given there's no working IP
    stack for DNS to resolve anything over).
- Events are exported to the host over the dedicated BPF vsock port (§3) as
  newline-delimited JSON.

### 7.2 Host side

- The receiver is intentionally **simple: it appends incoming JSONL events
  directly to a per-session log file.** No database, no real-time alerting
  pipeline in this version. It is one of the three per-session transcript
  receivers described in §11.1, including that section's growth-bounding
  policy.
- **Violation response: log + alert only, no automatic action.** Flagged
  events are recorded and surfaced for review, but a session is never
  auto-killed on a BPF-observed event in this version — this avoids
  false-positive kills before "normal" agent behavior is well understood.
  (Tiered/hard-kill policies can be layered in later once that baseline
  exists.)

## 8. In-Guest Hardening (Deliberately Minimal)

Only **capability dropping** is applied beyond the VM boundary itself:
setuid to an unprivileged user and strip all Linux capabilities before
`exec`-ing the agent (§4, step 6).

**Explicitly not done, by design:** seccomp filtering, read-only rootfs
enforcement, or nsjail-style namespace isolation. Rationale: nsjail-class
tooling exists to isolate a process *from other processes/tenants sharing a
kernel* — a problem that doesn't exist here, since each guest kernel runs
exactly one workload (the agent and its subprocesses) with no neighbors. The
microVM boundary is the real isolation boundary; capability dropping is
cheap defense-in-depth with no functional downside, while seccomp's cost
(building and maintaining an allowlist tolerant of arbitrary shell commands —
compilers, package managers, etc.) wasn't judged worth it for the value
added on top of the VM boundary + BPF visibility.

## 9. Guest Rootfs (Device 1)

- **Custom-built, minimal, Nix-based image**, Python-focused, containing a
  **whitelisted set of CLI tools** plus the Claude Code CLI.
- **Must be a fully self-contained Nix closure** — no bind-mounting or
  otherwise sharing the host's `/nix/store` or any other Nix store. The
  image contains exactly and only its own isolated store with the allowed
  tools.
- The mitmproxy CA certificate is installed into this image's trust store at
  build time (§5.2).
- Rebuilt only when the tool allowlist changes — otherwise reused unchanged
  across all sessions (see §6.2).

## 10. Session Lifecycle & Host Orchestration

- **Language: Python**, chosen for mature libraries around calling
  Firecracker's REST API (over its control Unix socket), subprocess/tool
  wrapping (git, nix, mkfs, mount), and general orchestration maturity. It
  now backs a CLI plus a handful of small per-unit helper scripts, not a
  daemon (§10.1).
- **Resource allocation:** fixed small default per guest — **250 MiB RAM**
  (decided; sized to fit hugetlbfs 2M-page pool allocation, §12.1), vCPU
  count still an example (e.g. 1–2 vCPU) — not configurable per task in
  this version. The host enforces a **host-wide cap on concurrent VMs**,
  rejecting new launches beyond it until a running session finishes (§10.3).
- **Timeouts:** every session has a fixed maximum wall-clock duration (an
  adjustable default, e.g. a few hours), enforced declaratively via
  systemd's `RuntimeMaxSec=` on the VM's own unit (§10.1) — no periodic
  reap process is needed for this. A session can also be killed manually at
  any time via the CLI. A separate, shorter **inactivity** timeout also
  applies — see §11.2.

### 10.1 No central daemon — the CLI steers systemd directly

**Superseded design decision** (§15): the originally-specified single
long-running host daemon owning all session state is dropped. Chunk K5's
jailer + systemd wiring already gives each session's process lifecycle,
resource limits, restart/cleanup and log capture to systemd; a second,
custom-built supervisor duplicating that job added a layer with no
independent value, and a second place for the two to disagree. (Precedent:
a security audit of a jailer-less firecracker setup independently converged
on "jailer plus systemd system-service/cgroup-v2 supervision" as the target
architecture — see `agent-vm/README.md`'s external references.)

**Per-session unit graph.** Launching a session instantiates a templated
set of systemd units, `agentvm-session-<id>-*`, started together as one
transaction via a wrapping target:

- **`agentvm-session-<id>.target`** — groups everything below.
  `systemctl start` on this one unit launches the whole session atomically
  (§13.1).
- **`agentvm-session-<id>-vm.service`** — jailer, execing firecracker,
  chrooted, dedicated uid/gid (§12.2). `RuntimeMaxSec=<timeout>` enforces
  the session wall-clock cap declaratively. `BindsTo=` the three helper
  units below (any one of them stopping — including a deliberate self-stop
  — stops this unit too, §13.2); `After=` the same three, so they're
  listening before the VM boots and starts talking.
- **`agentvm-session-<id>-recv-proxy.service`**,
  **`agentvm-session-<id>-recv-bpf.service`** — the two guest-initiated
  transcript receivers (§11.1). `PartOf=agentvm-session-<id>-vm.service`
  (stopping the VM stops these too — one-way, the reverse of `BindsTo=`).
- **`agentvm-session-<id>-stdio.service`** — the interactive stdio bridge:
  host-initiated connection to the guest's interactive vsock port,
  `attach.sock` fan-out, and (§11.1) the `terminal.jsonl` tee. `PartOf=`
  the VM unit, same as the receivers.
- **`agentvm-session-<id>-idle.timer`** + **`.service`** — the inactivity
  watchdog (§11.2). `PartOf=` the VM unit (torn down with the session).

All of the above have `Restart=no` — nothing self-heals; a stopped unit is
a decision, not a hiccup to paper over (an auto-restarted receiver would
undo its own cap enforcement, §11.1).

**Host-wide singleton services**, started independently of any session and
outliving all of them: `agentvm-git-service.service` (§6.1.1) and
`agentvm-mitmproxy.service` (§5.2). Every session's VM unit has
`Requires=`+`After=` (not `BindsTo=`/`PartOf=`) pointing at both — a
one-way "must be up before I start" dependency that does not couple their
lifetime to any one session.

**The CLI is a thin wrapper around systemd**, not an RPC client to a custom
daemon:

- `launch` renders the unit set for a new session ID and runs `systemctl
  start agentvm-session-<id>.target`. Returns as soon as that call returns
  — it does not block for the session's duration.
- `list` queries `systemctl list-units 'agentvm-session-*'` plus each
  session's own metadata file (repo, commit, launch time) for display.
- `attach`/`detach` connect directly to the running session's `attach.sock`
  (path derived from the session ID, no lookup needed) for raw
  stdin/stdout passthrough (§11.1) — no control-socket round trip needed
  first, since there's no daemon to ask.
- `stop` runs `systemctl stop` on the target (cascades through the unit
  graph above) — graceful-then-SIGKILL is `TimeoutStopSec=`/`KillMode=` on
  the unit, not hand-rolled.
- `review`/`transcript` read the session's on-disk transcript directory
  directly (§11) — nothing but systemd was ever holding this state, so
  there's no RPC boundary to cross.
- `doctor` (§12.5) runs local host checks only — never touches any
  session's units.
- The former `reap`/manual-timeout-check command is dropped:
  `RuntimeMaxSec=` makes it structurally unnecessary.

**Session registry.** There is no daemon-mutated JSON file. `systemctl
list-units`/`show` against the `agentvm-session-*` naming convention *is*
the authoritative live-state source; a thin per-session metadata file
(repo, pinned commit, launch timestamp — written once at launch, never
mutated) supplies the fields systemd doesn't track. The old design's
"crash recovery" concern (reconciling a stale registry after a daemon
restart) doesn't apply here: there is no separate long-lived process whose
crash could desync from reality, since systemd's own unit state *is*
reality.

### 10.2 Concurrency model

Not applicable under the design above — struck. Each per-session process
(jailer/firecracker, the two receivers, the stdio bridge, the idle timer)
is its own OS process, supervised independently by systemd; there is no
shared event loop or single process to describe a concurrency model for.

### 10.3 Configuration

Host-wide knobs (`max_concurrent_sessions`, default resource sizing,
default timeout) live in a config file (e.g.
`$XDG_CONFIG_HOME/agentvm/config.toml`), read by the CLI on each invocation
(there is no long-lived process to read it once at startup). Chosen over
environment variables since more host-wide knobs are expected over time
(default resource sizing, allowlist entries) and a file scales better than
a pile of env vars.

`max_concurrent_sessions` is enforced by `launch` counting currently-active
`agentvm-session-*.target` units before starting a new one — rejecting (no
units created, nothing started, §13.3) if already at the cap.

- **CLI responsibilities** (exact command surface is an implementation
  detail, but must cover):
  - Launch a session (repo + pinned commit + task input).
  - List running/recent sessions.
  - Attach/detach to a running session's interactive stdin/stdout (over its
    vsock port, screen/tmux-attach-like — detaching does not kill the
    session).
  - Stop/kill a session manually.
  - Review a finished session's result diff (§6.3) and its transcript.
  - **`doctor`** (§12.5) — report host runtime/hardware status, independent
    of any session: hardware vulnerability mitigation status
    (Spectre/Meltdown/MDS etc., via `spectre-meltdown-checker`), hugepage
    pool state, cgroup version, and jailer/systemd unit health. Read-only,
    no side effects on running sessions.

## 11. Session Transcript & Stream Receivers

- Per session, a directory containing **separate newline-delimited JSON
  files per stream**:
  - `terminal.jsonl` — timestamped stdin/stdout chunks.
  - `proxy.jsonl` — request/response summaries from mitmproxy.
  - `bpf.jsonl` — raw BPF events (§7.2).
- Each line carries a common schema (timestamp, session ID, stream/event
  type, payload) so the files are **directly queryable via DuckDB**
  (`read_json_auto`, globbing across files/sessions) and importable into
  **SQLite** for further analysis, without any bespoke tooling.
- This is explicitly **not** a re-executable recording — it supports human
  review/audit of what happened, not deterministic replay against recorded
  network responses.

### 11.1 Per-stream receivers

**Delivery mechanism:** `proxy.jsonl` and `bpf.jsonl` are each written by
their own small, dedicated host-side receiver process (§10.1's
`recv-proxy`/`recv-bpf` units) — one per stream, deliberately kept separate
rather than a single multiplexed process, to avoid any need for
stream-routing logic. Each receiver:

- is pre-configured with exactly one session's vsock path. Firecracker's
  vsock device is a Unix-domain-socket proxy, not real kernel AF_VSOCK
  (verified against Firecracker's own `docs/vsock.md`: it "mediates between
  AF_UNIX sockets (host) and AF_VSOCK sockets (guest)"); guest-initiated
  connections on port P surface at `<uds_path>_<P>`, and each VM has a
  *dedicated* `uds_path`. There is therefore no cross-session ambiguity to
  authenticate away, and no CID-based lookup is needed or even possible —
  no peer-CID is exposed to the host side at all.
- listens for one guest-initiated connection, **no handshake** (the
  opposite direction from the interactive stdio channel below, which is
  host-initiated and does use Firecracker's `CONNECT <port>\n` handshake).
- runs a deliberately dumb loop: read up to N bytes, write to the `.jsonl`
  file, sleep an interval — this read-size/interval pairing *is* the
  bandwidth cap; there is no separate token-bucket mechanism.
- enforces a **hard 100 MB cap per file**: once cumulative bytes written
  reaches the cap, stop reading, close the accepted connection, close/
  unlink the listening socket, and exit. No attempt is made to stop on a
  JSONL line boundary (the final line past the cap may be truncated/
  invalid) and no draining-and-discarding happens once capped — this is a
  deliberate backstop against guest-side abuse, not a data-integrity
  feature, and the guest's own writer is intentionally left to block/fail
  against the closed socket.
- has `Restart=no` (§10.1): an auto-restarted receiver would silently
  reopen the very socket the cap enforcement just closed, defeating the
  mechanism.

`terminal.jsonl` is written by the stdio-bridge unit
(`agentvm-session-<id>-stdio.service`) rather than a third standalone
receiver, since that unit already holds the one persistent, host-initiated
interactive stdio connection (needed regardless, to support `attach`/
`detach`) and taps its traffic. Recording happens **regardless of attach
state**; detaching a CLI client never touches the underlying guest
connection or any other attached client. The same 100 MB hard-cap policy
above applies to this tap as well.

> **Open wire-level detail** (§15): whether the interactive stdio channel
> and the terminal-transcript tap are literally the same vsock connection
> observed from the host side (a single host-initiated connection, tapped
> for recording and fanned out to N attach clients — the model assumed
> above, requiring no guest-side change beyond pid1's existing design) or
> become two separate guest-side connections (one interactive, one a
> guest-initiated logging push symmetric with proxy/bpf) was not fully
> pinned down by the discussion that produced this section, which focused
> on the proxy/bpf case. Revisit if implementation makes the single-tapped-
> connection model awkward.

### 11.2 Inactivity watchdog

Independent of, and in addition to, the total wall-clock session timeout
(`RuntimeMaxSec=`, §10.1): a session is stopped after **10 minutes with no
output activity on any of the three transcript streams combined** — total
silence across all three, not a per-channel independent timeout.

Mechanism, chosen to need no new IPC: each receiver (§11.1) and the stdio
bridge only ever write their `.jsonl` file when real bytes arrive, and each
creates/touches its file immediately on startup (before any real byte) so
"nothing has happened *yet*" at session start doesn't read as
already-idle. The file's own mtime *is* the last-activity signal, for free.

`agentvm-session-<id>-idle.timer` fires a lightweight check roughly every
60 seconds: take `max(mtime)` across the three `.jsonl` files; if `now -
max(mtime) > 600s`, stop one of the three receiver/bridge units — the
`BindsTo=` cascade already wired for the VM unit (§10.1) does the rest, so
the watchdog itself needs no "stop the VM" logic of its own.

## 12. Production Hardening & Resource Control

### 12.1 Hugepages

Guest memory is backed by **pre-allocated hugetlbfs pages (`2M` mode)**,
chosen over `None`/`Transparent` despite snapshotting being explicitly out
of scope for this project (the usual reason to prefer `2M` is performance
under snapshot/UFFD workflows, which don't apply here — `2M` is still
chosen anyway). Default guest RAM is **250 MiB** per session (a multiple of
2, i.e. exactly 125 hugetlbfs pages, no leftover 4K fragment).

The hugetlbfs pool is **statically sized at host boot** via NixOS's own
kernel/sysctl configuration (`boot.kernel.sysctl."vm.nr_hugepages"` or
equivalent), not allocated/resized dynamically per launch — sized to `250
MiB × max_concurrent_sessions` (§10.3). An undersized pool causes erratic
behavior/`SIGBUS` in a guest rather than a clean failure, so this value
must never drift from the configured concurrency cap; the two are set
together, by hand, in host config, not derived at runtime.

The chosen mode is wired into `FirecrackerVM`'s `/machine-config` PUT
(`huge_pages` field) alongside `vcpu_count`/`mem_size_mib`.

**Interaction with `nx_huge_pages` (§12.4):** KVM's default iTLB-multihit
mitigation splits its own guest-physical→host-physical (EPT/NPT) mappings
for executable regions down to 4K, independent of whether the underlying
host memory is hugetlbfs-backed. Left at its default, this can silently
negate the entire point of choosing `2M` here — §12.4 must be decided
alongside this, not treated as an independent checkbox.

### 12.2 Jailer + systemd (process isolation model)

Every session's `firecracker` process runs under **`jailer`** (bundled in
the same nixpkgs `firecracker` derivation — verified by building it:
`1.16.1` ships `firecracker` + `jailer` + others in one `bin/`, no extra
packaging needed), itself run *as* a systemd unit
(`agentvm-session-<id>-vm.service`, §10.1) rather than spawned and
supervised by a bespoke daemon.

What jailer alone provides: chroot via `pivot_root` into
`<chroot_base>/<exec_file_name>/<id>/root`; always a new mount namespace; a
`setuid`/`setgid` drop to a **unique uid/gid per concurrent session**. It
does *not* provide, without extra flags: restart/liveness supervision,
stdout/stderr capture, declarative resource limits, or guaranteed cleanup
on crash — systemd supplies all of these on top:

- `Delegate=yes` on the VM unit lets systemd own the top of the cgroup
  subtree while jailer creates its own nested cgroup underneath for the
  VM's threads, without the two fighting over the same cgroup node (cgroup
  v2's "no internal process constraint").
- Killing the unit/scope reliably kills the whole cgroup — this is what
  avoids the orphan risk jailer's own docs call out: with `--daemonize` but
  no `--new-pid-ns`, jailer's PID and firecracker's PID differ, so killing
  jailer alone would not kill firecracker.
- `IPAddressDeny=any` (no `IPAddressAllow=` needed) on the VM unit, since it
  has no legitimate network need at all — only a local vsock UDS (§12.3) —
  is a second, defense-in-depth backstop alongside chunk F's egress
  allowlist.
- **`--cgroup-version 2` must be passed explicitly.** jailer's own default
  is `--cgroup-version 1`; this host mounts cgroup v2 only (§2) — an
  unspecified `--cgroup-version` would target a hierarchy that doesn't
  exist on this host.

### 12.3 Network egress hardening (corrected against generic guidance)

There is no TAP/virtio-net device anywhere in this design (§3). Generic
Firecracker production-hardening advice to rate-limit "the guest's network
interface" or block TAP traffic to the cloud IMDS address
(`169.254.169.254`) does not apply and is not implemented: there is no
IP-layer path for the guest to reach that address, or anywhere else, in the
first place, since there is no network interface to route through.

What does apply: `IPAddressDeny=any` on the VM unit (§12.2) confines the
one process that *could* misuse a network capability if compromised, even
though it isn't supposed to have one. Rate-limiting the *live* proxied HTTP
traffic (distinct from the transcript-log bandwidth cap, §11.1) has no
Firecracker-API mechanism to lean on — the `Vsock` device schema has no
rate-limiter field, unlike `drives`/`network-interfaces` (verified against
the API spec) — so if wanted at all, it has to happen in host software (the
vsock↔mitmproxy bridge relay loop, or a mitmproxy addon); not built in this
version.

### 12.4 KVM/host tuning

- **`min_timer_period_us`**: lowers host CPU overhead from guest-injected
  timer interrupts (via the `kvm-pit` kernel thread, below). Applied via a
  kernel module parameter, made **explicit in host config** (`llm-host.nix`,
  `boot.extraModprobeConfig` or equivalent, for `options kvm
  min_timer_period_us=<N>`) rather than an ad hoc one-off `modprobe` — the
  exact value needs measuring against this guest kernel's actual timer
  usage, not assumed.
- **`kvm-pit` thread cgroup placement is not automatic.** Verified against
  current kernel source: `arch/x86/kvm/i8254.c`'s `kvm_create_pit()`
  creates its worker via `kthread_run_worker(0, "kvm-pit/%d", pid_nr)`, and
  `kernel/kthread.c` shows every kthread is actually forked from the global
  `kthreadd` (PID 2) context — the `%d` in the name is cosmetic (the
  creating thread's PID, for identification only), not a real
  parent/cgroup relationship. `Delegate=yes` (§12.2) cannot reach it, since
  delegation only covers processes forked from the unit's own tree.
  Mitigation: an `ExecStartPost=` script on the VM unit locates the
  `kvm-pit/<tid>` task (scan for a TID under firecracker's own
  `/proc/<pid>/task/`) and writes its PID into the unit's own
  `cgroup.procs`. Two risks, to be confirmed by testing rather than assumed
  (§14): PIT creation is lazy (first guest PIT access, not process start)
  so a single-shot poststart check may race it and needs a retry/poll; and
  whether a kernel-thread PID can be freely migrated via `cgroup.procs` the
  way a normal process's can (no definitive kernel documentation found
  either way).
- **SMT**: per Firecracker's own guidance ("SMT is frequently a
  precondition for speculation issues... where one tenant could leak
  information to another"), disabled (`nosmt` on the host kernel cmdline) —
  this project's concurrent agent sessions are exactly the "tenants sharing
  a physical host" scenario the guidance warns about. Designed for the
  eventual bare-metal deployment target; the current Hyper-V-nested dev
  environment can't actually enforce this at the physical layer, which is
  expected and acceptable for dev.
- **`nx_huge_pages=never`** (module parameter, same modprobe-config
  mechanism as `min_timer_period_us`), chosen over cgroup v2's
  `favordynmods` remount — needed to actually realize `2M` hugepages'
  benefit for executable guest memory (§12.1). **Also made explicit in host
  config**, not applied ad hoc.
- **cgroup v2 only** — see §2; jailer's `--cgroup-version 2` (§12.2) and the
  above are all v2-targeted, no v1 fallback.

### 12.5 The `doctor` CLI subcommand

Reports host runtime/hardware status independent of any session, read-only,
no side effects:

- Hardware vulnerability mitigation status via `spectre-meltdown-checker` —
  this is the delivery mechanism for "run it once, record the result in the
  runbook": `doctor` makes it a repeatable, on-demand check instead of a
  one-time manual run.
- Hugepage pool state (configured vs. actually available, §12.1).
- cgroup version in use (must report v2; a v1 finding here is a
  host-misconfiguration bug, §2).
- jailer/systemd unit health for the hardening measures above, including
  whether the shared singleton services (§10.1) are up.

## 13. Error Handling & Failure Modes

### 13.1 Launch-time atomicity

A session's unit graph (§10.1: VM unit + two receivers + stdio bridge +
idle timer, wrapped by one `.target`) starts as a single systemd
transaction. `BindsTo=`/`Requires=`-family dependencies mean a failure in
any required unit (e.g. jailer failing to set up its chroot, a receiver
failing to bind its vsock UDS path) fails the whole `systemctl start
agentvm-session-<id>.target` transaction — no orphaned half-started
session, no manual cleanup path to write and maintain. `launch` surfaces
the failing unit's `systemctl status`/journal output to the user; nothing
is retried automatically.

### 13.2 Stop cascades

Three independent triggers converge on the same mechanism (§10.1's
`BindsTo=`, VM unit → the two receivers + stdio bridge):

1. Manual `stop` (direct `systemctl stop` on the target/VM unit).
2. Session wall-clock timeout (`RuntimeMaxSec=` on the VM unit itself).
3. A receiver or the stdio bridge stopping on its own — whether from
   hitting its 100 MB cap (§11.1, intentional), the idle watchdog stopping
   it deliberately (§11.2, intentional), or an unrelated crash
   (unintentional).

All three converge on "the VM unit stops," because `BindsTo=` doesn't
distinguish *why* a bound unit went inactive. This is a deliberate
fail-closed posture for case 3's intentional half (matches "backstop
against abuse"), but it means an unrelated bug in a small receiver can take
down a whole agent session — raising the bar on keeping those receivers
minimal and well-tested (§14), which was the reasoning for keeping them as
separate, dumb processes in the first place (§11.1).

### 13.3 Best-effort vs. fatal failures

Not every failure should block a launch or kill a session:

- **Fatal** (fails the launch transaction, §13.1): hugetlbfs pool
  exhaustion (surfaces as a Firecracker API/InstanceStart error),
  chroot/uid setup failure, a receiver failing to bind its vsock path, the
  shared git-service/mitmproxy singletons (§10.1) not being up
  (`Requires=`+`After=` on those).
- **Best-effort, non-fatal** (logged, session proceeds): the `kvm-pit`
  cgroup-placement poststart script (§12.4) failing to find or move the
  thread — it affects CPU-accounting precision, not correctness or
  isolation, so a failure here degrades an accounting nicety rather than
  the session itself. This is a spec-level decision made for completeness;
  revisit if empirical testing (§14) shows the placement is reliable enough
  to be a hard requirement instead.

### 13.4 BPF violations

Unchanged from §7.2: log + alert only, never an automatic kill on a
BPF-observed event in this version.

## 14. Testing Strategy

Test markers (repo-wide convention, tracked in `todo.md`): `needs_kvm`
(requires `/dev/kvm`), `needs_root` (elevated privileges — loop-mounts, BPF
load, cgroup/jailer operations), `needs_bpf` (BPF load capability).
Unmarked tests run anywhere, including CI without virtualization.

Layered approach, consistent with the rest of the project (fakes for unit
tests, real KVM for integration):

- **Unit tests, no VM needed:** receiver read-loop cap logic (byte
  counting, close-on-cap, no line-boundary special-casing) against a fake
  socket; idle-watchdog mtime-comparison logic against a fake clock and
  fake files; unit-file/target rendering (§10.1) against fixture session
  IDs; pure functions for the jailer invocation argv (mirrors the existing
  `build_cap_drop_plan` pattern).
- **`needs_kvm` integration tests**, on this host's fixture kernel/rootfs:
  - Hugepage boot-time benchmark: `2M` vs `None` (§12.1).
  - Growth-bounding: a receiver fed past 100 MB stops reading and the file
    caps at exactly that size; JSONL up to the cap remains valid, the tail
    may not (§11.1).
  - Idle watchdog: a session with no traffic on any of the three streams is
    stopped at the 10-minute mark; an active one isn't (§11.2).
  - Launch-atomicity: inject a failure in one required unit (e.g. an
    already-bound vsock path) and confirm the whole target fails to start
    with no leftover running units (§13.1).
- **`needs_kvm`+`needs_root` integration tests:**
  - `kvm-pit` placement: boot a VM, confirm the poststart script finds and
    moves the thread, confirm via `cpu.stat`/`systemd-cgtop` that its CPU
    time now attributes to the VM's cgroup (§12.4 — this specifically tests
    the two open risks flagged there, rather than assuming them away).
  - Cgroup delegation: confirm `Delegate=yes` and jailer's own
    `--cgroup-version 2` nested cgroup coexist without one clobbering the
    other's limits.
- **`doctor` subcommand** (§12.5): unit-tested output formatting against
  fake `spectre-meltdown-checker`/`systemctl`/hugepage-pool outputs; one
  `needs_root` smoke test against the real host tools.

Per-chunk step-by-step test breakdown (what a test asserts, fixture shape,
etc.) lives in `todo.md`'s K4/K5 entries and is not duplicated here — this
section states the strategy and lists the scenarios this design work
introduced; `todo.md` remains the execution checklist.

## 15. Decisions Log & Remaining Open Items

Decisions the spec originally left open, pinned down during implementation
(see `docs/agent-vm-host-plan.md` and `todo.md` for the chunk/step each
landed in):

- **`git-http-backend` wrapping** (§6.1.1) — a small custom wrapper using
  stdlib `http.server` invoking `git http-backend` as CGI per request, not
  a general-purpose CGI runner (chunk D2).
- **Guest kernel build specifics** (§3, §9) — built via
  `pkgs.linuxManualConfig` directly, not `pkgs.buildLinux` (which hardcodes
  `CONFIG_MODULES=y` with no override point); non-modular
  (`CONFIG_MODULES=n`), producing an uncompressed ELF `vmlinux` — Firecracker
  rejects `bzImage` outright ("Invalid Elf magic number" at InstanceStart).
  `devtmpfs` is not manually mounted by pid1-init; the kernel auto-mounts it
  before init runs, and a second mount fails `EBUSY` (chunk B1/B3).
- **Nix closure isolation mechanism** (§9) — nixpkgs' own `make-squashfs`
  closure helper, which already produces an image with its own isolated
  `/nix/store` prefix rather than bind-mounting the host's (chunk H1).
- **vsock↔TCP shim implementation** (§5.1) — `socat`, built via
  `pkgsStatic.socat`. AF_VSOCK support has been in mainline socat since
  1.7.4 (Jan 2021); no known nixpkgs breakage for this package as of
  writing (chunk F5).
- **vsock syscalls in pid1-init** (§4) — the `nix` crate's AF_VSOCK support
  (already a dependency since B3's mount wrapper), not the separate `vsock`
  crate — one syscall-wrapper dependency in the tree instead of two
  (chunk C1).
- **eBPF load privilege** (§7.1, §8) — loaded while pid1-init is still
  root, before the capability-drop step (§8). Tracepoint/kprobe BPF program
  types need `CAP_BPF`+`CAP_PERFMON` specifically (plain `CAP_BPF` alone
  isn't sufficient) — not worth chasing as a fine-grained capability grant
  for a process that drops every capability moments later anyway
  (chunk G5/K1).
- **Host daemon / CLI process model** (§10.1) — **superseded.** Originally
  a single long-running daemon process; now the CLI steers systemd unit
  state directly, with no central daemon (K5, decided during hardening
  discussion — see §10.1 for the full replacement design).
- **Host-side concurrency model** (§10.2) — **superseded**, struck along
  with the daemon above; not applicable to a systemd-unit-per-process model.
- **Host-wide config source** (§10.3) — a config file, not environment
  variables.
- **Hugepages mode** (§12.1) — `2M` (pre-allocated hugetlbfs pool), default
  guest RAM 250 MiB, pool statically sized at host boot.
- **Process isolation model** (§12.2) — jailer run as a systemd unit
  (`Delegate=yes`, `--cgroup-version 2`), not a bespoke daemon-supervised
  subprocess.
- **Transcript stream delivery & growth bounding** (§11.1) — three (not
  one multiplexed) per-session receiver processes, hard 100 MB cap per
  file, authenticated structurally by Firecracker's dedicated-`uds_path`-
  per-VM model rather than any CID lookup.
- **Inactivity watchdog** (§11.2) — 10-minute combined-silence threshold,
  implemented via transcript-file mtimes and a per-session systemd timer,
  reusing the existing stop cascade rather than a separate kill path.
- **cgroup version** (§2) — v2 only, no v1 support anywhere in this
  subsystem.

Still open:

- **Package registry strategy per ecosystem** (§5.3) — local caching mirror
  vs. direct-through-proxy, decided as ecosystems (pip, npm, etc.) are
  actually needed. No ecosystem beyond git has been wired in yet.
- **Resource limits → systemd unit property mapping** (§12.2) — which of
  the spec'd cgroup knobs (`blkio.throttle.*`, `memory.limit_in_bytes`,
  `cpu.shares`/`cfs_quota_us`, jailer `fsize`/`no-file`) become declarative
  unit directives (`MemoryMax=`, `CPUQuota=`, `IOWeight=`) versus jailer's
  own raw `--cgroup`/`--resource-limit` flags is undecided.
- **Host memory: swap and KSM** (§12.4) — whether/how to disable swap (or
  secure it) and disable KSM has not been decided against `llm-host.nix`'s
  actual configuration (zram root, no swap partition currently defined).
- **Terminal-transcript wire-level mechanism** (§11.1) — whether recording
  taps the same host-initiated connection used for interactive attach, or
  becomes a second, guest-initiated logging push symmetric with
  proxy/bpf's receivers, is not fully pinned down.
- **Chunk I re-specification** — I1–I8 in `todo.md` still describe the
  superseded daemon/registry/RPC design (§10.1's "Host daemon / CLI process
  model" decision above) and need rewriting against the systemd-unit model
  before implementation starts there.
