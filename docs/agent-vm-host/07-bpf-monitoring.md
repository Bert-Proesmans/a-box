---
component: bpf-monitoring
source: agent-vm-host-spec.md
spec-section: §7
tags:
- agent-vm-host
- spec-component
---

# BPF Monitoring

Independent, in-guest audit trail of process, network, file, and DNS activity, exported to the host as a log — not an enforcement mechanism.

## Guest side

### Toolchain choice: C + libbpf + CO-RE

- Written in **C using libbpf with CO-RE** (Compile Once – Run Everywhere), not Rust/Aya or Go/cilium-ebpf.
- Chosen specifically because it has the **fewest moving toolchain parts to reproduce inside a Nix build**: `clang`, `libbpf`, `bpftool` are all mainstream, well-established nixpkgs packages/derivations.
- Rejected alternatives and why: Aya needs a pinned nightly Rust toolchain plus `bpf-linker`; cilium/ebpf needs an extra `bpf2go` codegen layer. Both add reproducibility risk inside a Nix build compared to the mainstream C/libbpf/CO-RE path.

### Load sequencing

- The compiled eBPF program + small libbpf-based loader binary is invoked by the Rust [[04-guest-pid1-init|pid1-init]] as one of its setup steps (step 4 of its sequence).

### Captured events

- **Process exec** (`execve` + args) — every command the agent/shell runs.
- **Network syscalls** (`connect`/`sendto`) — belt-and-suspenders, since no virtio-net exists in this design; catches any attempt to open a raw socket or otherwise bypass the intended vsock/proxy path.
- **File opens**, **distinguishing read vs. write mode**.
- **DNS attempts** — also belt-and-suspenders, given there's no working IP stack for DNS to resolve anything over.

### Export

- Events are exported to the host over the dedicated BPF vsock port as **newline-delimited JSON**.

## Host side

### Receiver design

- The receiver is intentionally **simple: it appends incoming JSONL events directly to a per-session log file.**
- **No database, no real-time alerting pipeline** in this version.
- It is one of the three per-session [[11-session-transcript-receivers|transcript receivers]] (the `bpf.jsonl` receiver), including that section's growth-bounding policy.
- Runs as its own per-session systemd unit (`agentvm-session-<id>-recv-bpf.service`), `PartOf=` the session's VM unit — see [[10-session-lifecycle-orchestration|Session Lifecycle & Host Orchestration]].

### Violation response policy

- **Log + alert only, no automatic action.**
- Flagged events are recorded and surfaced for review, but a session is **never auto-killed** on a BPF-observed event in this version.
- Rationale: this avoids false-positive kills before "normal" agent behavior is well understood.
- #implementation-note Tiered/hard-kill policies can be layered in later once that behavioral baseline exists.

## Related

- [[04-guest-pid1-init|Guest pid1-init]] — loads the compiled BPF program and loader as one of its boot setup steps.
- [[11-session-transcript-receivers|Session Transcript & Stream Receivers]] — the `bpf.jsonl` receiver and its growth-bounding policy live here.
- [[05-network-egress-control|Network Egress Control]] — BPF's network-syscall capture is redundant-by-design belt-and-suspenders on top of the "no virtio-net" boundary this note enforces.
- [[10-session-lifecycle-orchestration|Session Lifecycle & Host Orchestration]] — runs the BPF receiver as a per-session systemd unit.
- [[13-error-handling-failure-modes|Error Handling & Failure Modes]] — defines what (if anything) happens when violations are flagged, beyond logging.
