---
component: index
source: agent-vm-host-spec.md
tags:
- agent-vm-host
- spec-index
---
# Agent VM Host — Specification Index

Isolated LLM code-agent VM host: one Firecracker microVM per Claude Code session, no guest network device, all egress mediated by the host. Split from the [[agent-vm-host-spec|monolithic spec]] into 15 component notes for low-token, targeted retrieval — search or open a single component instead of loading the whole spec. Each note is self-contained, uses fine-grained headings, and links to the components it depends on.

## Platform & Boot

- [[01-purpose-and-scope|Purpose & Scope]] — threat model, usage model, playback-only transcript requirement.
- [[02-host-platform|Host Platform]] — NixOS, disko/btrfs, nested virt, cgroup v2-only.
- [[03-vmm-firecracker|VMM: Firecracker]] — minimal device model, no virtio-net, vsock as the only channel.
- [[04-guest-pid1-init|Guest pid1-init]] — Rust/musl pid1, no shell, 7-step startup sequence.
- [[09-guest-rootfs|Guest Rootfs (Device 1)]] — self-contained Nix closure, whitelisted tools, mitmproxy CA baked in.

## Network & Data Egress

- [[05-network-egress-control|Network Egress Control]] — vsock↔TCP shim, absent-DNS-as-canary, mitmproxy TLS MITM, allowlist, credential injection, per-session listen ports.
- [[06-workspace-and-repo-delivery|Workspace & Repository Delivery]] — host-local git mirror, read-only git-protocol access, three-block-device layout, result extraction.

## Monitoring & In-Guest Posture

- [[07-bpf-monitoring|BPF Monitoring]] — libbpf/CO-RE exec/network/file/DNS event capture, log-only receiver policy.
- [[08-in-guest-hardening|In-Guest Hardening]] — capability dropping only; why seccomp/nsjail are deliberately skipped.

## Orchestration & Lifecycle

- [[10-session-lifecycle-orchestration|Session Lifecycle & Host Orchestration]] — no central daemon, CLI steers systemd unit graphs directly.
- [[11-session-transcript-receivers|Session Transcript & Stream Receivers]] — terminal/proxy/bpf `.jsonl` streams, 100 MB caps, inactivity watchdog.
- [[12-production-hardening|Production Hardening & Resource Control]] — hugepages, jailer+systemd, KVM/host tuning, `doctor` subcommand.

## Reliability & Verification

- [[13-error-handling-failure-modes|Error Handling & Failure Modes]] — launch atomicity, stop cascades, fatal vs. best-effort failures.
- [[14-testing-strategy|Testing Strategy]] — test markers, unit/integration test layering.
- [[15-decisions-log|Decisions Log & Remaining Open Items]] — 17 resolved decisions, 4 still-open items, spanning nearly every component above.

## Querying this collection

- By tag: `#open-question` (unresolved risks/decisions scattered across network egress, workspace delivery, orchestration, production hardening, error handling, testing, and the decisions log), `#decision` (resolved items, mostly in the decisions log), `#implementation-note` (verify-before-build callouts).
- By component: frontmatter `spec-section` holds the original spec section number the note came from; `component` holds its slug.
- Semantically: `search_semantic` over this folder surfaces the right component note directly — no need to load the monolithic spec.
