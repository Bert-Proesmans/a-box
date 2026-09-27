---
component: guest-rootfs-plan
source: 09-guest-rootfs.md
tags:
- agent-vm-host
- spec-plan
---

# Guest Rootfs (Device 1) — Implementation Plan

## Blueprint

[[09-guest-rootfs]] specifies device 1 of the guest's three-block-device
layout: a custom-built, minimal, Python-focused Nix image carrying a
whitelisted CLI tool set plus the Claude Code CLI. Nothing in this
component exists yet. The finished state this plan builds toward: a single
reproducible build producing a read-only filesystem image that is a fully
self-contained Nix closure — its own isolated `/nix/store` prefix, no
bind-mount or other sharing of the host's store — with the mitmproxy CA
certificate baked into its trust store at build time, wired to boot as the
guest's device 1 through the already-planned kernel/VMM/pid1 chain, and
reused unchanged across every session until the tool allowlist itself
changes.

Build order follows the spec's own layering: the closure and its isolation
guarantee must exist before anything can boot from it; the image only
becomes a real guest rootfs once it carries a bootable init at the path the
kernel/VMM boot arguments expect; trust-store provisioning is an
independent addition layered onto an already-bootable image; and the
reuse/rebuild policy is the last property to prove, because it's about how
this image behaves across many builds and many concurrent guests, not
about any one build's contents.

This plan does not build: the kernel or VMM launcher
([[03-vmm-firecracker]], already planned in [[03-vmm-firecracker-plan]]),
the pid1 binary itself ([[04-guest-pid1-init]], already planned in
[[04-guest-pid1-init-plan]]), the mitmproxy CA or the proxy that terminates
TLS with it ([[05-network-egress-control]]), or device 2/3's
workspace-overlay content ([[06-workspace-and-repo-delivery]]). Where a
step needs one of those as an already-existing dependency (the kernel, the
VMM launcher, the pid1 binary, a CA certificate/key pair), that is called
out explicitly as a pre-existing input to this component, not something
this plan produces.

**Resolution status:** [[15-decisions-log]]'s "Still open" section has no
item tagged directly against [[09-guest-rootfs]]. Its resolved "Nix
closure isolation mechanism" decision — nixpkgs' own `make-squashfs`
closure helper, producing an image with its own isolated `/nix/store`
prefix, rather than bind-mounting the host's — is folded into Step 1
below. Two further items from [[05-network-egress-control]] bear directly
on this component's own build and are likewise resolved and folded into
Step 1, not open: the "package-registry strategy" decision — this guest
has no runtime dependency-installation path for any ecosystem at all;
everything a session needs must already be in this image's closure before
the session starts, so this plan's tool allowlist (Step 1) stays scoped to
the CLI tools and Claude Code CLI the spec actually names, with no
speculative package-manager tooling added — and the spec's standing
implementation note that every tool in the closure must actually honor
`http_proxy`/`https_proxy` for all of its network paths, folded into
Step 1's own verification (part d) as a repeatable per-tool obligation,
not a one-time check.
## Chunks

1. **Chunk 1 — Self-contained Nix closure.** Build the isolated-store
   closure image carrying the whitelisted tool set. (Step 1)
2. **Chunk 2 — Bootable init wiring.** Make the closure image a real,
   bootable guest rootfs. (Step 2)
3. **Chunk 3 — Trust-store provisioning.** Bake the mitmproxy CA into the
   image's trust store at build time. (Step 3)
4. **Chunk 4 — Reuse & rebuild policy.** Prove the image is shareable
   read-only across concurrent guests and rebuilds only when the allowlist
   changes. (Step 4)

---

## Step 1 — Self-contained, whitelisted-tool Nix closure

Chunk 1, single step. Foundation — no prior step exists yet.

