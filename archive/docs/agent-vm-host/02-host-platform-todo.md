---
component: "host-platform-todo"
source: "02-host-platform-plan.md"
tags: ["agent-vm-host", "spec-todo"]
---
# Host Platform — Build Checklist

A step's top-level box is a summary — check it only once every nested box under it is checked.

## Chunk 1 — Base Host OS & Storage Foundation
- [x] Step 1.1 — Base host system definition — [[02-host-platform-plan#Step 1.1 — Base host system definition]]
  - [x] Define hostname, boot loader, minimal system services/packages, network reachability, admin login path
  - [x] Configuration builds and boots into a working, reachable machine on its own, with no virtualization/cgroup/storage-layout specifics yet
  - [x] Structured so later steps can extend it (filesystem layout, kernel modules, service units) without restructuring
- [x] Step 1.2 — Storage layout: persistent subvolumes + ephemeral root — [[02-host-platform-plan#Step 1.2 — Storage layout: persistent subvolumes + ephemeral root]]
  - [x] Declarative disko-managed btrfs layout with one named persistent subvolume for the package/build store
  - [x] One named persistent subvolume for all other persistent host state (app data, logs meant to survive reboots, configuration)
  - [x] zram-backed root filesystem, recreated empty every boot — nothing outside the two persistent subvolumes survives a reboot
  - [x] Wire disk/subvolume layout into host config's filesystem mounts; host builds and boots end-to-end against this storage shape
  - [x] Step 1.1's base host identity/network behavior left unmodified
  - [x] No additional snapshot/content-addressed/dedup filesystem layer added (no ZFS, no CoW image store)
## Chunk 2 — Nested Virtualization & KVM Access
- [x] Step 2.1 — KVM kernel modules and device access — [[02-host-platform-plan#Step 2.1 — KVM kernel modules and device access]]
  - [x] Load KVM kernel modules for both AMD and Intel virtualization extensions (CPU vendor not assumed) so `/dev/kvm` exists at boot
  - [x] Grant a dedicated, unprivileged "VM launcher" user/group permission to open/use `/dev/kvm` without root
  - [x] Document explicitly in the configuration that this host may run as a guest under an outer hypervisor, and that these modules are necessary but not sufficient — no attempt to detect/configure the outer hypervisor from here
- [x] Step 2.2 — Boot-time KVM availability verification — [[02-host-platform-plan#Step 2.2 — Boot-time KVM availability verification]]
  - [x] Verification check confirms `/dev/kvm` exists and can actually be opened by the VM-launcher user (not just node presence)
  - [x] On failure, distinguishes "KVM kernel module not loaded" vs. "device present but not usable (outer hypervisor nested-virt not enabled — contact host owner)"
  - [x] Runnable standalone as a pre-flight diagnostic before any guest launch
  - [x] Wired to run at boot alongside host startup, producing a log entry either way (pass or fail with cause)
## Chunk 3 — Exclusive cgroup v2 Enforcement
- [x] Step 3.1 — Mount cgroup v2 as the only hierarchy — [[02-host-platform-plan#Step 3.1 — Mount cgroup v2 as the only hierarchy]]
  - [x] Service manager mounts only the unified cgroup v2 hierarchy at boot, host-wide
  - [x] No legacy v1 cgroup hierarchy mounted anywhere on the system
  - [x] No per-service opt-out of this setting — strict platform guarantee, not an overridable default
- [x] Step 3.2 — cgroup v2-only verification guard — [[02-host-platform-plan#Step 3.2 — cgroup v2-only verification guard]]
  - [x] Check confirms the unified cgroup v2 controller interface is present
  - [x] Check confirms no legacy v1 cgroup hierarchy is mounted anywhere
  - [x] Fails loudly (clear log error, refuses to report healthy) if either condition is violated
  - [x] Structured the same way as the KVM-availability check (step 2.2)
  - [x] Wired into the same host pre-flight diagnostics story as the KVM check, so one "is this host ready" pass covers both
## Chunk 4 — Host Memory Posture for VM Density
- [ ] Step 4.1 — Swap-disabled, KSM-disabled memory posture guard — [[02-host-platform-plan#Step 4.1 — Swap-disabled, KSM-disabled memory posture guard]]
  - [x] Swap guarantee made explicit and host-config-pinned: no swap device ever activated
  - [x] KSM guarantee made explicit and host-config-pinned: KSM stays disabled, no KSM-enabling configuration present
  - [x] Boot-time verification check confirms no swap device is active and KSM run state is off, structured the same way as the KVM and cgroup v2-only checks
  - [x] Check fails loudly and refuses to report healthy if either condition is violated
  - [x] Wired into the same host pre-flight diagnostics story as the KVM and cgroup v2-only checks
  - [ ] Check's pass/fail state made part of the future `doctor` CLI's report once that component exists ([[12-production-hardening]])
  - [ ] Verify: boot host, confirm check reports both conditions healthy
  - [ ] Verify negative path: force one condition false in a test config (throwaway swap device, or KSM enabled) and confirm the check fails loudly with a distinct message per case
## Related

- [[02-host-platform-plan]] — the plan note this checklist derives from.
- [[02-host-platform]] — the spec note behind the plan.
