---
component: production-hardening-todo
source: 12-production-hardening-plan.md
tags:
- agent-vm-host
- spec-todo
---
# Production Hardening & Resource Control — Todo

A step's top-level box is a summary checkbox: check it only once every nested box under it is checked.

## Chunk 1 — Hugepages & `nx_huge_pages`

- [ ] Step 1.1 — [[12-production-hardening-plan#Step 1.1 — Hugepages: static pool sizing at host boot|Hugepages: static pool sizing at host boot]]
  - [ ] Add `boot.kernel.sysctl."vm.nr_hugepages"` (or equivalent) fixed to `(250 MiB / 2 MiB) × max_concurrent_sessions` 2M-pages, with `max_concurrent_sessions` entered directly in Nix config
  - [ ] Add a prominent comment above the setting: must be kept in sync by hand with the CLI config's `max_concurrent_sessions`; a mismatch causes SIGBUS-class guest failures
  - [ ] Add a boot-time verification check (pattern from 02-host-platform-plan's Steps 2.2/3.2) confirming the configured pool size matches kernel-reported `HugePages_Total`, failing loudly on mismatch
  - [ ] Verify: boot the host, confirm the check reports the pool healthy with `HugePages_Total` matching the computed value
  - [ ] Verify: negative path — temporarily mismatched pool size in a test configuration, confirm the check fails loudly with a clear message
- [ ] Step 1.2 — [[12-production-hardening-plan#Step 1.2 — `nx_huge_pages=never` module parameter|`nx_huge_pages=never` module parameter]]
  - [ ] Add `options kvm nx_huge_pages=never` to `boot.extraModprobeConfig`, with a comment tying it to Step 1.1's hugepage pool
  - [ ] Extend Step 1.1's boot-time verification check in place (not a second check) to confirm `/sys/module/kvm/parameters/nx_huge_pages` reports `never`
  - [ ] Verify: boot the host, confirm the extended check reports both the hugepage pool size and `nx_huge_pages=never` healthy together
  - [ ] Verify: negative path — temporarily omit the modprobe config, confirm the check fails specifically on the `nx_huge_pages` condition while the pool-size condition still reports separately and correctly
- [ ] Step 1.3 — [[12-production-hardening-plan#Step 1.3 — Firecracker machine-config `huge_pages` wiring|Firecracker machine-config `huge_pages` wiring]]
  - [ ] Extend the VMM launcher's machine-config PUT to include a `huge_pages` field set to `2M`, alongside `vcpu_count`/`mem_size_mib`, sourced from 10's config knobs
  - [ ] Add a launcher-level guard: requested `mem_size_mib` checked against the pool's known total configured size, refusing the launch with a clear error if the pool looks exhausted
  - [ ] Verify: launch a microVM with `huge_pages` set to `2M`, confirm via the guest's `/proc/meminfo` (or equivalent) that guest memory is actually hugetlbfs-backed
  - [ ] Verify (`needs_kvm` hugepage boot-time benchmark): launch the same guest config twice (`huge_pages=2M` vs `None`), record and compare boot time between the two

## Chunk 2 — Jailer + systemd process isolation

- [ ] Step 2.1 — [[12-production-hardening-plan#Step 2.1 — Jailer invocation argv (pure function, unit-tested)|Jailer invocation argv (pure function, unit-tested)]]
  - [ ] Build a pure, side-effect-free function taking session id, chroot base dir, `firecracker` binary path, guest kernel/disk-image paths, per-VM vsock UDS path, and slot index
  - [ ] Return the complete jailer argv: `--id`, `--exec-file`, `--chroot-base-dir`, `--uid`/`--gid` (derived from the slot index via a fixed, documented base offset), `--cgroup-version 2`, no `--daemonize`
  - [ ] Function performs no I/O of its own (no process spawning, no filesystem writes)
  - [ ] Verify (unit tests, no VM/root needed): normal case produces the expected full argv for a given slot index
  - [ ] Verify: two different slot indices produce two distinct, non-overlapping uid/gid pairs
  - [ ] Verify: `--cgroup-version 2` and no `--daemonize` always present regardless of inputs
  - [ ] Verify: a rejected/erroring case for an out-of-range slot index
- [ ] Step 2.2 — [[12-production-hardening-plan#Step 2.2 — Wire jailer argv into the VM unit: `Delegate=yes`, `--cgroup-version 2`, `IPAddressDeny=any`|Wire jailer argv into the VM unit: `Delegate=yes`, `--cgroup-version 2`, `IPAddressDeny=any`]]
  - [ ] Replace `agentvm-session-vm@.service`'s placeholder `ExecStart=` with a real one: reads slot index/params from `EnvironmentFile=`, calls Step 2.1's argv function, execs `jailer` (which execs `firecracker`)
  - [ ] Add `Delegate=yes` and `IPAddressDeny=any` as unit directives without removing/restructuring existing directives (`RuntimeMaxSec=`, `Requires=`/`After=`, `ExecStartPre=`/`ExecStopPost=`, `Restart=no`)
  - [ ] Add no resource-limit directive or flag of any kind (open, unresolved decision — flag, don't guess)
  - [ ] Verify: start a real session's target, confirm the VM unit execs a real jailer/firecracker pair (not the sleep placeholder) chrooted under a session-specific uid/gid matching the recorded slot index
  - [ ] Verify (`needs_kvm`+`needs_root` cgroup-delegation test): confirm `Delegate=yes` and jailer's nested `--cgroup-version 2` cgroup coexist without one clobbering the other, by inspecting the resulting cgroup tree
  - [ ] Verify: confirm `IPAddressDeny=any` is in effect (the jailed process cannot open an IP socket of any kind)

## Chunk 3 — KVM/host tuning

- [ ] Step 3.1 — [[12-production-hardening-plan#Step 3.1 — `min_timer_period_us` and `nosmt` host kernel tuning|`min_timer_period_us` and `nosmt` host kernel tuning]]
  - [ ] Add `options kvm min_timer_period_us=<N>` (a documented placeholder value, clearly labeled as needing real measurement) to `boot.extraModprobeConfig`, alongside the `nx_huge_pages` entry
  - [ ] Add `nosmt` to the host kernel's boot command line
  - [ ] Add a comment at the `nosmt` setting noting the current nested-virt dev environment cannot enforce this at the physical layer
  - [ ] Verify: boot the host, confirm `/sys/module/kvm/parameters/min_timer_period_us` reports the configured value
  - [ ] Verify: confirm `/proc/cmdline` contains `nosmt`
  - [ ] Verify: in the dev environment, confirm (and record as an expected, documented limitation) whether SMT siblings are still visible in `/sys/devices/system/cpu/cpu*/topology/thread_siblings_list` despite `nosmt`
- [ ] Step 3.2 — [[12-production-hardening-plan#Step 3.2 — `kvm-pit` cgroup placement `ExecStartPost=` script|`kvm-pit` cgroup placement `ExecStartPost=` script]]
  - [ ] Build the `ExecStartPost=` script: given the firecracker PID, poll `/proc/<pid>/task/` for a task whose `comm` matches `kvm-pit`, with a bounded retry/poll loop (not single-shot)
  - [ ] On finding it, write that TID into the delegated cgroup's `cgroup.procs`
  - [ ] Log three distinguishable outcomes: found-and-moved, not-found-within-poll-window, move-failed
  - [ ] Add as a second `ExecStartPost=` directive on `agentvm-session-vm@.service`, alongside (not replacing) the existing slot-release `ExecStartPost=`
  - [ ] Verify (`needs_kvm`+`needs_root` `kvm-pit` placement test): boot a real VM through the full unit graph, confirm the script finds and moves the `kvm-pit` thread, confirm via `cpu.stat`/`systemd-cgtop` its CPU time attributes to the VM's delegated cgroup
  - [ ] Verify: induce guest PIT access at varying delays after VM start, confirm the poll/retry loop still finds the thread even when creation isn't immediate; report the observed timing margin
  - [ ] Verify: confirm the existing slot-release `ExecStartPost=` from 10's Step 2.4 still fires correctly alongside this new one

## Chunk 4 — The `doctor` subcommand

- [ ] Step 4.1 — [[12-production-hardening-plan#Step 4.1 — `doctor`: hardware-mitigation, hugepage, and cgroup-version reporting|`doctor`: hardware-mitigation, hugepage, and cgroup-version reporting]]
  - [ ] Extend the `doctor` CLI subcommand (currently a no-op stub) to report, in a stable structured format: `spectre-meltdown-checker` output (subprocess, verbatim plus a pass/fail summary line)
  - [ ] Report hugepage pool configured-vs-actual state (reading the same `/proc/meminfo` fact Step 1.1's check already reads, not reimplemented)
  - [ ] Report cgroup version in use (reading `/sys/fs/cgroup/cgroup.controllers` presence, matching 02's Step 3.2 detection; v1 = error-level finding, not a warning)
  - [ ] Report the swap/KSM posture guard's last-known pass/fail state from 02-host-platform-plan's Step 4.1
  - [ ] Do not re-implement any underlying check; do not touch any session unit at this step
  - [ ] Verify: unit-test output formatting against fake `spectre-meltdown-checker`/`systemctl`/hugepage-pool outputs covering a fully-healthy host, a v1-cgroup-detected host (reported as error), an undersized-hugepage-pool host, and a swap/KSM-guard-failed host — each a distinct, identifiable report line
  - [ ] Verify: one `needs_root` smoke test against the real host tools produces a real report without erroring
  - [ ] Verify: confirm no session-scoped systemd unit is queried or touched by this step
- [ ] Step 4.2 — [[12-production-hardening-plan#Step 4.2 — `doctor`: jailer/systemd unit-health reporting|`doctor`: jailer/systemd unit-health reporting]]
  - [ ] Extend `doctor` to report whether `agentvm-git-service.service` and `agentvm-mitmproxy.service` are active, reusing the `systemctl` query pattern from 10's `list` command
  - [ ] Report whether `Delegate=yes` is actually in effect for any currently-running session's VM unit (read-only `systemctl show` query, not a live cgroup-tree walk)
  - [ ] For any currently-running session, report whether its `kvm-pit` `ExecStartPost=` script (Step 3.2) logged success or failure in the journal
  - [ ] If no sessions are running, report that plainly rather than erroring
  - [ ] Verify: unit-test output formatting against fake `systemctl`/journal outputs covering both singletons up, one singleton down, no sessions running, and a running session whose `kvm-pit` script logged failure
  - [ ] Verify: one `needs_root` smoke test with a real session launched (via 10's `launch`), confirm `doctor` correctly reports that session's `Delegate=yes` state and `kvm-pit` placement outcome without stopping or otherwise touching its units
