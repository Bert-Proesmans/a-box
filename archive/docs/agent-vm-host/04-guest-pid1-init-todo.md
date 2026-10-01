---
component: guest-pid1-init-todo
source: 04-guest-pid1-init-plan.md
tags:
- agent-vm-host
- spec-todo
---
# Guest pid1-init — Build Checklist

A step's top-level box is a summary — check it only once every nested box under it is checked.

## Chunk 1 — Boot-time Filesystem & Workspace Assembly

- [x] Step 1.1 — pid1 binary skeleton & pseudo-filesystem mounts — [[04-guest-pid1-init-plan#Step 1.1 — pid1 binary skeleton & pseudo-filesystem mounts]]
  - [x] New statically-linked (musl target) Rust binary crate serving as guest pid1
  - [x] Mounts procfs at conventional mount point
  - [x] Mounts sysfs at conventional mount point
  - [x] Mounts a tmpfs for temporary storage
  - [x] Does not mount devtmpfs (kernel already mounts it before this process starts)
  - [x] After mounts succeed, writes a distinct marker string to stdout/console, then blocks indefinitely
  - [x] Structured so later boot stages (device/workspace mounts, vsock, privilege drop, exec) can be added without restructuring
  - [x] Verify: build for musl target, launch as guest init via existing VMM launcher + existing guest kernel + throwaway root disk containing just this binary; captured boot log shows marker string and no mount errors (no EBUSY from devtmpfs)
- [ ] Step 1.2 — Block-device mounts & overlayfs workspace assembly — [[04-guest-pid1-init-plan#Step 1.2 — Block-device mounts & overlayfs workspace assembly]]
  - [ ] Mounts guest's second virtio-block device read-only at an internal mount point
  - [ ] Mounts guest's third virtio-block device read-write at a second internal mount point
  - [ ] Combines device 2 (lower, read-only) and device 3 (upper, read-write) via kernel overlay filesystem into one merged, writable workspace mount point
  - [ ] After mounts succeed, writes a marker (including the merged mount point path) to boot console, then continues blocking
  - [ ] Verify: throwaway arbitrary-content disk images for devices 2/3, launch via existing VMM launcher with full three-disk config; captured boot log shows merged-mount-point marker
  - [ ] Verify overlay is genuinely writable end to end (e.g. marker reports a file existing only in the read-write upper device, or a write performed during boot)
  - Depends on: [[03-vmm-firecracker-plan#Step 3 — Full block-device model: three virtio-block devices]]

## Chunk 2 — Guest vsock Channels

- [x] Step 2.1 — Interactive stdio vsock connection — [[04-guest-pid1-init-plan#Step 2.1 — Interactive stdio vsock connection]]
  - [x] Opens vsock connection to host on one fixed, well-known port dedicated to interactive stdio, using the `nix` crate's AF_VSOCK support
  - [x] Holds the connection open (not closed) for a later step to duplicate onto the exec'd agent's stdin/stdout
  - [x] Temporary echo behavior on this connection for this step's own verification (left in place until replaced later)
  - [x] Verify: launch via existing VMM launcher; from host, connect to instance's dedicated vsock socket path, address the stdio port, send bytes, confirm echoed back unchanged
  - Depends on: [[03-vmm-firecracker-plan#Step 4 — vsock control-channel transport]]
  - `echo_agent` (spawned via `spawn.rs`, stdio dup'd) no longer prefixes lines with `echo: ` — it copies stdin to stdout byte-for-byte, so sent bytes come back unchanged. Verified against a real KVM boot in `test_session_manager_kvm.py`.
- [ ] Step 2.2 — Guest-side proxy-shim channel — [[04-guest-pid1-init-plan#Step 2.2 — Guest-side proxy-shim channel]]
  - [ ] After stdio connection established, starts the guest-side proxy-shim program as a child process (direct binary exec, never through a shell), bound to a loopback TCP port translating to a second fixed vsock port dedicated to proxy traffic
  - [ ] Does not wait for or supervise this child process afterward
  - [ ] Throwaway placeholder shim used here (real shim is [[05-network-egress-control]]'s deliverable): binds the loopback port, writes a marker on any incoming connection, then closes
  - [ ] Verify: launch via existing VMM launcher; boot-console marker confirms placeholder shim started and its loopback port is reachable inside the guest
  - [ ] Verify: connect to instance's dedicated vsock socket path on the proxy port from the host, confirm connection reaches the placeholder shim's translated loopback side
- [ ] Step 2.3 — BPF-exporter vsock connection — [[04-guest-pid1-init-plan#Step 2.3 — BPF-exporter vsock connection]]
  - [ ] Opens a third vsock connection to host on a third fixed, well-known port dedicated to BPF event export, using the same AF_VSOCK mechanism
  - [ ] Holds this connection open alongside the stdio connection (neither closed)
  - [ ] Temporary echo behavior on this connection for this step's own verification (same stopgap as Step 2.1, since real eBPF loader doesn't exist yet)
  - [ ] Verify: launch via existing VMM launcher; from host, connect to instance's dedicated vsock socket path, address the BPF-export port, send bytes, confirm echoed back unchanged
  - [ ] Verify: stdio and proxy-shim channels from the previous two steps still both work in the same boot

## Chunk 3 — eBPF Load While Root

- [ ] Step 3.1 — Invoke the eBPF loader before privilege drop — [[04-guest-pid1-init-plan#Step 3.1 — Invoke the eBPF loader before privilege drop]]
  - [ ] After vsock connections established and before any privilege drop, invokes the eBPF loader as a direct child process (direct binary exec, never through a shell) while still running as root
  - [ ] Hands the loader the already-open BPF-export vsock connection
  - [ ] Throwaway placeholder loader used here (real loader is [[07-bpf-monitoring]]'s deliverable): checks for `CAP_BPF`+`CAP_PERFMON`, writes a marker to boot console reporting presence, writes a further marker onto the handed-off BPF-export connection, then exits
  - [ ] Verify: launch via existing VMM launcher; captured boot log shows placeholder reporting both `CAP_BPF` and `CAP_PERFMON` present
  - [ ] Verify: connect to instance's dedicated vsock socket path on the BPF-export port from host, confirm placeholder's marker arrives over that connection
  - Ordering is load-bearing: must run strictly before Step 4.2's capability drop, per [[15-decisions-log]]'s "eBPF load privilege" decision

## Chunk 4 — Environment, Privilege Drop, and Exec

- [ ] Step 4.1 — Configure the agent's environment — [[04-guest-pid1-init-plan#Step 4.1 — Configure the agent's environment]]
  - [ ] Builds in memory: `HTTP_PROXY`/`HTTPS_PROXY` set to the proxy shim's loopback address, a placeholder credential env var set to an obviously-fake fixed string (never a real key), and a working directory pointing at the overlay workspace mount point
  - [ ] Does not start any process with this environment yet
  - [ ] Writes all prepared values to boot console as a marker for this step's verification
  - [ ] Verify: launch via existing VMM launcher; captured boot log shows the exact `HTTP_PROXY`/`HTTPS_PROXY` value, the placeholder credential marker (never a real credential), and the workspace working directory path
- [ ] Step 4.2 — Drop privileges — [[04-guest-pid1-init-plan#Step 4.2 — Drop privileges]]
  - [ ] Immediately after environment preparation, switches effective and real user/group to a dedicated unprivileged guest user
  - [ ] Strips every Linux capability from effective, permitted, and inheritable capability sets
  - [ ] No seccomp filtering or additional namespace isolation added (deliberate full extent of in-guest hardening, per [[08-in-guest-hardening]])
  - [ ] Writes a marker to boot console reporting resulting user/group identity and confirming capability sets are empty
  - [ ] Verify: launch via existing VMM launcher; captured boot log shows unprivileged user/group identity and empty capability sets, and this marker appears only after Step 3.1's eBPF-load marker, never before it
- [ ] Step 4.3 — exec into the agent — [[04-guest-pid1-init-plan#Step 4.3 — exec into the agent]]
  - [ ] Duplicates the held stdio vsock connection onto the placeholder agent process's standard input and output
  - [ ] Execs directly into the placeholder binary with the prepared environment and working directory, replacing this process's own image entirely (never forking)
  - [ ] Throwaway placeholder agent used here: echoes stdin to stdout, prints received environment variables and working directory once first
  - [ ] Verify end to end: launch via existing VMM launcher; from host, connect to instance's dedicated vsock socket path on the stdio port; confirm placeholder's environment/working-directory dump arrives first, then anything sent from host is echoed back
  - Current code spawns (`fork`+`exec` via `Command`) rather than truly `exec`ing into the agent, and never drops the parent pid1 image — this step still needs the fork's-worth of rework, not just an env/cwd addition

## Related

- [[04-guest-pid1-init-plan]] — the plan note this checklist derives from.
- [[04-guest-pid1-init]] — the spec note behind the plan.
