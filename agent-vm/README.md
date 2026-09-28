# agent-vm
Isolated Firecracker microVM host for running Claude Code agent sessions.
Design/plan/checklist notes now live split per-component under
`docs/agent-vm-host/` (`archive/agent-vm-host-spec.md` and `archive/todo.md`
are the superseded originals); root `TODO.md` rolls up chunk-level progress
across all of them. Enter the build environment with `nix-shell agent-vm/nix
-A devshell`.

## Source layout

- `bpf/` - C/libbpf CO-RE scaffold: `progs/noop.bpf.c` (BPF program) +
  `loader/main.c` (userspace loader), built by `nix/bpf.nix`. Real
  tracepoint programs land in chunk G (see
  [[07-bpf-monitoring-todo|07-bpf-monitoring]]).
- `guest/` - Rust cargo workspace holding the two binaries that run inside
  the microVM:
  - `pid1-init/` - the guest's PID 1: mount setup (`mount.rs`), vsock
    channels (`vsock.rs`), port constants (`ports.rs`), process spawn
    (`spawn.rs`). Built statically (musl, `pkgsStatic`) by
    `nix/guest-init.nix`.
  - `echo-agent/` - stub agent binary standing in for the real Claude Code
    agent process until later chunks replace it.
- `host/` - the `agentvm` Python package (host-side orchestration CLI),
  packaged by `nix/host-package.nix`:
  - `src/agentvm/cli.py` - click entrypoint (currently a stub).
  - `src/agentvm/firecracker.py` - `FirecrackerVM` wrapper.
  - `src/agentvm/session_manager.py` - `SessionManager`/`TerminalRecorder`/
    `AttachHub`: holds a session's guest vsock stdio connection for its
    whole lifetime, tees bytes to `terminal.jsonl`, fans out to `attach`
    clients over a local Unix socket. One thread-based instance per
    session, no shared event loop (see file's own docstring for why).
  - `src/agentvm/vsock_bridge.py` - `connect_guest_port` helper.
  - `tests/` - pytest suite; `conftest.py` builds `guest-kernel`/
    `device1-v0` via `nix-build` as session-scoped fixtures, and defines
    `needs_kvm`/`needs_root`/`needs_bpf` markers (auto-skipped when
    unavailable, e.g. no usable `/dev/kvm`) so `pytest agent-vm/host` stays
    runnable without special privileges.
- `nix/` - all Nix build definitions, collected in `default.nix`:
  `devshell.nix` (dev shell), `host-package.nix` (the `agentvm` CLI
  package), `bpf.nix` (bpf scaffold), `guest-init.nix` (static
  `pid1-init`), `guest-kernel.nix` (guest kernel image) +
  `guest-kernel-check.nix` (build-time check: real bootable x86 ELF),
  `device1-v0.nix` (guest rootfs squashfs image) +
  `device1-v0-check.nix` (build-time check: exact expected file listing).
  The `-check.nix` files are Nix build-time derivation checks, distinct
  from the boot-time host checks below.

Host-OS-level configuration this subsystem depends on (KVM kernel modules,
cgroup v2, memory posture, the dedicated `vm-launcher` user, and the
`agent-vm-host-preflight` boot-time check) lives outside this directory, in
the repo-root `llm-host.nix` and `agent-vm-host-platform.nix` - see
[[02-host-platform]].

## External references

Looked at while researching chunk K4 (hugepages) and K5 (jailer/systemd/cgroups
hardening). Kept here so we don't have to re-derive where this stuff came from.

- [firecracker/docs/jailer.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md) - chroot/uid/cgroup mechanics; cgroups are opt-in, not automatic; `--cgroup-version` defaults to `1`.
- [firecracker/docs/prod-host-setup.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/prod-host-setup.md) - source of K5's checklist: jailer, cgroup resource limits, KVM tuning (`min_timer_period_us`, `kvm-pit`, SMT, `nx_huge_pages`/`favordynmods`).
- [firecracker/docs/vsock.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/vsock.md) - host side is a Unix-domain-socket proxy, not real AF_VSOCK; no peer-CID exposed to host processes.
- [firecracker/docs/hugepages.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/hugepages.md) - `None`/`Transparent`/`2M` tradeoffs behind K4.
- [firecracker/src/firecracker/swagger/firecracker.yaml](https://github.com/firecracker-microvm/firecracker/blob/main/src/firecracker/swagger/firecracker.yaml) - API schema; confirms `Vsock` device has no rate-limiter field.
- [firecracker-containerd/runtime/jailer.go](https://github.com/firecracker-microvm/firecracker-containerd/blob/main/runtime/jailer.go) + [docs/architecture.md](https://github.com/firecracker-microvm/firecracker-containerd/blob/main/docs/architecture.md) - containerd's shim invokes jailer per VM itself; containerd supervises, no systemd.
- [trailofbits/coop issue #479](https://github.com/trailofbits/coop/issues/479) - security audit of a jailer-less firecracker setup; concluded direction is jailer + systemd/cgroup-v2 supervision, not systemd sandboxing as a jailer replacement.
- [**Project: srv**](https://github.com/HeavyHorst/srv) - closest scale analog to agent-vm (single-host, single-operator, SSH-driven CLI). Root-owned VM runner execs jailer directly per VM, per-VM cgroup v2 leaf, no systemd-per-VM - own daemon supervises instead.
- [**Project: Cratera**](https://cratera.org/) - public worked example of jailer wrapped in a systemd unit: `Delegate=yes`, fixed uid/gid, `IPAddressDeny=any`. Illustrative, not an authoritative source.
