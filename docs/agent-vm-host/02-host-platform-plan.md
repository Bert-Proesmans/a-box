---
component: "host-platform-plan"
source: "02-host-platform.md"
tags: ["agent-vm-host", "spec-plan"]
---
# Host Platform — Implementation Plan

## Blueprint

Build order, each layer resting on the previous:

1. A base host system definition with a reproducible storage layout: two
   persistent subvolumes (one for the package/build store, one for all other
   persistent state) plus an ephemeral root wiped on every boot.
2. Nested-virtualization-aware KVM device access, since the VM launcher this
   platform hosts needs a working `/dev/kvm` and this host may itself run as
   a guest under an outer hypervisor.
3. An exclusive cgroup v2 hierarchy, mounted and verified with no v1 fallback
   anywhere, since every later resource-isolation mechanism assumes it.
4. A host memory posture for VM density (swap handling, KSM) — left as an
   open gap per the spec, not guessed at here.

Finished state: a host that boots reproducibly onto the specified storage
shape, exposes verified KVM access with an explicit outer-hypervisor
dependency documented, mounts cgroup v2 exclusively with a boot-time guard,
and has host memory tuning either resolved later or explicitly flagged
pending — never silently assumed.

## Chunks

1. Base Host OS & Storage Foundation
2. Nested Virtualization & KVM Access
3. Exclusive cgroup v2 Enforcement
4. Host Memory Posture for VM Density (open gap — no steps)

---

## Chunk 1 — Base Host OS & Storage Foundation

### Step 1.1 — Base host system definition

First step of the whole plan — nothing precedes it.

```text
Define a base operating system configuration for a single dedicated host
machine. Establish the host's basic identity (hostname, boot loader,
minimal set of system services and packages, network reachability, and an
administrative login path) so that, on its own, this configuration builds
and boots into a working, reachable machine — even before any of the
storage or virtualization specifics are added.

Do not add virtualization, cgroup, or storage-layout specifics yet; this
step only needs to produce a minimal but genuinely bootable and reachable
host. Structure the configuration so later steps can extend it (add
filesystem layout, kernel modules, and service units) without restructuring
what you produce here.
```

### Step 1.2 — Storage layout: persistent subvolumes + ephemeral root

Builds on step 1.1's base host definition.

```text
You are extending a base host operating system configuration (already
defined: boots, reachable, minimal). Add a declarative, disko-managed
btrfs storage layout to it, with:

- One named persistent subvolume holding the package/build store.
- One named persistent subvolume holding all other persistent host state
  (application data, logs meant to survive reboots, configuration).
- A root filesystem backed by zram (compressed RAM-backed block device)
  that is recreated empty on every boot — nothing written to `/` outside
  the two persistent subvolumes survives a reboot.

Wire the generated disk/subvolume layout into the host configuration's
filesystem mounts so the host builds and boots end-to-end against this
storage shape: the two persistent subvolumes mounted at appropriate
locations, the zram-backed filesystem mounted as the ephemeral root, and
the base host from step 1.1 unmodified in identity/network behavior.

Do not introduce any additional snapshot or content-addressed/dedup
filesystem layer (no ZFS, no CoW-based image store) — the two-subvolume
btrfs layout plus ephemeral root is the complete storage requirement for
this platform layer. Any future need to reuse or share large disk images
between sessions is handled by a mechanism defined outside this component
and out of scope here.
```

---

## Chunk 2 — Nested Virtualization & KVM Access

### Step 2.1 — KVM kernel modules and device access

Builds on chunk 1's bootable, storage-configured host.

```text
You are extending a host operating system configuration that already boots
with a defined storage layout (a package/build store subvolume, a general
persistent-state subvolume, and an ephemeral root). Add kernel-level
support for hardware-accelerated virtualization on this host:

- Load KVM kernel modules for both AMD and Intel CPU virtualization
  extensions (the host's actual CPU vendor is not assumed in advance), so
  that a `/dev/kvm` device node is created at boot.
- Grant a dedicated, unprivileged host-side "VM launcher" user/group
  permission to open and use `/dev/kvm` directly, without requiring root.

This host may itself be running as a virtualized guest under an outer
hypervisor. Document explicitly, in the configuration itself, that loading
these modules is necessary but not sufficient: if the outer hypervisor
does not also expose nested virtualization to this host, `/dev/kvm` will
not function even though it exists, and every downstream VM-launching
capability on this host will fail. Do not attempt to detect or configure
the outer hypervisor from here — only document the dependency clearly at
the point where it would bite.
```