```text
You are building a component of a Firecracker-based guest VM subsystem,
from its specification, from scratch. Nothing has been implemented for
this component yet.

Specification facts to ground this task in: this component is a custom,
minimal, Python-focused OS/toolchain image, built as a Nix closure,
containing a whitelisted set of CLI tools plus the Claude Code CLI. It
must be a fully self-contained Nix closure — no bind-mounting or otherwise
sharing the host's own Nix package store, or any other external store, at
build time or run time. The finished image contains exactly and only its
own isolated store holding the allowed tools and their own runtime
dependencies — nothing borrowed from, or referencing, any store outside
itself.

A settled build decision for this task, already resolved and not to be
re-derived: build the image using nixpkgs' own closure-to-squashfs helper
mechanism, which already produces an image carrying its own isolated
store prefix, rather than inventing a bind-mount-based scheme.

A standing verification obligation for every tool included here, from this
subsystem's design: since this guest has no direct network interface and
relies entirely on `http_proxy`/`https_proxy` environment variables to
reach anything, every tool in the closure must actually honor those
variables for all of its own network code paths — some tools have bugs or
fallback paths that ignore proxy configuration and try a direct
connection/resolution instead. Package-manager tools beyond git (pip, npm,
etc.) are not included here, and if ever included must never be wired to a
live registry: per [[15-decisions-log|the package-registry strategy
decision]], this guest has no runtime dependency-installation path for any
ecosystem — every library a session needs must already be in this image's
closure before the session starts, added via this same allowlist and a
rebuild, never fetched over the network at task time. Keep this step's
allowlist to the CLI tools and Claude Code CLI the specification actually
names; do not add speculative package-manager tooling here.

Task: define an explicit, single, named list — the "tool allowlist" — that
enumerates exactly which CLI tools, the Python interpreter, and the Claude
Code CLI belong in this image, structured so a later change to this one
list is the only intended way to change the image's contents. Build a Nix
derivation, exposed as an independently buildable output the way other
standalone build artifacts in this repo are already exposed, that
assembles the Nix closure of exactly the packages named in the allowlist
(plus their own transitive runtime dependencies) and packages that closure
into a read-only filesystem image using the settled closure-to-squashfs
build decision above.

Verify: (a) build the derivation and confirm its output is a valid
filesystem image. (b) Inspect the store paths referenced by binaries and
libraries inside the built image and confirm every one of them carries
this image's own isolated store prefix — none of them resolve to, or
require, the host's own package store at runtime. (c) Confirm the set of
packages present in the built image's closure matches exactly the
allowlist (nothing extra, nothing missing). (d) For each tool in the
allowlist that makes outbound network calls, run it inside a sandboxed
environment with `http_proxy`/`https_proxy` pointed at a throwaway local
listener and with direct network access blocked, and confirm the tool's
traffic actually arrives at that listener rather than attempting a direct
connection — this is the per-tool proxy-honoring smoke test the design
calls for, and it must be repeatable for any tool added to the allowlist
later, not just run once now.
```
## Step 2 — Bootable init wiring

