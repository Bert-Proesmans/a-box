---
component: in-guest-hardening
source: agent-vm-host-spec.md
spec-section: §8
tags:
- agent-vm-host
- spec-component
---

# In-Guest Hardening (Deliberately Minimal)

Why this design applies almost no in-guest process isolation beyond the VM boundary itself, and why that's a deliberate choice rather than an oversight.

## What is applied: capability dropping

- Only **capability dropping** is applied beyond [[03-vmm-firecracker|the microVM boundary]] itself.
- Mechanism: setuid to an unprivileged user and strip all Linux capabilities before `exec`-ing the agent (step 6 of the [[04-guest-pid1-init|pid1-init]] setup sequence).

## What is explicitly not done, by design

- **No seccomp filtering.**
- **No read-only rootfs enforcement.**
- **No nsjail-style namespace isolation.**

## Rationale

- nsjail-class tooling exists to isolate a process *from other processes/tenants sharing a kernel* — a problem that **doesn't exist here**, since each guest kernel runs exactly one workload (the agent and its subprocesses) with no neighbors.
- The microVM boundary is the real isolation boundary; capability dropping is cheap defense-in-depth with no functional downside.
- seccomp's cost — building and maintaining an allowlist tolerant of arbitrary shell commands (compilers, package managers, etc.) — wasn't judged worth it for the value added on top of the VM boundary + BPF visibility.

## Related

- [[03-vmm-firecracker|VMM: Firecracker]] — the microVM boundary that this note explicitly relies on instead of duplicating process-level isolation.
- [[04-guest-pid1-init|Guest pid1-init]] — performs the capability-dropping step (step 6) right before exec-ing the agent.
- [[07-bpf-monitoring|BPF Monitoring]] — the visibility layer this design leans on in place of seccomp enforcement.
- [[09-guest-rootfs|Guest Rootfs (Device 1)]] — the image whose contents (whitelisted CLI tools) shape why an arbitrary-shell-command seccomp allowlist would be costly to maintain.