### Step 2.2 — Boot-time KVM availability verification

Builds on step 2.1.

```text
You are extending a host configuration that now loads KVM kernel modules
and grants a dedicated VM-launcher user access to `/dev/kvm`, with a
documented dependency on nested virtualization being enabled at an outer
hypervisor layer. Add a small, host-level verification check — run
automatically at boot and also invokable manually on demand — that:

- Confirms `/dev/kvm` exists and can actually be opened by the VM-launcher
  user (not just that the device node is present).
- On failure, emits a clear, actionable message distinguishing two
  different causes: "KVM kernel module not loaded on this host" versus
  "device present but not usable, likely because the outer hypervisor has
  not enabled nested virtualization — contact the host owner."

This check must be able to run standalone as a pre-flight diagnostic
before any guest is launched, not only surface as a cryptic failure deep
inside guest-launch logic. Wire it to run at boot alongside the rest of
host startup, producing a log entry either way (pass or fail with cause).
```

---

## Chunk 3 — Exclusive cgroup v2 Enforcement

### Step 3.1 — Mount cgroup v2 as the only hierarchy

Builds on chunk 1's base host; independent of chunk 2's virtualization work.

```text
You are extending a host operating system configuration that already boots
with a defined storage layout. Configure the host's service manager to
mount only the unified cgroup v2 hierarchy at boot, host-wide, with no
legacy (v1) cgroup hierarchy mounted anywhere on the system and no
per-service opt-out of this setting. This is a strict platform guarantee,
not a default that individual services or later configuration may
override.
```

### Step 3.2 — cgroup v2-only verification guard

Builds on step 3.1, and pairs with the KVM verification check from step 2.2.

```text
You are extending a host configuration that mounts cgroup v2 exclusively
at boot. Add a boot-time verification check, structured the same way as
an existing KVM-availability pre-flight check on this host, that:

- Confirms the unified cgroup v2 controller interface is present.
- Confirms no legacy v1 cgroup hierarchy is mounted anywhere on the
  system.
- Fails loudly (clear log error, refuses to report healthy) if either
  condition is violated, rather than allowing a partially-v1 system to
  look fine until something downstream breaks.

Frame this in the configuration as the platform-level guarantee that every
later cgroup-touching component on this host — a VM launcher's cgroup
delegation, systemd resource-control unit directives, per-guest
device/interrupt placement, and any future resource-hardening work — can
rely on with no v1 fallback path of its own to build or maintain. This
mirrors the resolved "cgroup v2 only, everywhere in this subsystem"
decision recorded in [[15-decisions-log]]. Wire this check to run as part
of the same host pre-flight diagnostics story as the KVM-availability
check, so a single "is this host ready" pass covers both.
```

---

## Chunk 4 — Host Memory Posture for VM Density

> [!warning] Open gap — no implementation step
> Whether/how to disable or secure swap, and whether to disable KSM
> (kernel same-page merging), for a host that runs multiple untrusted VM
> guests concurrently is **not decided** in the spec. The host's storage
> foundation (chunk 1) already establishes an ephemeral, zram-backed root
> with no swap partition defined, but that is a storage-layout fact, not a
> memory-security decision — see the open question in
> [[15-decisions-log]]. No codegen prompt is generated for this chunk;
> guessing a swap/KSM policy risks baking in a security-relevant default
> the spec explicitly left open. Revisit once this decision is resolved,
> then add steps here following the same pattern as chunks 1–3.

## Related

- [[02-host-platform]] — the spec note this plan derives from.
- [[15-decisions-log]] — cgroup v2-only resolved decision (folded into
  chunk 3); host memory swap/KSM open question (chunk 4 open gap).
