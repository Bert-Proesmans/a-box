# Agent VM Host — Build Checklist

Tracks implementation of `docs/agent-vm-host-spec.md` via the staged plan in
`docs/agent-vm-host-plan.md`. Work top to bottom, chunk by chunk, step by
step — later steps assume earlier ones are merged and green.

Test markers used throughout: `needs_kvm` (requires `/dev/kvm`), `needs_root`
(requires elevated privileges, e.g. loop-mounts/BPF load), `needs_bpf`
(requires BPF load capability). Anything unmarked should run anywhere.

## Chunk overview

- [x] A — Scaffolding
- [x] B — Firecracker walking skeleton
- [ ] C — vsock stdio + attach
- [ ] D — Host git mirror & service
- [ ] E — Block devices & workspace
- [ ] F — Network egress
- [ ] G — eBPF monitoring
- [ ] H — Guest rootfs closure
- [ ] I — Orchestration (systemd units) + CLI
- [ ] J — Transcript unification
- [ ] K — Hardening & polish

---

## Chunk A — Scaffolding

- [x] **A1 — Devshell & repo layout**
  - [x] Create `agent-vm/{host,guest,bpf,nix}/` directories
  - [x] `agent-vm/nix/devshell.nix`: Rust musl target, clang, libbpf, bpftool, python3+pytest+mypy, firecracker
  - [x] Wire into `lon`'s pinned-source mechanism (no flakes/niv)
  - [x] `agent-vm/README.md` pointing at spec + plan docs
  - [x] Verify devshell evaluates/builds standalone
- [x] **A2 — Python package skeleton**
  - [x] `pyproject.toml`, `src/agentvm/__init__.py` (`__version__`), `src/agentvm/cli.py` (`--version`)
  - [x] `tests/test_cli.py` written first, confirmed failing, then implemented
  - [x] `agent-vm/nix/host-package.nix` packaging via `buildPythonApplication`
  - [x] `agentvm --version` works inside devshell; `pytest` green
- [x] **A3 — Rust pid1-init workspace skeleton**
  - [x] Cargo workspace with `pid1-init` member (`main.rs` + `lib.rs`)
  - [x] Placeholder test in `tests/placeholder.rs`
  - [x] `agent-vm/nix/guest-init.nix`: static musl build, verify with `file` (no dynamic interpreter)
  - [x] `cargo test --workspace` passes in devshell
- [x] **A4 — C/libbpf skeleton**
  - [x] `bpf/Makefile`, `bpf/progs/noop.bpf.c`, `bpf/loader/main.c` (open/load, exit 0)
  - [x] `agent-vm/nix/bpf.nix` derivation
  - [x] Build succeeds; `file` confirms valid ELF (real load-check deferred to chunk G)

## Chunk B — Firecracker walking skeleton

- [x] **B1 — Minimal guest kernel**
  - [x] `agent-vm/nix/guest-kernel.nix` config fragment: VIRTIO_BLK, VIRTIO_VSOCKETS, DEVTMPFS(+MOUNT), TMPFS, OVERLAY_FS, SQUASHFS, BPF+BPF_SYSCALL+KPROBES/BPF_EVENTS, PROC_FS/SYSFS
  - [x] Non-modular (built-in only) kernel build - `CONFIG_MODULES=n`. `pkgs.buildLinux` (generic.nix) hardcodes `CONFIG_MODULES="y"` with no override point; built via `pkgs.linuxManualConfig` (`build.nix` directly) instead, reusing `buildLinux`'s resolved `.configfile` for the fragment-to-config step
  - [x] `vmlinux` output exists, non-empty, `file`-verified as an ELF x86-64 executable - deviates from the plan's `bzImage`: this firecracker build only accepts the uncompressed ELF/PVH kernel image, rejecting bzImage with "Invalid Elf magic number" at InstanceStart (confirmed in B4)
