---
component: guest-rootfs-todo
source: 09-guest-rootfs-plan.md
tags:
- agent-vm-host
- spec-todo
---
# Guest Rootfs (Device 1) — Todo

A step's top-level box is a summary checkbox; check it only when every nested box under it is checked.

## Chunk 1 — Self-Contained Nix Closure

- [ ] Step 1 — Self-contained, whitelisted-tool Nix closure — [[09-guest-rootfs-plan#Step 1 — Self-contained, whitelisted-tool Nix closure]]
  - [ ] Define an explicit, single, named "tool allowlist" enumerating the CLI tools, the Python interpreter, and the Claude Code CLI, structured so a later change to this one list is the only intended way to change the image's contents
  - [ ] Build a Nix derivation, exposed as an independently buildable output matching this repo's existing convention, assembling the closure of exactly the allowlisted packages (plus their transitive runtime deps) via nixpkgs' closure-to-squashfs helper
  - [ ] Verify (a): build the derivation, confirm its output is a valid filesystem image
  - [ ] Verify (b): inspect store paths referenced by binaries/libraries inside the built image, confirm every one carries this image's own isolated store prefix, none resolve to or require the host's store at runtime
  - [ ] Verify (c): confirm the set of packages present in the built image's closure matches exactly the allowlist (nothing extra, nothing missing)
  - [ ] Verify (d): for each network-calling tool in the allowlist, run it inside a sandboxed environment with `http_proxy`/`https_proxy` pointed at a throwaway local listener and direct network access blocked, confirm its traffic arrives at that listener rather than attempting a direct connection — repeatable for any tool added to the allowlist later

## Chunk 2 — Bootable Init Wiring

- [ ] Step 2 — Bootable init wiring — [[09-guest-rootfs-plan#Step 2 — Bootable init wiring]]
  - [ ] Extend the build so the already-built pid1 binary (and its own runtime deps) is included in the same self-contained closure and placed at the fixed path the guest kernel's boot arguments designate as the init to exec
  - [ ] Preserve full self-containment: the added binary and its dependencies resolve entirely within this image's own isolated store prefix, no exception
  - [ ] Verify: using the already-built guest kernel and VMM launcher, launch a microVM with this image attached as the sole boot disk (device 1) and boot arguments (no initrd) execing the wired init path; confirm the captured boot log shows the pid1 binary's own earliest-boot-stage startup marker, proving it ran from inside this image's own isolated store

## Chunk 3 — Trust-Store Provisioning

- [ ] Step 3 — Trust-store provisioning for the mitmproxy CA — [[09-guest-rootfs-plan#Step 3 — Trust-store provisioning for the mitmproxy CA]]
  - [ ] Extend the build to accept a CA certificate file as a build input and add it into the image's system-wide trust-store bundle, so every tool that consults the system trust store for TLS verification picks it up automatically with no per-tool configuration
  - [ ] Preserve full self-containment: the augmented trust-store bundle lives inside this image's own isolated store prefix like everything else in the closure
  - [ ] Verify (a): inspect the built image's trust-store bundle, confirm it contains exactly the injected certificate in addition to the image's normal default trust anchors
  - [ ] Verify (b): stand up a throwaway local TLS test endpoint presenting a certificate signed by the same CA, and, using one of the closure's own TLS-capable tools run inside a sandboxed environment against this image's assembled root filesystem, confirm a connection to that endpoint is trusted with no per-connection CA override

## Chunk 4 — Reuse & Rebuild Policy

- [ ] Step 4 — Reuse and rebuild policy: shared read-only, gated only by the allowlist — [[09-guest-rootfs-plan#Step 4 — Reuse and rebuild policy: shared read-only, gated only by the allowlist]]
  - [ ] (a) Confirm, and if necessary restructure, the build so the tool allowlist is the only input whose change is expected to produce a new, distinct built image — check directly, don't assume it falls out of the build tooling's caching behavior
  - [ ] (b) Wire the built image into the existing VMM launcher's device-1 slot as an artifact meant to be attached read-only to more than one simultaneously running guest at once
  - [ ] Verify (i): build the image twice with no changes, confirm identical output (determinism); touch/change something unrelated in the build environment, confirm the previously-built image is still produced (no spurious rebuild); change the allowlist itself, confirm a new, distinct image artifact results
  - [ ] Verify (ii): using the VMM launcher's multi-disk-attach capability, launch two or more microVM instances simultaneously, each with this exact same single built image attached read-only as device 1, confirm every instance independently boots and reaches its own init marker with no interference between instances sharing the one backing image

## Related

- [[09-guest-rootfs]] — the spec this plan implements.
- [[09-guest-rootfs-plan]] — the plan this checklist tracks.
