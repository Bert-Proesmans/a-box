---
component: production-hardening
source: agent-vm-host-spec.md
spec-section: §12
tags:
- agent-vm-host
- spec-component
---

# Production Hardening & Resource Control

## Hugepages

Guest memory is backed by **pre-allocated hugetlbfs pages (`2M` mode)**, chosen over `None`/`Transparent` despite snapshotting being explicitly out of scope for this project — the usual reason to prefer `2M` is performance under snapshot/UFFD workflows, which don't apply here, but `2M` is still chosen anyway.

### Guest RAM sizing
Default guest RAM is **250 MiB** per session — a multiple of 2, i.e. exactly **125 hugetlbfs pages**, no leftover 4K fragment.

### Static pool sizing at host boot
The hugetlbfs pool is **statically sized at host boot** via NixOS's own kernel/sysctl configuration (`boot.kernel.sysctl."vm.nr_hugepages"` or equivalent), not allocated/resized dynamically per launch. It is sized to `250 MiB × max_concurrent_sessions` (see [[10-session-lifecycle-orchestration|concurrency cap]]).

An undersized pool causes **erratic behavior/`SIGBUS`** in a guest rather than a clean failure, so this value must never drift from the configured concurrency cap — the two are set together, by hand, in host config, not derived at runtime. #open-question — this manual-sync requirement is a standing operational risk if the concurrency cap is ever changed without also updating the hugepage pool size.

### Firecracker API wiring
The chosen mode is wired into `FirecrackerVM`'s `/machine-config` PUT (`huge_pages` field) alongside `vcpu_count`/`mem_size_mib` — see [[03-vmm-firecracker|Firecracker machine-config]].

### Interaction with nx_huge_pages
KVM's default iTLB-multihit mitigation splits its own guest-physical→host-physical (EPT/NPT) mappings for executable regions down to 4K, **independent of whether the underlying host memory is hugetlbfs-backed**. Left at its default, this can silently negate the entire point of choosing `2M` here — [[#nx_huge_pages=never]] must be decided alongside this hugepage choice, not treated as an independent checkbox.

## Jailer + systemd (process isolation model)

Every session's `firecracker` process runs under **`jailer`** (bundled in the same nixpkgs `firecracker` derivation — verified by building it: `1.16.1` ships `firecracker` + `jailer` + others in one `bin/`, no extra packaging needed), itself run *as* a [[10-session-lifecycle-orchestration|systemd unit]] (`agentvm-session-<id>-vm.service`) rather than spawned and supervised by a bespoke daemon.

### What jailer alone provides
- chroot via `pivot_root` into `<chroot_base>/<exec_file_name>/<id>/root`;
- always a new mount namespace;
- a `setuid`/`setgid` drop to a **unique uid/gid per concurrent session**.