- [x] **B2 — Device 1 v0 image**
  - [x] `agent-vm/nix/device1-v0.nix`: squashfs containing `/init` (pid1-init binary) plus empty `/proc /sys /dev /tmp` - added in B3 once real mounting needed pre-existing targets on the read-only root (can't `mkdir` at runtime)
  - [x] Check derivation: `unsquashfs -l` lists exactly those six paths
- [x] **B3 — pid1-init v0 (mount + liveness)**
  - [x] `Mounter` trait + `SyscallMounter`/`FakeMounter`
  - [x] `mount_pseudo_filesystems()`: proc, sysfs, tmpfs - devtmpfs deliberately excluded: the kernel already auto-mounts it (`DEVTMPFS_MOUNT=y`) before init runs, and a second manual mount fails with EBUSY (confirmed by an actual boot in B4)
  - [x] Liveness line written to `/dev/console`, then park loop
  - [x] Unit tests against `FakeMounter`
- [x] **B4 — Python Firecracker launcher + boot proof**
  - [x] `firecracker.py`: `FirecrackerVM` (machine config, boot, console-log capture, `stop()`)
  - [x] `conftest.py`: `needs_kvm` marker + skip when `/dev/kvm` unusable
  - [x] `test_firecracker_boot.py`: boot, poll console log for liveness string, stop, assert clean exit
  - [x] Passes on this host

## Chunk C — vsock stdio + attach

- [ ] **C1 — pid1 vsock stdio listener + stub echo agent**
  - [ ] `ports.rs`: shared constants `STDIO_PORT`/`PROXY_PORT`/`BPF_PORT`
  - [ ] `bind_vsock_listener`, accept once, spawn `echo_agent` with stdio dup2'd via `Spawner` trait
  - [ ] `echo_agent` workspace member (echoes lines prefixed `"echo: "`)
  - [ ] Device1-v0 squashfs updated to include both binaries
  - [ ] Unit tests via `FakeSpawner` (assert wiring, no real vsock needed)
- [ ] **C2 — Host vsock handshake + persistent SessionManager connection**
  - [ ] `vsock_bridge.py`: `connect_guest_port` implementing `CONNECT <port>\n` / `OK` handshake
  - [ ] Unit tests incl. malformed-reply failure case, against fake UDS server
  - [ ] `ports.py` mirrors Rust port constants
  - [ ] `session_manager.py`: `SessionManager` holds one persistent `stdio_sock`
  - [ ] `needs_kvm` integration test: write `hello`, read back `echo: hello`
- [ ] **C3 — terminal.jsonl recorder + attach/detach multiplexing**
  - [ ] Background reader tees `stdio_sock` traffic into `terminal.jsonl` (base64 payload) regardless of attach state
  - [ ] `attach.sock` local Unix socket; fan-out to N connected clients
  - [ ] Detach/disconnect never touches `stdio_sock` or other clients
  - [ ] Unit tests with fake sockets: fan-out, logging, disconnect isolation
  - [ ] `needs_kvm` integration test: two attach clients, disconnect one, other keeps working, transcript correct

## Chunk D — Host git mirror & service

- [ ] **D1 — Mirror manager**
  - [ ] `git_mirror.py`: `ensure_mirror` (`clone --mirror` / `fetch --prune`)
  - [ ] Unit tests: fresh clone, re-fetch picks up new upstream commit, failure surfaces git stderr in message
- [ ] **D2 — git-http-backend wrapper service**
  - [ ] `git_service.py`: `GitHttpBackendServer` on `127.0.0.1:<port>`, custom CGI wrapper around `git http-backend`
  - [ ] Upload-pack only; `service=git-receive-pack` → 403 without spawning git
  - [ ] Test: real `git clone` over HTTP succeeds; receive-pack query rejected with no git subprocess spawned
- [ ] **D3 — Access log + path-based receive-pack rejection**
  - [ ] `git-access.jsonl`: every request logged (allowed/rejected + reason)
  - [ ] Reject any path containing `git-receive-pack`, independent of query-param check
  - [ ] Unit tests: path-based rejection has distinct reason; D2's requests each produce a matching log line
- [ ] **D4 — `prepare_repo()`**
  - [ ] `ensure_mirror` + verify commit exists (`git cat-file -e`) → `ResolvedRepo`
  - [ ] Unit tests: happy path; not-found error names the offending sha, no silent fallback

## Chunk E — Block devices & workspace

- [ ] **E1 — Device 3 (writable overlay) builder**
  - [ ] `build_writable_overlay`: `truncate` + `mkfs.ext4 -F`
  - [ ] `needs_root` loop-mount test + a permission-independent ext4-magic-number test
- [ ] **E2 — Device 2 (workspace) builder**
  - [ ] `build_workspace_image`: `clone --depth 1 --no-checkout` → `fetch --depth 1 <sha>` → `checkout <sha>` → `mksquashfs`
  - [ ] Integration test: two-commit fixture repo, `unsquashfs -l` correctness, pinned-commit-only content, `.git/config` origin URL check
- [ ] **E3 — pid1 overlayfs mount of device2+device3**
  - [ ] `mount_block_device` via `Mounter` trait
  - [ ] `build_overlay_options` pure function + unit test (exact `lowerdir=/upperdir=/workdir=` string)
  - [ ] `assemble_workspace()` wired into `main()` after pseudo-fs mount
  - [ ] `FakeMounter` test asserting mount order/fstypes/flags
  - [ ] `needs_kvm` integration test: 3-drive VM, `echo_agent` `write:` command lands file under `/workspace`
- [ ] **E4 — Result diff extraction**
  - [ ] `extract_diff`: loop-mount device3, interpret overlayfs whiteouts (char dev 0/0), materialize unified diff vs pinned commit
  - [ ] Unit tests on synthetic upperdir fixtures: modified file, added file, whiteout-deleted file
  - [ ] `needs_kvm` integration test extending E3: diff shows the written file as added

## Chunk F — Network egress

- [ ] **F1 — mitmproxy CA generation/persistence**
  - [ ] `mitm_ca.py`: `ensure_ca` (idempotent, via mitmproxy's `CertStore` API, stored under `/persistent`)
  - [ ] Unit test: second call doesn't regenerate (same file/mtime)
- [ ] **F2 — Allowlist addon**
  - [ ] `allowlist.py`: deny-by-default `request()` hook; `domain` and exact-`loopback` entry kinds
  - [ ] SSRF guard: any other loopback address/private range denied even if unlisted
  - [ ] `deny_paths_containing` rule support per entry
  - [ ] Unit tests (`tflow`/`taddons`): allow domain, deny domain, allow loopback port, deny other loopback port, deny private range, deny `git-receive-pack` path to allowlisted loopback entry
- [ ] **F3 — Credential injection addon**
  - [ ] `credentials.py`: real key (read from host-local file, not env var) swapped into `Authorization` only for the exact Anthropic destination
  - [ ] Unit tests: matching destination rewritten; non-matching destination's header untouched
- [ ] **F4 — proxy.jsonl transcript addon**
  - [ ] `transcript.py`: summarized record per request, including denied ones (`status_code: null`)
  - [ ] Mandatory Authorization redaction on every record, allowed or denied
  - [ ] Unit tests: allowed record shape, denied record shape, secret value never present in serialized output
- [ ] **F5 — Guest vsock↔TCP shim**
  - [ ] pid1 spawns `socat` (`TCP-LISTEN` loopback → `VSOCK-CONNECT` host-CID:`PROXY_PORT`) before stdio accept
  - [ ] Static `socat` bundled into device1 image via `pkgsStatic.socat` (decided, see spec §12 — fall back to a custom shim only if this fails in practice)
  - [ ] Pure unit test of constructed argv
  - [ ] Integration test present (may be folded into F6/F8 — note where)
- [ ] **F6 — Host vsock↔mitmproxy bridge**
  - [ ] `serve_guest_connections`: bind `<uds_path>_<port>`, accept-loop, relay to mitmproxy's TCP listener
  - [ ] Unit tests: relay correctness via fake TCP echo server; concurrent connections not serialized
- [ ] **F7 — Wire git service into allowlist**
  - [ ] `build_allowlist()` helper: Anthropic entry + git-loopback entry (with `deny_paths_containing`)
  - [ ] Unit test: exactly two entries, correct shapes
- [ ] **F8 — Full egress end-to-end test**
  - [ ] Real `GitHttpBackendServer` + real mitmproxy (F2–F4 addons) + fake allowlisted HTTPS test server + F6 bridge + real VM w/ F5 shim + empty `resolv.conf`
  - [ ] `echo_agent` extended: `curl-allowed` / `curl-denied` / `git-fetch` / `dns-lookup`
  - [ ] Assertions: allowed succeeds; denied fails + logged; git-fetch succeeds; DNS lookup fails fast (no hang)

## Chunk G — eBPF monitoring

- [ ] **G1 — Exec tracing**
  - [ ] `exec.bpf.c` (`sched_process_exec` tracepoint) → ring buffer: pid/ppid/comm/argv
  - [ ] Loader polls ring buffer, prints JSONL to stdout
  - [ ] `needs_root`/`needs_bpf` marker infra added
  - [ ] Pure unit test of JSON serialization
  - [ ] Integration test: known marker binary's exec captured
- [ ] **G2 — Network syscall tracing**
  - [ ] `connect`/`sendto` tracing, dest address/port captured, `event_type: "network"`
  - [ ] Serialization unit test extended for this shape
  - [ ] Integration test: raw TCP connect to throwaway listener captured
- [ ] **G3 — File-open read/write tracing**
  - [ ] `open`/`openat` tracing with read/write mode classification from flags
  - [ ] Pure unit test of flag classification (incl. `O_RDWR|O_CREAT`)
  - [ ] Integration test: one read-only + one write-only open, both classified correctly
- [ ] **G4 — DNS attempt detection**
  - [ ] Port-53 connect/sendto → additional `dns_attempt` event
  - [ ] Pure unit test of port-53 classification
  - [ ] Integration test: UDP sendto to `127.0.0.1:53` captured as `dns_attempt`
- [ ] **G5 — Loader → vsock export, wired into pid1**
  - [ ] Loader connects to `AF_VSOCK` `BPF_PORT` instead of stdout
  - [ ] pid1 spawns loader after mounts, before privilege drop; binds listener for host `CONNECT`
  - [ ] Unit test (`FakeSpawner`): spawn ordering/argv
  - [ ] `needs_kvm`+`needs_root` integration test: exec event arrives over vsock
- [ ] **G6 — Host BPF receiver**
  - [ ] `bpf_receiver.py`: read NDJSON off vsock connection, append to `bpf.jsonl`
  - [ ] Unit test: correct line handling incl. a chunk split mid-line
  - [ ] `needs_kvm`+`needs_root` integration test via the receiver end-to-end

## Chunk H — Guest rootfs closure

- [ ] **H1 — Real minimal closure**
  - [ ] `device1.nix` via nixpkgs' `make-squashfs` helper (coreutils, bash, git, python3)
  - [ ] Check: `unsquashfs -l` contents; closure is self-contained (not host-store-referencing)
  - [ ] Independently ensure the pid1-init mount-point directories still exist in this image (`/proc /sys /dev /tmp` - see the cross-reference comment in the old `device1-v0.nix` and `pseudo_filesystem_mounts()` in `mount.rs`); this replaces device1-v0's hand-written `mkdir -p` list with no shared source of truth, so don't drop it silently
- [ ] **H2 — Claude Code CLI + placeholder credential + proxy env**
  - [ ] `allowUnfreePredicate` mirrored for `claude-code`
  - [ ] Placeholder credential file baked in at a fixed path
  - [ ] pid1 env-assembly function (`ANTHROPIC_API_KEY`, `HTTP_PROXY`, `HTTPS_PROXY`)
  - [ ] Unit test: pure env-assembly function
  - [ ] Build check: placeholder file content verified via `unsquashfs -cat`
- [ ] **H3 — Bake in mitmproxy CA**
  - [ ] `device1.nix` accepts CA path as build input, installs into trust store for every relevant client (curl/git/python `ssl`)
  - [ ] Build-time check: `openssl verify` a test leaf cert (signed by F1's CA) against the produced bundle
- [ ] **H4 — Per-tool proxy-honoring smoke test**
  - [ ] `needs_kvm`+`needs_root` integration test: real device1 + full F8 stack + G5 loader
  - [ ] `git ls-remote` and `curl` through proxy succeed and appear in `proxy.jsonl`
  - [ ] `bpf.jsonl` shows zero direct-connect network events bypassing the shim
- [ ] **H5 — Wire real Claude Code CLI as exec target**
  - [ ] pid1's final exec → real CLI binary, `cwd=/workspace`, H2 env vars
  - [ ] `FakeSpawner` unit test updated for new binary/cwd/env
  - [ ] Prior echo_agent-based integration tests updated/replaced (process starts, stdio reachable, `/workspace` visible)

## Chunk I — Orchestration (systemd units) + CLI

- [ ] **I1 — `units.py` + `session_meta.py` + `config.py`**
  - [ ] Pure functions rendering unit-file text for the five core per-session units: `agentvm-session-<id>.target`, `-vm.service` (jailer/firecracker), `-recv-proxy.service`, `-recv-bpf.service`, `-stdio.service`
  - [ ] `-vm.service`: `--cgroup-version 2`, `Delegate=yes`, `IPAddressDeny=any`, `RuntimeMaxSec=<timeout>`, `Restart=no`, `TimeoutStopSec=`/`KillMode=`, `BindsTo=`+`After=` the three helper units, `Requires=`+`After=` the two host-wide singletons
  - [ ] Helper units: `PartOf=` the vm unit, `Restart=no`
  - [ ] One fixed/shared jailer uid·gid for now (K5.2 hardens to per-session-unique); idle-watchdog timer/service deferred to K5.3
  - [ ] `session_meta.py`: write-once per-session metadata file (repo, commit, launch timestamp)
  - [ ] `config.py`: TOML host-wide config (`max_concurrent_sessions`, default resource sizing, default timeout), loaded fresh per CLI invocation, no caching
  - [ ] Unit tests: rendered unit text has expected directives for a fixture session; metadata round-trip; config defaults vs file override
- [ ] **I2 — `launch` CLI command**
  - [ ] `prepare_repo` (D4) → build device2/3 → write metadata (I1) → render+write unit files → one `systemctl start agentvm-session-<id>.target` call
  - [ ] Failure surfaces the failing unit's `systemctl status`/`journalctl` output, no retry (§13.1 atomicity)
  - [ ] Prints session_id, returns immediately, does not block for session duration
  - [ ] No concurrency cap yet (I6)
  - [ ] Unit test: pipeline step order via fakes/mocked `systemctl` calls
  - [ ] `needs_kvm`+`needs_root` integration test: launch against fixture repo, confirm target+sub-units active via real `systemctl`, VM reachable via C2/C3 stdio
- [ ] **I3 — `list` CLI command**
  - [ ] `systemctl list-units 'agentvm-session-*.target'` parsed + joined with each session's I1 metadata file
  - [ ] No daemon-crash reconciliation needed — systemd's own unit state is reality
  - [ ] Unit test: table formatting against fixture/mocked `systemctl` output + metadata files
- [ ] **I4 — `attach`/`detach` commands**
  - [ ] Connect directly to `<session_dir>/attach.sock` (path derived from session_id, no lookup round trip)
  - [ ] Same raw-tty passthrough + escape-sequence detection as originally scoped
  - [ ] Unit test: escape-sequence detection incl. split across reads
  - [ ] `needs_kvm` integration test: launch, attach, type a line, detach, session still running after
- [ ] **I5 — `stop` command**
  - [ ] `systemctl stop agentvm-session-<id>.target`, cascades through `BindsTo=` graph (I1)
  - [ ] Graceful-then-SIGKILL is declarative (`TimeoutStopSec=`/`KillMode=` in I1), not hand-rolled
  - [ ] `needs_kvm` integration test: launch, stop, firecracker process actually gone, `list` shows inactive
- [ ] **I6 — Concurrency cap**
  - [ ] `max_concurrent_sessions` (I1 config) enforced in `launch` (I2) by counting active `agentvm-session-*.target` units via `systemctl` before starting a new one
  - [ ] Rejects (no units created, nothing started, §13.3) at cap
  - [ ] Unit test: cap=1 + mocked `systemctl` showing one active target → launch refuses, I2 pipeline never invoked (spy-based); stopped/inactive targets don't count
- [ ] **I7 — `review`/`transcript` commands**
  - [ ] Read the session's on-disk transcript directory directly — no RPC, no daemon
  - [ ] `review` requires target inactive (checked via `systemctl is-active`), else clear error; calls E4's `extract_diff` locally, pipes to `delta`/`less`
  - [ ] `transcript`: prints jsonl paths + DuckDB one-liner
  - [ ] Unit tests: "must be stopped" guard; pager selection via fake `shutil.which`
  - [ ] `needs_kvm` integration test: launch → stop → review end-to-end
- [ ] **I8 — `doctor` subcommand skeleton**
  - [ ] Read-only, no side effects, independent of any session
  - [ ] cgroup version check (must report v2 per §2)
  - [ ] Host-wide singleton services (git-service, mitmproxy) active via `systemctl is-active`
  - [ ] Extended in K5.5 with hugepage-pool state + `spectre-meltdown-checker` output
  - [ ] Unit test: output formatting against fake/mocked `systemctl`/cgroup reads

## Chunk J — Transcript unification

- [ ] **J1 — Shared schema + retrofit**
  - [ ] `transcript_schema.py`: shared envelope `{timestamp, session_id, stream, event_type, payload}` + `write_event` helper
  - [ ] Retrofit C3 (terminal), F4 (proxy), G6 (bpf) writers onto it
  - [ ] Existing unit tests updated for new envelope; captured information unchanged
- [ ] **J2 — DuckDB cross-file query test**
  - [ ] Fixture jsonl files (via `write_event` or a real launch)
  - [ ] `duckdb` query across `*.jsonl`; assert row counts, and column presence/types

## Chunk K — Hardening & polish

- [ ] **K1 — Capability dropping**
  - [ ] `build_cap_drop_plan` pure function + `apply_cap_drop` (setuid + clear all capability sets)
  - [ ] Wired as the absolute last pid1 step before exec
  - [ ] Unit test: plan shape
  - [ ] `needs_kvm` integration test: `/proc/self/status` shows non-zero Uid, all-zero CapEff, over the stdio channel
- [ ] **K2 — Full hermetic end-to-end scenario test**
  - [ ] Deterministic stub agent (swappable via H5 build flag): reads + appends to a known file
  - [ ] Daemon started first as its own process, then driven purely through the CLI: `launch` → poll `list` until stopped → `review` (diff correct)
  - [ ] `terminal.jsonl`, `proxy.jsonl` (no disallowed destinations), `bpf.jsonl` (exec + write file_open events) all checked
  - [ ] Second `launch` while at concurrency cap (I7) is rejected
  - [ ] Low `timeout_seconds` session is auto-stopped by reaping (I6)
- [ ] **K3 — Runbook & §12 decision record**
  - [ ] `agent-vm/README.md`: image rebuild triggers, full CLI reference (incl. `daemon`/`reap`), transcript stream locations + DuckDB one-liner
  - [ ] Write the daemon's `systemd --user` unit (the one item spec §12 still lists as open)
  - [ ] "Decisions made" section covering every entry in spec §12's decisions log: git-http-backend wrapper, package-registry strategy (explicitly left deferred), kernel config fragment + vmlinux/bzImage + devtmpfs deviations, closure isolation mechanism, vsock shim choice, vsock crate choice (`nix`, not `vsock`), eBPF load privilege (root before cap-drop), daemon/RPC/concurrency/config-source decisions
  - [ ] Every runbook claim checked against actual final code, not the original plan
- [ ] **K4 — Hugepages** (per [firecracker's hugepages.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/hugepages.md))
  - [x] Mode decided: `2M` (pre-allocated hugetlbfs pool), despite snapshotting being explicitly out of scope — chosen over `None`/`Transparent` regardless
  - [ ] Default guest RAM decided: **250 MiB** per session (`mem_size_mib`) — valid for `2M` mode (250 is a multiple of 2, i.e. 125 hugetlbfs pages, no leftover 4K fragment)
  - [ ] Host-side hugetlbfs pool sizing/allocation as part of launch prep: pool size = `250 MiB × max_concurrent_sessions` (I7); undersized pool causes erratic behavior/`SIGBUS`
  - [ ] Wire the chosen mode into `FirecrackerVM`'s `/machine-config` PUT (`huge_pages` field) alongside `vcpu_count`/`mem_size_mib`
  - [ ] Note interactions before picking a mode: `Transparent` doesn't work with UFFD during snapshot resume; `2M` requires UFFD and can't combine with file-backed restore; dirty-page tracking forces 4K granularity, negating the benefit either way - relevant only if snapshotting is ever added, otherwise not a blocker
  - [ ] `needs_kvm` integration/benchmark test: boot time with hugepages enabled vs `None`, on this host's fixture kernel/rootfs
- [ ] **K5 — Production host hardening** ([firecracker prod-host-setup.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/prod-host-setup.md))
  - [ ] Host kernel: `quiet loglevel=1` on the host's own boot cmdline (llm-host.nix), not the guest's; keep host kernel/microcode current via the normal NixOS update path
  - [ ] Firecracker invocation: never pass `--seccomp-filter`/`--no-seccomp` (keep the built-in default filters); add `8250.nr_uarts=0` to the *guest* kernel_args once the real agent (H5) no longer needs the console for liveness/debugging, or otherwise rate-limit/null-redirect console output in production
  - [ ] `terminal.jsonl`/`bpf.jsonl`/`proxy.jsonl` growth is bounded (rotation or size cap) rather than unbounded append-forever, per the "bounded storage for logs" recommendation
  - [ ] Host-side watchdog: kill the session after **10 minutes of no output activity on any channel** (terminal/proxy/bpf combined - not a per-channel independent timeout, and orthogonal to I6's total wall-clock session timeout). Minimal design, no new IPC: each stream's receiver (K5 growth-bounding item) already only writes its `.jsonl` file when real bytes arrive, so the file's mtime *is* the last-activity signal for free - receiver touches/creates its file immediately on startup (before any real byte) so "nothing yet" doesn't read as already-idle. A per-session `systemd.timer` (companion unit, `PartOf=` back to the VM unit so it never outlives the session) polls every ~60s: take `max(mtime)` across the three files, and if `now - max(mtime) > 600s`, `systemctl stop` one of the three receiver units - reuses the already-decided `BindsTo=` cascade (VM unit stops when any receiver stops) instead of inventing a separate "stop the VM" path. `needs_kvm` integration test: idle VM (no terminal/proxy/bpf traffic) gets stopped at the 10-minute mark; an active one doesn't
  - [ ] Jailer or equivalent: run firecracker chrooted under a dedicated non-privileged uid/gid per session (one unique uid/gid per concurrent VM), with `--exec-file`/`--chroot-base-dir`/`--netns` unwritable by unprivileged users
  - [ ] **OPEN QUESTION:** Resource limits per VM via cgroups/jailer: `blkio.throttle.io_serviced` + `io_service_bytes`, `memory.limit_in_bytes` (+ `memsw`/soft limit), `cpu.shares` + `cpu.cfs_period_us`/`cfs_quota_us`, jailer `fsize`/`no-file` - now that jailer runs under a systemd unit (K5 decision), these need mapping onto concrete unit directives (`MemoryMax=`, `CPUQuota=`, `IOWeight=`/`IOReadBandwidthMax=`, `Delegate=yes`) vs. left as jailer's own raw `--cgroup`/`--resource-limit` flags - undecided which authority owns which knob
  - [ ] KVM/host tuning: lower `kvm min_timer_period_us` (modprobe config), move `kvm-pit` kernel threads into each VM's cgroup, disable SMT or otherwise document the tenant-isolation tradeoff for this host, `kvm.nx_huge_pages=never` or cgroups `favordynmods` (kernel 6.1+) — interacts with K4: `nx_huge_pages` splitting can shatter the `2M`-mode EPT mappings for executable guest memory regardless of hugetlbfs backing, undermining the reason `2M` was picked
  - [ ] `min_timer_period_us` and `favordynmods` made explicit in host config (llm-host.nix), not just applied ad hoc: `boot.extraModprobeConfig` (or equivalent) for `options kvm min_timer_period_us=<N>`, and the cgroup v2 remount (`-o remount,favordynmods`) wired as a systemd unit/mount option rather than a manual one-off command
  - [ ] `kvm-pit` thread cgroup placement is **not automatic** — verified against current kernel source (`arch/x86/kvm/i8254.c`'s `kvm_create_pit()` calls `kthread_run_worker(0, "kvm-pit/%d", pid_nr)`; per `kernel/kthread.c`, every kthread is actually forked from the global `kthreadd` (PID 2) context via `create_kthread()`, not from the calling process — the `%d` in the name is just the creator's PID for human identification, not a real parent/cgroup relationship). systemd's `Delegate=yes` cannot reach it: delegation only covers processes forked from the unit's own tree, and `kvm-pit` never is one. Needs an `ExecStartPost=` script on the VM unit: locate the `kvm-pit/<tid>` task (scan `/proc/*/comm` for a TID under firecracker's own `/proc/<pid>/task/`), write its PID into the unit's delegated `cgroup.procs`. Two open risks to test, not assume: (a) timing — PIT creation is lazy (on first guest PIT access), so a single-shot poststart grep may race it; needs a short retry/poll rather than a one-off check; (b) whether a kernel-thread PID can be freely migrated via `cgroup.procs` on this kernel the way a normal process can (no blocking cgroup v2 doc text found either way — cgroup v1 had known quirks moving kthreads for some controllers). `needs_kvm`+`needs_root` integration test: boot a VM, confirm the poststart script finds and moves the thread, confirm via `cpu.stat`/`systemd-cgtop` that its CPU time now attributes to the VM's cgroup
  - [ ] **OPEN QUESTION:** Host memory: disable swap (or secure swap) so guest memory is never paged to disk; disable KSM to prevent cross-VM page-dedup side channels - not yet discussed at all against llm-host.nix's actual config (zram root, no swap partition currently defined)
  - [ ] Network egress hardening (builds on chunk F): **no TAP/virtio-net device exists in this design at all (spec §3)** — the earlier "rate-limit the guest's network interface, drop TAP traffic to IMDS" wording was generic Firecracker prod-host-setup.md advice that doesn't apply here and is corrected. All egress is vsock→host-UDS→mitmproxy (§5); there's no IP-layer path to `169.254.169.254` (or anywhere else) to block, since there's no network interface for the guest to route through. What still applies: (a) confine the firecracker+jailer systemd unit itself with `PrivateNetwork=yes`/`IPAddressDeny=any` — it has no legitimate network need, only a local vsock UDS; (b) rate-limiting the live proxied HTTP traffic (not the transcript logs, which K5's growth-bounding item already covers) has no Firecracker-API mechanism to lean on (verified: the `Vsock` device schema has no rate-limiter field, unlike `drives`/`network-interfaces`) — must happen in host software, e.g. the F6 relay loop or a mitmproxy addon, if wanted at all
  - [ ] Hardware vulnerability posture: `spectre-meltdown-checker` output is surfaced through the new `agentvm doctor` subcommand (spec §10.1), not just a one-off manual run; K3 runbook still records the baseline result and vendor-specific (Intel/AMD) mitigation guidance to revisit on host CPU changes
  - [ ] Explicitly out of scope for a single-operator host (record in K3's decision log rather than implementing): per-instance uid/gid *fleet* management beyond what one concurrent-session cap needs, and the ARM-only `KVM_CAP_COUNTER_OFFSET` check (this host is x86_64)
