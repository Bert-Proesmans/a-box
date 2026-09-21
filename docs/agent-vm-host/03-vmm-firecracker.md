---
component: vmm-firecracker
source: agent-vm-host-spec.md
spec-section: §3
tags:
- agent-vm-host
- spec-component
---
# VMM: Firecracker

## Device Model — Deliberately Minimal

Firecracker's device model only offers: virtio-block, virtio-net, virtio-vsock, virtio-balloon/rng/pmem, and one legacy UART serial console. Notably absent: no virtio-console, no PCI, no shared-memory/virtiofs. This minimal device model is not incidental — it directly shapes the rest of this subsystem's design, most importantly the network egress story.

## No virtio-net — No IP Stack Path Out

**No virtio-net device is attached to any guest, at all.** This means there is no IP stack path out of the guest *by construction* — not enforced by a firewall rule that could be misconfigured or bypassed, but structurally absent at the device-model level. See [[05-network-egress-control|Network Egress Control]] for how the guest still reaches the network (via vsock, not IP), and note in particular [[05-network-egress-control|the DNS resolution discussion]]: this is also why the guest's resolver has no interface to send a query over even if it were configured.

## virtio-vsock — The Only Interactive/Control Channel

vsock is the sole channel in or out of the guest, carrying, over separate vsock ports per session:

### Interactive stdin/stdout
Replaces the need for a serial console as the agent's terminal.

### HTTP(S) Proxy Traffic
Guest → host-local proxy. See [[05-network-egress-control|guest-side vsock↔TCP shim]] and [[10-session-lifecycle-orchestration|the mitmproxy singleton service]] on the receiving end.

### BPF Event Export
Guest → host receiver. See [[07-bpf-monitoring|BPF Monitoring]] for what's captured and [[11-session-transcript-receivers|Session Transcript & Stream Receivers]] for how the exported events are persisted.

## Legacy UART Serial Console — Boot Log Capture Only

The legacy UART serial console is retained **only** for early kernel boot log capture, for debugging boot failures. It is a single unmultiplexed byte stream and is **not** used for anything interactive — that role belongs entirely to vsock. See [[13-error-handling-failure-modes|Error Handling & Failure Modes]] for how boot failures surfaced here are handled.

## Guest Boot — Custom Kernel + Custom pid1

Guests boot a custom kernel directly into a custom pid1 — no traditional init system, no initrd handoff. See [[04-guest-pid1-init|Guest pid1-init]] for the full startup sequence this pid1 binary runs.

## Three virtio-block Devices Per Guest

Each guest gets three virtio-block devices, used to assemble the guest's workspace via overlayfs. See [[06-workspace-and-repo-delivery|Workspace & Repository Delivery]] for what each of the three devices holds and how they're layered, and [[09-guest-rootfs|Guest Rootfs]] for the specific rootfs device (Device 1).

## Related

- [[04-guest-pid1-init]] — the pid1 binary that runs inside the guest this VMM boots
- [[05-network-egress-control]] — the entire proxy design follows directly from "no virtio-net"
- [[06-workspace-and-repo-delivery]] — consumes the three virtio-block devices described here
- [[07-bpf-monitoring]] — its event export rides the third vsock channel described here
- [[09-guest-rootfs]] — Device 1 of the three virtio-block devices