The uid/gid pair is derived from the same per-session **concurrency slot** that [[05-network-egress-control|mitmproxy's per-session listen port allocation]] uses — one shared slot allocator (sized by `max_concurrent_sessions`) backing both resources, not two independent pools.

### What jailer does *not* provide (systemd supplies it instead)
Without extra flags, jailer does not provide: restart/liveness supervision, stdout/stderr capture, declarative resource limits, or guaranteed cleanup on crash. systemd supplies all of these on top:

#### Delegate=yes and the cgroup subtree
`Delegate=yes` on the VM unit lets systemd own the top of the [[02-host-platform|cgroup v2]] subtree while jailer creates its own nested cgroup underneath for the VM's threads, without the two fighting over the same cgroup node (cgroup v2's "no internal process constraint").

#### Reliable teardown, no orphan process
Killing the unit/scope reliably kills the whole cgroup — this is what avoids the orphan risk jailer's own docs call out: with `--daemonize` but no `--new-pid-ns`, jailer's PID and firecracker's PID differ, so killing jailer alone would not kill firecracker.

#### IPAddressDeny=any
`IPAddressDeny=any` (no `IPAddressAllow=` needed) on the VM unit, since it has no legitimate network need at all — only a local vsock UDS (see [[#Network egress hardening (corrected against generic guidance)|network egress hardening, below]]) — is a second, defense-in-depth backstop alongside the [[05-network-egress-control|egress allowlist]].

#### --cgroup-version 2 must be explicit
jailer's own default is `--cgroup-version 1`; this host mounts [[02-host-platform|cgroup v2]] only. An unspecified `--cgroup-version` would target a hierarchy that doesn't exist on this host, so it **must be passed explicitly**.

## Network egress hardening (corrected against generic guidance)

There is **no TAP/virtio-net device anywhere in this design** (see [[03-vmm-firecracker]]). Generic Firecracker production-hardening advice to rate-limit "the guest's network interface" or block TAP traffic to the cloud IMDS address (`169.254.169.254`) **does not apply and is not implemented**: there is no IP-layer path for the guest to reach that address, or anywhere else, in the first place, since there is no network interface to route through.

### What does apply
`IPAddressDeny=any` on the VM unit (see [[#IPAddressDeny=any]] above) confines the one process that *could* misuse a network capability if compromised, even though it isn't supposed to have one.

### No rate-limiter mechanism for live proxied traffic
Rate-limiting the *live* proxied HTTP traffic (distinct from the transcript-log bandwidth cap described in [[11-session-transcript-receivers|Session Transcript & Stream Receivers]]) has **no Firecracker-API mechanism to lean on** — [[03-vmm-firecracker|the Vsock device]] schema has no rate-limiter field, unlike `drives`/`network-interfaces` (verified against the API spec). So if wanted at all, it has to happen in host software (the vsock↔mitmproxy bridge relay loop, or a mitmproxy addon, per [[05-network-egress-control]]) — **not built in this version**.

## KVM/host tuning

### min_timer_period_us
Lowers host CPU overhead from guest-injected timer interrupts (via the `kvm-pit` kernel thread, see below). Applied via a kernel module parameter, made **explicit in host config** (`llm-host.nix`, `boot.extraModprobeConfig` or equivalent, for `options kvm min_timer_period_us=<N>`) rather than an ad hoc one-off `modprobe` — the exact value needs measuring against this guest kernel's actual timer usage, not assumed.

### kvm-pit cgroup placement
**Not automatic.** Verified against current kernel source: `arch/x86/kvm/i8254.c`'s `kvm_create_pit()` creates its worker via `kthread_run_worker(0, "kvm-pit/%d", pid_nr)`, and `kernel/kthread.c` shows every kthread is actually forked from the global `kthreadd` (PID 2) context — the `%d` in the name is cosmetic (the creating thread's PID, for identification only), not a real parent/cgroup relationship. [[#Delegate=yes and the cgroup subtree|`Delegate=yes`]] cannot reach it, since delegation only covers processes forked from the unit's own tree.

**Mitigation:** an `ExecStartPost=` script on the VM unit locates the `kvm-pit/<tid>` task (scan for a TID under firecracker's own `/proc/<pid>/task/`) and writes its PID into the unit's own `cgroup.procs`.

Two risks, to be confirmed by testing rather than assumed (see [[14-testing-strategy|integration tests]]): #open-question
- PIT creation is **lazy** (first guest PIT access, not process start), so a single-shot poststart check may race it and needs a retry/poll.
- Whether a kernel-thread PID can be freely migrated via `cgroup.procs` the way a normal process's can — no definitive kernel documentation found either way.

### SMT
Per Firecracker's own guidance ("SMT is frequently a precondition for speculation issues... where one tenant could leak information to another"), disabled (`nosmt` on the host kernel cmdline) — this project's concurrent agent sessions are exactly the "tenants sharing a physical host" scenario the guidance warns about.

Designed for the eventual bare-metal deployment target; the current Hyper-V-nested dev environment can't actually enforce this at the physical layer, which is expected and acceptable for dev.

### nx_huge_pages=never
Module parameter, same modprobe-config mechanism as `min_timer_period_us`, chosen over cgroup v2's `favordynmods` remount — needed to actually realize [[#Hugepages|`2M` hugepages]]' benefit for executable guest memory. **Also made explicit in host config**, not applied ad hoc.

### cgroup v2 only
See [[02-host-platform|host platform's cgroup v2 choice]]; jailer's [[#--cgroup-version 2 must be explicit|`--cgroup-version 2`]] and the tunables above are all v2-targeted, no v1 fallback.

## The `doctor` CLI subcommand

Reports host runtime/hardware status independent of any session, **read-only, no side effects**:

- **Hardware vulnerability mitigation status** via `spectre-meltdown-checker` — this is the delivery mechanism for "run it once, record the result in the runbook": `doctor` makes it a repeatable, on-demand check instead of a one-time manual run.
- **Hugepage pool state** (configured vs. actually available, per [[#Hugepages]]).
- **cgroup version in use** (must report v2; a v1 finding here is a host-misconfiguration bug, per [[02-host-platform]]).
- **jailer/systemd unit health** for the hardening measures above, including whether the shared singleton services (per [[10-session-lifecycle-orchestration]]) are up.

## Related

- [[10-session-lifecycle-orchestration]] — owns the systemd units (VM unit, singleton services) that jailer runs under and that `doctor` reports on.
- [[02-host-platform]] — defines the cgroup v2-only mount this section's jailer flag and kernel tunables all target.
- [[03-vmm-firecracker]] — the `/machine-config` API and Vsock device schema referenced by the hugepage wiring and the no-rate-limiter finding.
- [[05-network-egress-control]] — the egress allowlist and per-session slot allocator that `IPAddressDeny=any` and jailer's uid/gid drop complement.
- [[14-testing-strategy]] — where the kvm-pit cgroup-placement race/migration risks are meant to be confirmed rather than assumed.
- [[11-session-transcript-receivers]] — distinguishes the transcript-log bandwidth cap from the (unimplemented) live-traffic rate limiter discussed in [[#Network egress hardening (corrected against generic guidance)|network egress hardening]].
