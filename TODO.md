# Agent VM Host — Spec Rollup

Chunk-level progress across the 13 split-spec plans under `docs/agent-vm-host/`. Drill into a chunk's steps via its link. Supersedes the old monolithic-plan tracker, now at [[archive/todo]].

## Known gaps (need a decision, not just more work)

- **Echo stub isn't byte-exact.** `03-vmm-firecracker-todo` Step 4 and `04-guest-pid1-init-todo` Step 2.1 both require their placeholder echo to return bytes unchanged. The existing stub agent (`agent-vm/guest/echo-agent`) prefixes every line with `echo: ` instead. Either accept the prefix as a deliberate deviation, or make the stub byte-exact before checking those steps off.
- **Console log truncates on relaunch.** `FirecrackerVM.start()` (`agent-vm/host/src/agentvm/firecracker.py`) opens `console_log` with `.open("wb")`, which truncates any prior content. `03-vmm-firecracker-todo` Step 6 requires a failed/relaunched boot's log to persist — currently it doesn't, and there's no negative-path test catching this.

## [[02-host-platform-todo]]

- [ ] [[02-host-platform-todo#Chunk 1 — Base Host OS & Storage Foundation]]
- [ ] [[02-host-platform-todo#Chunk 2 — Nested Virtualization & KVM Access]]
- [ ] [[02-host-platform-todo#Chunk 3 — Exclusive cgroup v2 Enforcement]]
- [ ] [[02-host-platform-todo#Chunk 4 — Host Memory Posture for VM Density]]

## [[03-vmm-firecracker-todo]]

- [x] [[03-vmm-firecracker-todo#Chunk 1 — Guest kernel & first boot proof]]
- [ ] [[03-vmm-firecracker-todo#Chunk 2 — Full workspace block-device model]]
- [ ] [[03-vmm-firecracker-todo#Chunk 3 — vsock control-channel transport]]
- [ ] [[03-vmm-firecracker-todo#Chunk 4 — Device-model completeness & console-policy guarantees]]

## [[04-guest-pid1-init-todo]]

- [ ] [[04-guest-pid1-init-todo#Chunk 1 — Boot-time Filesystem & Workspace Assembly]]
- [ ] [[04-guest-pid1-init-todo#Chunk 2 — Guest vsock Channels]]
- [ ] [[04-guest-pid1-init-todo#Chunk 3 — eBPF Load While Root]]
- [ ] [[04-guest-pid1-init-todo#Chunk 4 — Environment, Privilege Drop, and Exec]]

## [[05-network-egress-control-todo]]

- [ ] [[05-network-egress-control-todo#Chunk 1 — Guest-side transport foundation]]
- [ ] [[05-network-egress-control-todo#Chunk 2 — Host-side mitmproxy core & end-to-end reachability]]
- [ ] [[05-network-egress-control-todo#Chunk 3 — Allowlist enforcement]]
- [ ] [[05-network-egress-control-todo#Chunk 4 — Credential injection]]
- [ ] [[05-network-egress-control-todo#Chunk 5 — Per-session concurrency-slot isolation]]

## [[06-workspace-and-repo-delivery-todo]]

- [ ] [[06-workspace-and-repo-delivery-todo#Chunk 1 — Host-local git mirror maintenance]]
- [ ] [[06-workspace-and-repo-delivery-todo#Chunk 2 — Git-http-backend service]]
- [ ] [[06-workspace-and-repo-delivery-todo#Chunk 3 — Per-guest workspace block-device content]]
- [ ] [[06-workspace-and-repo-delivery-todo#Chunk 4 — Result extraction & review]]

## [[07-bpf-monitoring-todo]]

- [ ] [[07-bpf-monitoring-todo#Chunk 1 — Guest eBPF Toolchain & Process/Network Capture]]
- [ ] [[07-bpf-monitoring-todo#Chunk 2 — File & DNS Capture, Unified Export Schema]]
- [ ] [[07-bpf-monitoring-todo#Chunk 3 — Continuous vsock Export & pid1-init Integration]]
- [ ] [[07-bpf-monitoring-todo#Chunk 4 — Host-Side `bpf.jsonl` Receiver]]

## [[08-in-guest-hardening-todo]]

- [ ] [[08-in-guest-hardening-todo#Chunk 1 — Independent Hardening Verification]]

## [[09-guest-rootfs-todo]]

- [ ] [[09-guest-rootfs-todo#Chunk 1 — Self-Contained Nix Closure]]
- [ ] [[09-guest-rootfs-todo#Chunk 2 — Bootable Init Wiring]]
- [ ] [[09-guest-rootfs-todo#Chunk 3 — Trust-Store Provisioning]]
- [ ] [[09-guest-rootfs-todo#Chunk 4 — Reuse & Rebuild Policy]]

## [[10-session-lifecycle-orchestration-todo]]

- [ ] [[10-session-lifecycle-orchestration-todo#Chunk 1 — Host-Wide Configuration]]
- [ ] [[10-session-lifecycle-orchestration-todo#Chunk 2 — Per-Session Systemd Unit Graph]]
- [ ] [[10-session-lifecycle-orchestration-todo#Chunk 3 — The CLI]]
- [ ] [[10-session-lifecycle-orchestration-todo#Chunk 4 — Concurrency-Cap Proof]]

## [[11-session-transcript-receivers-todo]]

- [ ] [[11-session-transcript-receivers-todo#Chunk 1 — `recv-bpf` real wiring & cap-cascade proof]]
- [ ] [[11-session-transcript-receivers-todo#Chunk 2 — Terminal-transcript tap (`session_manager.py`)]]
- [ ] [[11-session-transcript-receivers-todo#Chunk 3 — `proxy.jsonl` transcript addon]]
- [ ] [[11-session-transcript-receivers-todo#Chunk 4 — Inactivity watchdog]]

## [[12-production-hardening-todo]]

- [ ] [[12-production-hardening-todo#Chunk 1 — Hugepages & `nx_huge_pages`]]
- [ ] [[12-production-hardening-todo#Chunk 2 — Jailer + systemd process isolation]]
- [ ] [[12-production-hardening-todo#Chunk 3 — KVM/host tuning]]
- [ ] [[12-production-hardening-todo#Chunk 4 — The `doctor` subcommand]]

## [[13-error-handling-failure-modes-todo]]

- [ ] [[13-error-handling-failure-modes-todo#Chunk 1 — Launch-time failure behavior: atomicity, surfacing, and fatal-vs-best-effort classification]]
- [ ] [[13-error-handling-failure-modes-todo#Chunk 2 — Stop-cascade convergence]]

## [[14-testing-strategy-todo]]

- [ ] [[14-testing-strategy-todo#Chunk 1 — Shared pytest test-marker layer]]
