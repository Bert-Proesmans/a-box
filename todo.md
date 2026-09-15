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
- [ ] I — Orchestration CLI
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
  - [x] Non-modular (built-in only) kernel build - `MODULES` left "y" (nixpkgs' generic kernel builder hardcodes that assumption into its install phase with no override point) but no driver is ever built as `m`, so nothing needs loading and no initrd is used
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
  - [ ] Static `socat` bundled into device1 image (or caveat noted for chunk H)
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

## Chunk I — Orchestration CLI

- [ ] **I1 — SessionConfig + SessionRegistry**
  - [ ] Dataclass + validation (repo/commit non-empty, positive resource values)
  - [ ] JSON-file-backed registry: `create`/`update`/`get`/`list_all`
  - [ ] Unit tests: validation rejects bad config; round-trip; concurrent updates reflected
- [ ] **I2 — `launch` command**
  - [ ] `LaunchOrchestrator`: registry create → `prepare_repo` → build device2/3 → ensure git-service+mitmproxy singletons → boot VM → start SessionManager/bridge/receiver → mark running
  - [ ] Every subsystem dependency-injected for testability
  - [ ] Unit test: step ordering via fakes; failure path leaves registry "failed", not "running"
  - [ ] `needs_kvm` integration test: full launch against fixture repo, observable via stdio
- [ ] **I3 — `list` command**
  - [ ] Registry enumeration + Firecracker instance-info reconciliation (crash recovery)
  - [ ] Table formatting
  - [ ] Unit tests: reconciliation corrects stale "running"; formatting tested independently
- [ ] **I4 — `attach`/`detach` commands**
  - [ ] Raw-tty passthrough to `attach.sock`; fixed escape sequence to detach
  - [ ] Unit test: escape-sequence detection incl. split across reads
  - [ ] `needs_kvm` integration test: attach, type, see response; detach doesn't disturb session
- [ ] **I5 — `stop` command**
  - [ ] Graceful stop → timeout → SIGKILL fallback; registry update; teardown of SessionManager/bridges/receiver
  - [ ] Unit test: force-kill path taken after timeout, registry still correct
  - [ ] `needs_kvm` integration test: process actually gone; `list` reflects "stopped"
- [ ] **I6 — Timeout enforcement**
  - [ ] `reap_overdue_sessions` with injectable clock; stops overdue sessions with reason "timeout"
  - [ ] Wired to run at the top of every CLI invocation
  - [ ] Standalone `agentvm reap` entrypoint for a systemd timer
  - [ ] Unit tests: overdue vs within-deadline via fake clock
- [ ] **I7 — Concurrency cap**
  - [ ] `max_concurrent_sessions` config, enforced in `launch` after reaping runs
  - [ ] Rejects without creating a registry entry or starting any subsystem when at cap
  - [ ] Unit tests: cap enforcement via spies; stopped/failed sessions excluded from the count
- [ ] **I8 — `review` and `transcript` commands**
  - [ ] `review`: require stopped/failed, `extract_diff`, pipe to `delta`/`less`
  - [ ] `transcript`: print jsonl paths + example DuckDB command
  - [ ] Unit tests: "must be stopped" guard; pager selection via fake `shutil.which`
  - [ ] `needs_kvm` integration test: launch → stop → review shows expected diff

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
  - [ ] Driven purely through the CLI: `launch` → poll `list` until stopped → `review` (diff correct)
  - [ ] `terminal.jsonl`, `proxy.jsonl` (no disallowed destinations), `bpf.jsonl` (exec + write file_open events) all checked
  - [ ] Second `launch` while at concurrency cap (I7) is rejected
  - [ ] Low `timeout_seconds` session is auto-stopped by reaping (I6)
- [ ] **K3 — Runbook & §12 decision record**
  - [ ] `agent-vm/README.md`: image rebuild triggers, full CLI reference, transcript stream locations + DuckDB one-liner
  - [ ] "Decisions made" section: git-http-backend wrapper, package-registry strategy (explicitly left deferred), kernel config fragment, closure isolation mechanism, vsock shim choice
  - [ ] Every runbook claim checked against actual final code, not the original plan
