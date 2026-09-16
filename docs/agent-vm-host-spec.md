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
  the git server's config, not the proxy.**
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
  wrapper) remains an open implementation choice — see §12.

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
  pipeline in this version.
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
  wrapping (git, nix, mkfs, mount), and general orchestration maturity.
- **Resource allocation:** fixed small default per guest (e.g. 1–2 vCPU,
  1–2 GB RAM), not configurable per task in this version. The host enforces
  a **host-wide cap on concurrent VMs**, rejecting new launches beyond it
  until a running session finishes.
- **Timeouts:** every session has a fixed maximum wall-clock duration (an
  adjustable default, e.g. a few hours), after which the host force-stops it
  automatically. A session can also be killed manually at any time via the
  CLI.

### 10.1 Daemon / CLI split

Session state (a running VM's Firecracker handle, its persistent stdio
vsock connection, its proxy/BPF vsock bridges) must outlive any single CLI
invocation — `launch` returns to the shell immediately, and `list`/`attach`/
`stop` are separate, later process invocations. This requires a long-lived
process to actually own that state:

- **A single long-running host daemon** (`agentvm daemon`, intended to run
  as a `systemd --user` service — unit wiring is a runbook/host-config
  concern, tracked in §12) owns every session for the process's lifetime:
  the git-mirror service and mitmproxy singletons (§6.1.1, §5.2), every
  session's `SessionManager` (stdio tee + attach fan-out, §11), its
  vsock↔TCP proxy bridge (§5.1), and its BPF receiver (§7.2).
- **The CLI is a thin RPC client.** Every subcommand (`launch`, `list`,
  `attach`, `stop`, `review`, `reap`) connects to a control Unix socket
  (fixed path under the daemon's runtime directory), sends one
  newline-delimited JSON request, and prints the JSON response. `launch`
  does not block for the session's duration — it returns as soon as the
  daemon reports the VM is running.
- **Exception:** `attach` does not proxy interactive bytes through the
  control socket. It first asks the daemon (one control-socket round trip)
  for the session's `attach.sock` path, then connects to that socket
  directly for the raw stdin/stdout passthrough (§11) — keeping bulk
  terminal I/O off the control protocol.
- This also resolves timeout enforcement more simply than a CLI-triggered
  check could: the daemon runs its own internal periodic reap loop, so an
  overdue session is stopped even if no CLI command runs for hours.
  `agentvm reap` remains available as a manual/systemd-timer trigger, but is
  no longer the only mechanism.
- **Crash recovery:** if the daemon itself restarts, it reconciles its
  on-disk session registry against actual Firecracker processes (by
  PID/API-socket liveness) at startup, matching stale "running" entries to
  reality.

### 10.2 Concurrency model

The daemon is a **single asyncio event loop** hosting all sessions as
concurrent tasks (persistent stdio connections, N attach-client fan-out,
per-connection proxy bridge relays, BPF event readers). Chosen over a
thread-per-connection model because mitmproxy's own embeddable master
(§5.2) is itself asyncio-based, so the proxy bridge composes directly into
the daemon's loop instead of needing a thread↔event-loop bridge at that
boundary.

### 10.3 Configuration

Host-wide knobs (`max_concurrent_sessions`, default vcpu/mem, default
timeout) live in a config file (e.g.
`$XDG_CONFIG_HOME/agentvm/config.toml`), read once at daemon startup, with
built-in defaults if the file is absent. Chosen over environment variables
since more host-wide knobs are expected over time (default resource
sizing, allowlist entries) and a file scales better than a pile of env
vars.

- **CLI responsibilities** (exact command surface is an implementation
  detail, but must cover):
  - Launch a session (repo + pinned commit + task input).
  - List running/recent sessions.
  - Attach/detach to a running session's interactive stdin/stdout (over its
    vsock port, screen/tmux-attach-like — detaching does not kill the
    session).
  - Stop/kill a session manually.
  - Review a finished session's result diff (§6.3) and its transcript.

## 11. Session Transcript (Playback-Only)

- Per session, a directory containing **separate newline-delimited JSON
  files per stream**:
  - `terminal.jsonl` — timestamped stdin/stdout chunks.
  - `proxy.jsonl` — request/response summaries from mitmproxy.
  - `bpf.jsonl` — raw BPF events (§7.2's log file, or a per-session split of
    it).
- Each line carries a common schema (timestamp, session ID, stream/event
  type, payload) so the files are **directly queryable via DuckDB**
  (`read_json_auto`, globbing across files/sessions) and importable into
  **SQLite** for further analysis, without any bespoke tooling.
- This is explicitly **not** a re-executable recording — it supports human
  review/audit of what happened, not deterministic replay against recorded
  network responses.

## 12. Decisions Log & Remaining Open Items

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
- **Host daemon / CLI process model** (§10.1) — a single long-running
  daemon process owns all session state; the CLI is a thin RPC client
  (newline-delimited JSON over a control Unix socket).
- **Host-side concurrency model** (§10.2) — asyncio, one event loop per
  daemon process.
- **Host-wide config source** (§10.3) — a config file, not environment
  variables.

Still open:

- **Package registry strategy per ecosystem** (§5.3) — local caching mirror
  vs. direct-through-proxy, decided as ecosystems (pip, npm, etc.) are
  actually needed. No ecosystem beyond git has been wired in yet.
- **Daemon `systemd --user` unit** — the daemon process itself is built in
  chunk I, but its supervised-startup unit (enable/start on boot vs. lazy
  first-launch start, restart policy) is not yet written; tracked for the
  chunk K3 runbook.
