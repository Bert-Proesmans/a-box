---
component: decisions-log
source: agent-vm-host-spec.md
spec-section: §15
tags:
- agent-vm-host
- spec-component
---
# Decisions Log & Remaining Open Items

Decisions the spec originally left open, pinned down during
implementation. See `docs/agent-vm-host-plan.md` and `todo.md` for the
chunk/step each landed in.

## Resolved decisions

### `git-http-backend` wrapping #decision

Relates to [[06-workspace-and-repo-delivery|workspace & repository delivery]]. A small custom
wrapper using stdlib `http.server` invoking `git http-backend` as CGI per
request — not a general-purpose CGI runner. Landed in chunk D2.

### Guest kernel build specifics #decision

Relates to [[03-vmm-firecracker]] and [[09-guest-rootfs]]. Built
via `pkgs.linuxManualConfig` directly, not `pkgs.buildLinux` (which
hardcodes `CONFIG_MODULES=y` with no override point); non-modular
(`CONFIG_MODULES=n`), producing an uncompressed ELF `vmlinux` — Firecracker
rejects `bzImage` outright ("Invalid Elf magic number" at `InstanceStart`).
`devtmpfs` is not manually mounted by pid1-init; the kernel auto-mounts it
before init runs, and a second mount fails `EBUSY`. Landed in chunk
B1/B3.

### Nix closure isolation mechanism #decision

Relates to [[09-guest-rootfs|the guest rootfs image]]. Uses nixpkgs' own `make-squashfs`
closure helper, which already produces an image with its own isolated
`/nix/store` prefix, rather than bind-mounting the host's. Landed in
chunk H1.

### vsock↔TCP shim implementation #decision

Relates to [[05-network-egress-control|the vsock↔TCP shim]]. `socat`, built via
`pkgsStatic.socat`. AF_VSOCK support has been in mainline socat since
1.7.4 (Jan 2021); no known nixpkgs breakage for this package as of
writing. Landed in chunk F5.

### vsock syscalls in pid1-init #decision

