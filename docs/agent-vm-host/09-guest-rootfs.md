---
component: guest-rootfs
source: agent-vm-host-spec.md
spec-section: §9
tags:
- agent-vm-host
- spec-component
---

# Guest Rootfs (Device 1)

The OS/toolchain image every guest boots from — device 1 in the [[06-workspace-and-repo-delivery|three-block-device layout]].

## Build characteristics

- **Custom-built, minimal, Nix-based image**, Python-focused, containing a **whitelisted set of CLI tools** plus the Claude Code CLI.

## Fully self-contained closure requirement

- **Must be a fully self-contained Nix closure** — no bind-mounting or otherwise sharing the host's `/nix/store` or any other Nix store.
- The image contains exactly and only its own isolated store with the allowed tools.


## No runtime dependency installation

- **No package manager may reach a live registry from inside a running
  guest** — not pip, not npm, not cargo, not apt, none. This is a
  structural design constraint, not a temporary gap: no mechanism, block
  device, or egress-allowlist entry is intended to support it (see
  [[15-decisions-log|the package-registry strategy decision]]).
- Everything a session needs to execute tests, run experiments, fuzz, or
  do a normal task run — interpreters, test/fuzz frameworks, any
  interpreter-level libraries — must already be present in this image's
  Nix closure before the session starts.
- A repository whose test/build/run path depends on a library not already
  in this image's closure is out of scope for this design as-is: the fix
  is to add that library to the tool allowlist and rebuild this image (the
  existing [[#Reuse and rebuild policy|rebuild-on-allowlist-change path]]),
  not to fetch it at session runtime.
## Trust store provisioning

- The [[05-network-egress-control|mitmproxy CA certificate]] is installed into this image's trust store **at build time**, so the guest transparently trusts the TLS-intercepting proxy for its outbound HTTPS traffic.

## Reuse and rebuild policy

- Rebuilt **only when the tool allowlist changes** — otherwise reused unchanged across all sessions.
- This is what makes it shareable: read-only, attached to many concurrently-running guests at once (see the [[06-workspace-and-repo-delivery|three-block-device layout]], where device 1 is "shared across all sessions").

## Related

- [[06-workspace-and-repo-delivery|Workspace & Repository Delivery]] — device 1 in the three-device layout; contrasts with device 2 (rebuilt per commit) and device 3 (per-task).
- [[05-network-egress-control|Network Egress Control]] — supplies the CA certificate baked into this image's trust store.
- [[08-in-guest-hardening|In-Guest Hardening]] — the whitelisted tool set here is part of why a seccomp allowlist was judged not worth the added cost.
- [[03-vmm-firecracker|VMM: Firecracker]] — attaches this image read-only to the guest.
