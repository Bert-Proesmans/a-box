---
component: host-platform
source: agent-vm-host-spec.md
spec-section: §2
tags:
- agent-vm-host
- spec-component
---
# Host Platform

## Host OS — NixOS

The host OS is NixOS, configured in `llm-host.nix` in this repo.

## Storage — disko-managed btrfs

Already configured with disko-managed btrfs storage using `@nix` and `@persistent` subvolumes, plus a zram root that is wiped every boot.

## Nested Virtualization

`boot.kernelModules = [ "kvm-amd" "kvm-intel" ]` is set for **nested virtualization**. This matters because this host itself appears to run as a guest (`virtualisation.hypervGuest.enable = true`) — so nested virt must remain enabled at that *outer* hypervisor layer for `/dev/kvm` to be usable here at all. If the outer layer ever disables nested virt, this entire subsystem loses `/dev/kvm` access and [[03-vmm-firecracker|Firecracker]] cannot launch any guest.

## Why No New Dedup/Snapshot Filesystem Is Required

No new dedup/snapshot filesystem (ZFS, or btrfs-CoW specifically for this purpose) is required for this subsystem. Image reuse across sessions is instead achieved via the mechanism described in [[09-guest-rootfs|the guest rootfs image-reuse mechanism]] — not via filesystem-level snapshotting. #implementation-note The existing btrfs pool continues to be used for general storage as before; this subsystem doesn't need to introduce a new storage technology.

## cgroup v2 Only — Never v1

This host mounts the unified cgroup v2 hierarchy **exclusively** — verified by `/sys/fs/cgroup/cgroup.controllers` being present, with no v1 hierarchy mounted anywhere. This is a hard constraint, not a preference:

- **Every** cgroup-touching piece of this subsystem must target v2, with **no v1 fallback path** to be built or supported. That includes:
  - jailer's `--cgroup-version` flag ([[03-vmm-firecracker|Firecracker's]] launcher)
  - systemd unit resource directives
  - the `kvm-pit` poststart placement
  - [[12-production-hardening|its resource-control mechanisms]]

## Related

- [[09-guest-rootfs]] — the actual mechanism used for image reuse, in place of a dedup/snapshot filesystem
- [[12-production-hardening]] — depends on this host's cgroup v2-only guarantee for every resource-control directive
- [[03-vmm-firecracker]] — jailer's `--cgroup-version` flag and `/dev/kvm` access both depend on platform facts established here
- [[10-session-lifecycle-orchestration]] — host orchestration runs on top of this platform's storage and virtualization guarantees