Chunk 2, single step. Builds on Step 1's closure image. The guest kernel
and VMM launcher this step boots against, and the no-initrd/custom-init
boot-argument contract they establish, are an already-planned dependency:
[[03-vmm-firecracker-plan#Step 2 — Minimal boot proof: one root disk, captured boot log]]
proves that contract with a placeholder init, and
[[03-vmm-firecracker-plan#Step 3 — Full block-device model: three virtio-block devices]]
fixes this image's device slot as device 1. The init binary itself is an
already-planned, separately-built dependency:
[[04-guest-pid1-init-plan#Step 1.1 — pid1 binary skeleton & pseudo-filesystem mounts]].

```text
Context already built: a Nix derivation producing a read-only, fully
self-contained closure image (its own isolated store prefix, no bind-mount
of any external store) holding a whitelisted set of CLI tools, Python, and
the Claude Code CLI, verified for closure correctness and per-tool
proxy-honoring in an earlier step.

Specification facts for this task: the guest kernel boots directly into a
custom pid1 process with no traditional init system and no initrd — root
comes from this image, attached as a virtio-block device, and the kernel's
boot arguments point at a fixed path for the init binary to exec. A
separate, already-built pid1 binary exists as this subsystem's real init
implementation; this task's job is only to place that already-built binary
at the boot-expected path inside this image, not to build or modify the
binary itself.

Task: extend this component's build so the already-built pid1 binary (and
any of its own runtime dependencies) is included as part of this same
self-contained closure and placed at the fixed path the guest kernel's
boot arguments designate as the init to exec, inside the assembled
filesystem image. Preserve full self-containment: this added binary and
its dependencies must resolve entirely within this image's own isolated
store prefix, exactly like every other tool already in the closure — no
exception carved out for it.

Verify: using the already-built guest kernel and VMM launcher, launch a
microVM instance with this image attached as the sole boot disk (device 1)
and with the kernel's boot arguments configured, no initrd anywhere in the
path, to exec the init path this task wired up. Confirm the captured boot
log shows whatever startup marker the pid1 binary currently emits at its
own earliest boot stage, proving it was located and executed from inside
this image's own isolated store — not a placeholder init, and not
anything reached via a host bind-mount. This is the first point at which
this component is a genuine, bootable guest rootfs rather than just a
built closure.
```

## Step 3 — Trust-store provisioning for the mitmproxy CA

Chunk 3, single step. Builds on Step 2's bootable image. The CA
certificate itself is an already-existing input owned by
[[05-network-egress-control]] — this step only consumes it, never
generates or rotates it.

```text
Context already built: a self-contained closure image that boots, execs
the already-built pid1 binary as init from within its own isolated store,
and carries a whitelisted CLI tool set plus Python and the Claude Code
CLI.

Specification facts for this task: a separate, already-existing
TLS-intercepting proxy component owns a CA certificate it uses to
terminate and re-encrypt the guest's outbound HTTPS traffic. For the guest
to trust that proxy transparently, this CA certificate must be installed
into this image's own system-wide trust store at build time — not
provisioned at runtime, and not configured per-tool. Rotating the CA
means rebuilding this image; that is expected, not a bug to work around.

Task: extend this component's build to accept a CA certificate file as a
build input, and add it into this image's system-wide trust-store bundle
so that every tool in the closure which consults the system trust store
for TLS verification picks up this CA automatically, with no per-tool
configuration flag or override needed. Preserve full self-containment —
the augmented trust-store bundle must live inside this image's own
isolated store prefix like everything else in the closure.

Verify: (a) inspect the built image's trust-store bundle and confirm it
contains exactly this injected certificate in addition to the image's
normal default trust anchors. (b) Stand up a throwaway local TLS test
endpoint presenting a certificate signed by this same CA, and, using one
of the closure's own TLS-capable tools run inside a sandboxed environment
against this image's assembled root filesystem, confirm a connection to
that endpoint is trusted with no per-connection CA override — proving
system-level trust rather than one-off, manually-supplied trust. Do not
attempt to exercise the real proxy or real Anthropic-API allowlisting here
— that is [[05-network-egress-control]]'s own component, not built by this
plan.
```

## Step 4 — Reuse and rebuild policy: shared read-only, gated only by the allowlist

Chunk 4, single step, closing the plan. Builds on Step 3's fully
provisioned image. Verifying concurrent read-only sharing depends on the
already-planned multi-disk-attach launcher from
[[03-vmm-firecracker-plan#Step 3 — Full block-device model: three virtio-block devices]].

```text
Context already built: a self-contained closure image that boots, execs
the already-built pid1 binary from within its own isolated store, carries
the whitelisted tool set plus Python and the Claude Code CLI, and has the
mitmproxy CA baked into its system trust store.

Specification facts for this task: this image is rebuilt only when the
tool allowlist changes — otherwise it is reused unchanged across every
session. This is exactly what makes it shareable: a single read-only build
attached to many concurrently-running guests at once, with no per-session
copy and no per-session rebuild.

Task: (a) confirm, and if necessary restructure, this component's build so
that the tool allowlist defined in an earlier step is the only input whose
change is expected to produce a new, distinct built image — an unrelated
change elsewhere in the build environment must not force a rebuild of an
otherwise-identical image, and this must not merely be assumed to fall out
of the build tooling's caching behavior; it must be checked directly. (b)
Wire this built image into the existing VMM launcher's device-1 slot as an
artifact meant to be attached read-only to more than one simultaneously
running guest instance at once.

Verify: (i) build this image twice with no changes and confirm the two
builds produce the identical output artifact (proving determinism); touch
or change something in the build environment unrelated to the allowlist
and confirm the previously-built image is still the one produced (no
spurious rebuild); then change the allowlist itself (add, remove, or
version-bump one tool) and confirm a new, distinct image artifact results.
(ii) using the already-built VMM launcher's multi-disk-attach capability,
launch two or more microVM instances simultaneously, each with this exact
same single built image attached read-only as their device 1, and confirm
every instance independently boots and reaches its own init marker with
no interference between instances sharing the one backing image. This
closes the plan: every property [[09-guest-rootfs]] specifies —
self-contained closure, bootable, CA-provisioned, and shared read-only
until the allowlist changes — is now built and machine-verified.
```

## Related

- [[09-guest-rootfs]] — the spec note this plan derives from.
- [[15-decisions-log]] — resolved "Nix closure isolation mechanism"
  decision folded into Step 1; the package-registry strategy decision
  (no runtime package installs, ever — everything pre-baked) also folded
  into Step 1.
- [[06-workspace-and-repo-delivery]] — device 1's place in the
  three-block-device layout; owns device 2/3 content, out of scope here.
- [[03-vmm-firecracker-plan]] — the kernel, no-initrd boot contract, and
  fixed device-1 slot Step 2 and Step 4 boot and attach against.
- [[04-guest-pid1-init-plan]] — the already-built pid1 binary wired into
  this image's boot path in Step 2.
- [[05-network-egress-control]] — supplies the CA certificate consumed in
  Step 3; which package-manager tools (if any) belong in the guest closure
  at all remains a separate, ordinary tool-allowlist curation call — not
  gated on network access, since none is ever granted for that purpose.
  Step 1's own proxy-honoring smoke test (part d) is a standing per-tool
  verification duty this design calls for, not an open item.
- [[08-in-guest-hardening]] — the whitelisted tool set built here is why a
  seccomp allowlist was judged not worth the added cost.
- [[02-host-platform-plan]] — Step 1.2's package/build-store subvolume is
  where this component's own Nix builds live on the host; distinct from,
  and never bind-mounted into, this image's own isolated store.
