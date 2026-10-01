---
component: purpose-and-scope
source: agent-vm-host-spec.md
spec-section: §1
tags:
- agent-vm-host
- spec-component
---
# Purpose & Scope

## System Model

A single physical/virtual host runs short-lived, RAM-resident KVM microVMs. Each microVM boots a minimal guest that runs **exactly one Claude Code agent session** against **one task on one repository**. The host is the sole mediator between each guest and the outside world — every network path, every credential, every piece of the workspace passes through host-controlled mechanisms rather than being reachable directly by the guest. See [[03-vmm-firecracker|Firecracker's device model]] for how "sole mediator" is enforced at the hardware-interface level (no virtio-net at all), and [[05-network-egress-control|Network Egress Control]] for how the mediation is enforced at the traffic level.

## Usage Model

- **Single developer, personal use.**
- **No multi-tenant isolation requirements** beyond containing the agent itself — this is not a shared-hosting or multi-customer security boundary. The isolation goal is "keep one agent session from doing something the operator didn't intend," not "keep tenant A from seeing tenant B's data."

## Threats Defended Against

### Data Exfiltration
Prompt injection or bad agent judgment sending secrets or code to an unintended destination. Defended against primarily via [[05-network-egress-control|the allowlist-only egress proxy]] (nothing reaches the network except explicitly permitted destinations) and the fact that guests never hold real credentials (see [[05-network-egress-control|credential injection]]).

### Arbitrary Code Execution Damage
Damage the agent performs by executing arbitrary code as part of its normal operation (this is expected/intended behavior of a code agent, not a bug to prevent — the threat is *blast radius*, not the execution itself). Contained by microVM isolation ([[03-vmm-firecracker|Firecracker]]), the minimal in-guest privilege surface ([[04-guest-pid1-init|pid1-init's privilege drop]], [[08-in-guest-hardening|in-guest hardening]]), and the ephemeral/RAM-resident nature of each session.

### Runaway or Unexpected Resource/Network Usage
An unsupervised agent consuming unbounded CPU/memory/network. Defended against via [[12-production-hardening|resource control (cgroups, hugepage pool, per-session concurrency slots)]] and the egress allowlist limiting what network usage is even possible.

## Reproducibility Requirement

Sessions are **not** deterministically re-executable — this is an explicit non-goal. The system instead produces a **playback-only transcript**:

- Terminal I/O
- Proxy traffic
- BPF events

...sufficient for **human review/audit after the fact**. This is deliberately *not* byte-for-byte replay against recorded network responses (no VCR-style response mocking, no deterministic re-run of the agent against captured state). The transcript is for a human to read what happened, not for the system to reproduce what happened. See [[11-session-transcript-receivers|Session Transcript & Stream Receivers]] for how the three transcript streams (terminal I/O, `proxy.jsonl`, BPF events) are captured and stored, and [[07-bpf-monitoring|BPF Monitoring]] for what the BPF event stream specifically captures.

## Related

- [[05-network-egress-control]] — primary mechanism defending against data exfiltration; embodies "host is sole mediator"
- [[03-vmm-firecracker]] — the isolation boundary containing arbitrary-code-execution damage
- [[11-session-transcript-receivers]] — implements the playback-only transcript requirement
- [[07-bpf-monitoring]] — one of the three transcript streams; also a threat-detection signal in its own right
- [[12-production-hardening]] — defends against the runaway resource/network usage threat
