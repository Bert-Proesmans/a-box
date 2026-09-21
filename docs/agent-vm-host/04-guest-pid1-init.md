---
component: guest-pid1-init
source: agent-vm-host-spec.md
spec-section: §4
tags:
- agent-vm-host
- spec-component
---
# Guest pid1-init

## Overview

A custom, statically-linked (musl target) **Rust** binary, replacing traditional init entirely. **No shell interpreter is present** as pid1 or anywhere in the boot path — this is a deliberate hardening property, not just an implementation choice; see [[08-in-guest-hardening|In-Guest Hardening]] for the broader rationale of keeping the in-guest attack/mistake surface minimal.

## Startup Sequence

### Mount Pseudo-Filesystems
Mount required pseudo-filesystems: proc, sysfs, devtmpfs, and a tmpfs for `/tmp`.

### Mount virtio-block Devices & Assemble Workspace
Mount the three virtio-block devices ([[03-vmm-firecracker|provided by Firecracker]]) and assemble the workspace via overlayfs. See [[06-workspace-and-repo-delivery|Workspace & Repository Delivery]] for the full layering scheme.

### Establish vsock Connections
Establish the vsock connections: stdin/stdout, proxy shim, BPF exporter — the three channels described in [[03-vmm-firecracker|Firecracker's vsock section]].

### Load & Attach eBPF Programs
Load and attach the eBPF programs by invoking the libbpf-based loader as a setup step. See [[07-bpf-monitoring|BPF Monitoring]] for what these programs capture.

### Configure Agent Environment
Configure the agent's environment:
- `HTTP_PROXY` / `HTTPS_PROXY` pointing at the local vsock-backed proxy shim (see [[05-network-egress-control|the guest-side vsock↔TCP shim]])
- A placeholder API credential (the real key is injected host-side; see [[05-network-egress-control|credential injection]])
- Working directory

### Drop Privileges
`setuid` to an unprivileged user and strip all Linux capabilities. This is deliberately the *extent* of in-guest hardening — see [[08-in-guest-hardening|In-Guest Hardening]] for why more elaborate in-guest measures (seccomp profiles, namespaces, etc.) are considered unnecessary given the isolation already provided by the VM boundary and the absence of virtio-net.

### exec into the Agent
`exec` into the Claude Code agent — pid1 does not fork/supervise, it replaces itself with the agent process directly.

## Why No Shell Interpreter

The absence of a shell interpreter anywhere in the boot path is a structural hardening choice: it removes an entire class of injection/misuse primitives (no `sh -c`, no shell expansion, no ad-hoc scripting surface) that a traditional init system's boot scripts would otherwise expose. Combined with the privilege-drop-then-exec model, the only process capable of arbitrary behavior in the guest is the agent itself, running unprivileged.

## Related

- [[03-vmm-firecracker]] — supplies the block devices and vsock channels this init sequence consumes
- [[06-workspace-and-repo-delivery]] — the overlayfs assembly performed in step 2
- [[05-network-egress-control]] — the proxy shim and `HTTP_PROXY`/`HTTPS_PROXY` configured in step 5
- [[07-bpf-monitoring]] — the eBPF loader invoked in step 4
- [[08-in-guest-hardening]] — explains why step 6's privilege drop is sufficient rather than one layer among many
