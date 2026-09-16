# agent-vm

Isolated Firecracker microVM host for running Claude Code agent sessions.
See `docs/agent-vm-host-spec.md` for the design and `docs/agent-vm-host-plan.md`
for the build plan and step-by-step progress (`todo.md` tracks checklist
status). Enter the build environment with `nix-shell agent-vm/nix -A devshell`.

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