Relates to [[04-guest-pid1-init|the guest pid1-init process]]. Uses the `nix` crate's AF_VSOCK
support (already a dependency since B3's mount wrapper), not the separate
`vsock` crate — one syscall-wrapper dependency in the tree instead of
two. Landed in chunk C1.

### eBPF load privilege #decision

Relates to [[07-bpf-monitoring|BPF monitoring's load step]] and [[08-in-guest-hardening|the capability-drop sequence]].
Loaded while pid1-init is still root, before the capability-drop step.
Tracepoint/kprobe BPF program types need `CAP_BPF`+`CAP_PERFMON`
specifically (plain `CAP_BPF` alone isn't sufficient) — not worth chasing
as a fine-grained capability grant for a process that drops every
capability moments later anyway. Landed in chunk G5/K1.

### Host daemon / CLI process model — superseded #decision

Relates to [[10-session-lifecycle-orchestration|session lifecycle & host orchestration]]. Originally a
single long-running daemon process; now the CLI steers systemd unit
state directly, with no central daemon. Decided during hardening
discussion (K5) — see [[10-session-lifecycle-orchestration]] for the full
replacement design.

### Host-side concurrency model — superseded #decision

Relates to [[10-session-lifecycle-orchestration|the host-side concurrency model]]. Struck along
with the daemon above; not applicable to a systemd-unit-per-process
model.

### Host-wide config source #decision

Relates to [[10-session-lifecycle-orchestration|host-wide config sourcing]]. A config file,
not environment variables.

### Hugepages mode #decision

Relates to [[12-production-hardening|hugepages]]. `2M` (pre-allocated
hugetlbfs pool), default guest RAM 250 MiB, pool statically sized at host
boot.

### Process isolation model #decision

Relates to [[12-production-hardening|the jailer + systemd process isolation model]]. Jailer run as a systemd
unit (`Delegate=yes`, `--cgroup-version 2`), not a bespoke
daemon-supervised subprocess.

### Transcript stream delivery & growth bounding — revised #decision

Relates to [[11-session-transcript-receivers|transcript stream delivery and growth bounding]]. `terminal.jsonl`/
`bpf.jsonl` each get a dedicated per-session receiver/tap process with a
hard 100 MB cap, authenticated structurally by Firecracker's dedicated-
`uds_path`-per-VM model rather than any CID lookup. `proxy.jsonl` is
produced differently (mitmproxy's own addon, a host-wide singleton) and
is deliberately **uncapped**, along with the live proxy relay itself —
capping either risked truncating exactly the audit trail this design
exists to preserve, or silently killing legitimate large transfers.

### Inactivity watchdog #decision

Relates to [[11-session-transcript-receivers|the inactivity watchdog]]. 10-minute
combined-silence threshold, implemented via transcript-file mtimes and a
per-session systemd timer, reusing the existing stop cascade (see
[[13-error-handling-failure-modes|stop cascades]]) rather than a separate
kill path.

### cgroup version #decision

Relates to [[02-host-platform|host platform]]. v2 only, no v1 support anywhere in
this subsystem.

### `proxy.jsonl` per-session split #decision

Relates to [[05-network-egress-control|mitmproxy's per-session slot ports]] and
[[11-session-transcript-receivers|the proxy transcript split]]. mitmproxy (a host-wide
singleton) binds one TCP listen port per concurrency slot; a
slot-assignment file maps the local port a flow arrived on to a
session_id/session_dir, since mitmproxy itself never restarts between
sessions. The same slot index also backs the per-session jailer uid/gid
(see [[12-production-hardening|the jailer uid/gid allocation]]) — one shared allocator, sized by
`max_concurrent_sessions`, not two independent pools.

### `proxy.jsonl` content: resolved IP + credential-injection audit #decision

Relates to [[05-network-egress-control|mitmproxy's credential injection]] and
[[11-session-transcript-receivers|proxy.jsonl's content]]. Added the destination IP
mitmproxy actually connected to (the host's own DNS resolution result)
and a `credential_injected` boolean from F3's addon, so the log
records *when* the real key went out without ever containing its value.

### Terminal-transcript wire-level mechanism #decision

Relates to [[11-session-transcript-receivers|the terminal-transcript tap]]. The interactive
stdio channel and the terminal-transcript tap are the same
host-initiated vsock connection, tapped by a single reader thread and
fanned out to N attach clients (chunk C3) — see the resolved callout at
[[11-session-transcript-receivers]] for the concurrency argument.


### Package registry strategy per ecosystem #decision

Relates to [[05-network-egress-control|package registry proxying]] and
[[09-guest-rootfs|the guest tool allowlist]]. **Revised** — the guest never
does live, runtime package-manager installs from any registry, for any
ecosystem, full stop; this isn't a policy about *which* mechanism a future
pip/npm install would use, it's that no such install path exists or is
intended. Everything a session needs (interpreters, test/fuzz frameworks,
any interpreter-level libraries) must already be present in
[[09-guest-rootfs|the guest rootfs Nix closure]] before the session
starts — a repo whose test/build/run path needs something not already
baked in gets that library added to the tool allowlist and the image
rebuilt ([[09-guest-rootfs|the existing rebuild-on-allowlist-change
path]]), not a live fetch at runtime. Consequently mitmproxy's egress
allowlist is not expected to ever need a package-registry domain entry
under normal operation — the earlier domain-allowlist-vs-mirror framing
for *if* one were ever added is moot, not merely deferred. `pip`/`npm`
inclusion in the tool allowlist itself (as installers acting only against
already-vendored local packages, if included at all) remains a separate,
ordinary tool-allowlist curation call, no different from adding any other
CLI tool.
### Host memory: swap and KSM #decision

Relates to [[12-production-hardening|KVM/host tuning]] and
[[02-host-platform]]. Both disabled — matching Firecracker's own
production-host-setup guidance: swap disabled to prevent guest memory
being written to persistent storage under memory pressure (data-remanence
risk after a session ends), KSM disabled to prevent a cross-tenant
page-deduplication side channel letting one guest infer another's memory
access patterns — the same "tenants sharing a physical host" reasoning
already used in this subsystem to disable SMT (see
[[12-production-hardening]]). `llm-host.nix`'s actual running host
configuration (the `nixosSystem` output, not the separate `installer`
config in the same file) already satisfies both today: no swap device is
ever activated (zram backs only the ephemeral root filesystem;
`zramSwap.enable` and `services.zram-generator.enable` are both explicitly
forced off) and KSM is left at NixOS's own off-by-default
(`hardware.ksm.enable` is never set anywhere in the host config). This
decision makes both facts explicit, verified platform guarantees — with a
boot-time check alongside the existing KVM/cgroup v2 checks, and a future
`doctor`-reportable status — instead of implicit defaults that could
silently drift.

### mitmproxy multi-listener support #decision

Relates to [[05-network-egress-control|mitmproxy's per-session slot
ports]] and [[10-session-lifecycle-orchestration]]. Confirmed supported:
mitmproxy's `mode` option is a sequence, and its `proxyserver` addon
creates one independent `ServerInstance` per parsed mode spec (verified
against `mitmproxy/addons/proxyserver.py` on the project's `main` branch),
rejecting only exact duplicate listen addresses — not distinct
addresses/ports of the same mode type. `mitmdump --mode regular@<port1>
--mode regular@<port2>` therefore runs two independent forward-proxy
listeners in one process, which is exactly what the "one host-wide
singleton, N per-slot listen ports" design in
[[05-network-egress-control]] needs. The one-mitmproxy-instance-per-slot
fallback sketched alongside this open question is no longer needed.

### Static vs. dynamic per-slot listener lifecycle #decision

Relates to [[05-network-egress-control|mitmproxy's per-session slot
ports]]. Slots are pre-bound as a static, full-size pool at mitmproxy
startup (one listener per `max_concurrent_sessions` slot, all always up)
— not opened/closed dynamically per VM session, even though mitmproxy
supports that too (its `proxyserver` addon's `configure()` re-diffs
`self._instances` against `ctx.options.mode` on any runtime change,
starting/stopping `ServerInstance`s with no process restart — a confirmed
capability, just not the one used here). Matches the hugepage pool's own
"statically sized at host boot" precedent.

Considered and ruled out as a reason to prefer dynamic: cross-session
information leakage through connection/buffer reuse on a recycled slot.
Verified against mitmproxy source (`mitmproxy/proxy/server.py`,
`mitmproxy/proxy/layers/http/__init__.py`): every accepted client TCP
connection gets its own fresh `ConnectionHandler`/`Context`/`Layer` tree,
and the destination-matched upstream-connection reuse cache
(`HttpLayer.connections`) lives on that per-connection `HttpLayer`
instance — scoped to one client socket, not to the listening
`ServerInstance`. A new guest VM connecting to a previously-used slot port
gets entirely fresh handler/connection state; nothing (buffers, pooled
upstream connections, per-flow objects) carries over from the prior
occupant. This holds identically whether the listener itself is long-lived
(static) or freshly created per session (dynamic) — so the listener
lifecycle choice has no bearing on this risk.

Standing safeguard regardless of listener model: the credential-injection/
transcript addon must resolve "which session does this flow belong to"
fresh per-flow via the slot-assignment file (arrival port → session_id
lookup) — never cache or carry that resolution across flows on the same
port. This is the one place cross-session bleed could actually be
introduced (an addon bug), not mitmproxy's own connection handling.
## Still open

### Resource limits → systemd unit property mapping #open-question

Relates to [[12-production-hardening|the jailer + systemd process isolation model]]. Which of the spec'd cgroup
knobs (`blkio.throttle.*`, `memory.limit_in_bytes`,
`cpu.shares`/`cfs_quota_us`, jailer `fsize`/`no-file`) become declarative
unit directives (`MemoryMax=`, `CPUQuota=`, `IOWeight=`) versus jailer's
own raw `--cgroup`/`--resource-limit` flags is undecided.
## Related

- [[05-network-egress-control]] — vsock↔TCP shim, `proxy.jsonl` split and
  content, the mitmproxy multi-listener decision, and the package-registry
  strategy decision all live here.
- [[06-workspace-and-repo-delivery]] — the `git-http-backend` wrapping
  decision.
- [[09-guest-rootfs]] — Nix closure isolation mechanism; the guest tool
  allowlist the package-registry decision constrains.
- [[03-vmm-firecracker]] — guest kernel build format constraints
  (`vmlinux` vs `bzImage`).
- [[04-guest-pid1-init]] — vsock syscall dependency choice.
- [[07-bpf-monitoring]] and [[08-in-guest-hardening]] — eBPF load
  privilege ordering relative to capability drop.
- [[10-session-lifecycle-orchestration]] — the superseded daemon/CLI and
  concurrency models, host-wide config source, and the mitmproxy
  multi-listener decision.
- [[11-session-transcript-receivers]] — transcript delivery, growth
  bounding, inactivity watchdog, and terminal-transcript wire mechanism.
- [[12-production-hardening]] — hugepages mode, process isolation model,
  the still-open resource-limit mapping question, and the host memory
  (swap/KSM) decision.
- [[02-host-platform]] — cgroup v2-only decision and host memory
  (swap/KSM) configuration context.
- [[13-error-handling-failure-modes]] — the inactivity watchdog reuses
  this component's stop-cascade mechanism.
