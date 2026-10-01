---
component: workspace-and-repo-delivery
source: agent-vm-host-spec.md
spec-section: §6
tags:
- agent-vm-host
- spec-component
---

# Workspace & Repository Delivery

How the guest gets code to work on, and how it gets read-only, audited access to git history without ever talking to GitHub directly.

## Host-local git mirroring

- The host keeps **full local mirror clones** of relevant repositories — not shallow, not on-demand-per-file — to cut latency and enable local dedup/reuse.
- The guest **never reaches GitHub directly.** It gets **restricted, read-only git-protocol access** (browsing branch history and file history — fetch/log/clone, no push/receive-pack) to a host-local git server serving the mirror.

### Sync timing

- The host fetches/updates its local mirror from upstream **on-demand, immediately before each task launch** — not on a periodic background timer.
- Every session starts from fresh upstream state, and launch time includes one fetch.

## How the guest reaches the git service

- The host runs **`git-http-backend`** bound to `127.0.0.1:<GIT_PORT>`, serving the mirror over **plain HTTP** — no TLS needed since this leg never leaves the host's own loopback.
- It's configured to expose only the `upload-pack` service (fetch/clone/`ls-remote`); `receive-pack` is not wired up at all. **That is the actual read-only enforcement — it lives in the git server's config, not the proxy.**
- Runs as its own **host-wide singleton systemd service** (`agentvm-git-service.service`), independent of any session's lifecycle — see [[10-session-lifecycle-orchestration|Session Lifecycle & Host Orchestration]] (host-wide singleton services, started independently of any session and outliving all of them).
- Every session's VM unit has a one-way `Requires=`+`After=` dependency on this service (must be up before the session starts, but the service's lifetime isn't coupled to any one session).

### Request path

- When the agent runs `git fetch`/`git log --all`/`git blame`, the request takes the same path as every other guest HTTP request: guest git client → loopback vsock↔TCP shim → vsock → [[05-network-egress-control|mitmproxy]] on the host → (allowlisted loopback target) → the git service.
- Being plain HTTP, mitmproxy doesn't even need to MITM this leg — it reads the request in the clear, logs it, and forwards it.

### Defense in depth

- mitmproxy additionally rejects any request whose path contains `git-receive-pack` to this destination, even though the backend doesn't expose that service anyway.
- [[07-bpf-monitoring|BPF's exec/network/file-open logging]] gives an independent audit trail on top of both the git server config and the proxy rule.

### Device 2 as a shallow clone

- Device 2 (see the three-block-device layout below) is built as a **shallow clone (`--depth=1`)** of the pinned commit from the local mirror, not a bare file export.
- This gives the guest a real (tiny) `.git` directory with exactly one remote configured: `http://127.0.0.1:<GIT_PORT>/<repo>.git` — the host-local service above, never GitHub.
- Startup cost barely changes versus a flat checkout (still one commit's worth of objects), but the agent's own git client can now extend history on demand (fetch more commits, blame, browse branches).

### Why not a 4th block device (file:// mount)?

Mounting the bare mirror directly as a block device (`file://`) was rejected because:

- It would give the guest low-level filesystem access to every ref/tag/packfile with **no protocol-level gatekeeping and no request log**.
- It would reintroduce a "how do we keep this fresh right before launch without rebuilding an image" problem.
- The on-demand HTTP fetch avoids both: the guest pulls only what it actually asks for, and every pull is logged.
- This is the origin of the earlier requirement that the agent must not reach a git process that manages the full history/blob store directly.

#open-question Server-side wrapping of `git-http-backend` (CGI runner vs. a small custom wrapper) remains an open implementation choice — see [[15-decisions-log|Decisions Log]].

## Three-block-device layout per guest

| # | Device | Contents | Read-only? | Reuse scope |
|---|--------|----------|------------|-------------|
| 1 | OS/toolchain rootfs | Nix-built closure (see [[09-guest-rootfs|Guest Rootfs]]) | Read-only | Shared across **all** sessions; rebuilt only when the tool allowlist changes |
| 2 | Workspace checkout | Filesystem image (squashfs/erofs) built from a checkout of the local mirror at a pinned commit | Read-only | Shared across **all concurrently-running tasks on that commit**; rebuilt per commit |
| 3 | Per-task writable overlay | Small empty ext4 image | Read-write | Per-task only |

The guest mounts device 2 (lower) and device 3 (upper) via **overlayfs inside the guest**, producing the merged, writable workspace view. This achieves zero-copy reuse of both the toolchain and the checked-out code across multiple concurrent agents — sharing happens at the read-only-image level (the same backing file attached read-only to many VMs at once), not via host-side CoW filesystem tricks.

## Result extraction & review

- **No automatic git integration.** Nothing is applied to any branch, committed, or pushed automatically.
- After a session ends, the host loop-mounts **only device 3** (the small writable overlay) to extract the changed files.
- The extracted result is presented as a **terminal-based diff** (standard unified diff / `git diff` against the pinned base commit, viewable via existing tools like `delta`/`less`) for manual review.
- This fits the terminal-first interaction model used throughout the design.

## Related

- [[05-network-egress-control|Network Egress Control]] — all git-service HTTP traffic still goes guest → proxy → git service, and mitmproxy is where the `git-receive-pack` rejection rule lives.
- [[10-session-lifecycle-orchestration|Session Lifecycle & Host Orchestration]] — the git service is one of the host-wide singleton services outliving individual sessions.
- [[09-guest-rootfs|Guest Rootfs (Device 1)]] — the other read-only, shared block device in the per-guest layout.
- [[07-bpf-monitoring|BPF Monitoring]] — provides the independent audit trail backing up the git server's protocol-level restrictions.
- [[03-vmm-firecracker|VMM: Firecracker]] — attaches the three block devices to each guest.
