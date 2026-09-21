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

## Still open

### Package registry strategy per ecosystem #open-question

Relates to [[05-network-egress-control|package registry proxying]]. Local caching mirror vs.
direct-through-proxy, decided as ecosystems (pip, npm, etc.) are actually
needed. No ecosystem beyond git has been wired in yet.

### Resource limits → systemd unit property mapping #open-question

Relates to [[12-production-hardening|the jailer + systemd process isolation model]]. Which of the spec'd cgroup
knobs (`blkio.throttle.*`, `memory.limit_in_bytes`,
`cpu.shares`/`cfs_quota_us`, jailer `fsize`/`no-file`) become declarative
unit directives (`MemoryMax=`, `CPUQuota=`, `IOWeight=`) versus jailer's
own raw `--cgroup`/`--resource-limit` flags is undecided.

### Host memory: swap and KSM #open-question

Relates to [[12-production-hardening|KVM/host tuning]] and [[02-host-platform]].
Whether/how to disable swap (or secure it) and disable KSM has not been
decided against `llm-host.nix`'s actual configuration (zram root, no swap
partition currently defined).

### mitmproxy multi-listener support #open-question

Relates to [[05-network-egress-control|mitmproxy's per-session slot ports]] and
[[10-session-lifecycle-orchestration]]. Needs confirming that a single
mitmproxy process can bind multiple simultaneous listen addresses (one
per concurrency slot) before implementation starts on the
`proxy.jsonl`-per-session-split mechanism; if it can't, the fallback is
one mitmproxy instance per slot instead of one host-wide singleton,
changing that service's "host-wide singleton" framing.

## Related

- [[05-network-egress-control]] — vsock↔TCP shim, `proxy.jsonl` split and
  content, and the package-registry open question all live here.
- [[06-workspace-and-repo-delivery]] — the `git-http-backend` wrapping
  decision.
- [[09-guest-rootfs]] — Nix closure isolation mechanism.
- [[03-vmm-firecracker]] — guest kernel build format constraints
  (`vmlinux` vs `bzImage`).
- [[04-guest-pid1-init]] — vsock syscall dependency choice.
- [[07-bpf-monitoring]] and [[08-in-guest-hardening]] — eBPF load
  privilege ordering relative to capability drop.
- [[10-session-lifecycle-orchestration]] — the superseded daemon/CLI and
  concurrency models, host-wide config source, and the mitmproxy
  multi-listener open question.
- [[11-session-transcript-receivers]] — transcript delivery, growth
  bounding, inactivity watchdog, and terminal-transcript wire mechanism.
- [[12-production-hardening]] — hugepages mode, process isolation model,
  resource-limit mapping, and host memory (swap/KSM) open questions.
- [[02-host-platform]] — cgroup v2-only decision and host memory
  configuration context.
- [[13-error-handling-failure-modes]] — the inactivity watchdog reuses
  this component's stop-cascade mechanism.
