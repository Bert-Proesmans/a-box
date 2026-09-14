# Isolated LLM Code-Agent VM Host — Implementation Blueprint & Prompt Plan

This document turns `docs/agent-vm-host-spec.md` into an executable, test-driven
build plan. It has four parts:

1. **Blueprint** — the end-to-end build order and why it's sequenced that way.
2. **Chunks** — coarse phases (A–K), each an independently reviewable slice.
3. **Steps** — each chunk broken into right-sized, testable units of work.
4. **Prompts** — one code-generation prompt per step, in order, meant to be
   fed to a coding LLM one at a time. Every prompt states what already exists,
   what to build, and how to wire it into prior work — nothing is left
   dangling or un-integrated.

Decisions the spec left open (§12) are pinned down explicitly where a step
depends on them, and called out as such.

---

## 1. Blueprint

The system has five largely independent subsystems (guest kernel+pid1, eBPF,
host network/proxy, host git service, host orchestration) that all converge
on one artifact: a bootable Firecracker microVM. Building them in isolation
first and integrating a "walking skeleton" early avoids the two failure modes
big-bang integration produces: (a) nothing runnable until everything is done,
and (b) huge, non-debuggable steps that mix a new kernel, a new Rust binary,
and new host code all at once.

Build order:

1. **Scaffolding (A)** — toolchains for Rust/musl, C/libbpf, Python, Nix
   build plumbing, so every later step has somewhere to compile/test into.
2. **Firecracker walking skeleton (B)** — the smallest possible kernel + pid1
   + Python launcher that boots a VM and proves the host can observe it
   (console log). Every later guest feature is added to this one binary.
3. **vsock stdio channel (C)** — the interactive terminal path, because it's
   the cheapest way to *observe* every later guest change from the host
   without re-parsing kernel console logs.
4. **Host git mirror & service (D)** — needed before workspace images can be
   built (E depends on it), and is host-only so it can be built/tested
   without touching the VM at all.
5. **Block devices & workspace (E)** — device 2/3 image builders, guest-side
   overlayfs mount, and result extraction. This is the first point the VM
   does something resembling real work.
6. **Network egress (F)** — vsock↔TCP shim, mitmproxy allowlist, credential
   injection, host-side vsock bridge. The riskiest subsystem (it's the actual
   security boundary for exfiltration), so it gets the most granular steps
   and a dedicated end-to-end test.
7. **eBPF monitoring (G)** — independent of F functionally, sequenced after
   it because G's own end-to-end test is more useful once there's real guest
   network activity (from F) to observe.
8. **Guest rootfs closure (H)** — only now do we build the *real* Device 1
   (Claude Code CLI, tool allowlist, mitmproxy CA baked in from F). Building
   it last means it can be validated against a fully working proxy/BPF stack
   instead of a stub.
9. **Session orchestration CLI (I)** — the Python glue (`launch`/`list`/
   `attach`/`stop`/`review`) that wires B–H into the one command surface
   §10 requires.
10. **Transcript unification (J)** — retrofits the three independently-built
    writers (terminal/proxy/bpf) onto one shared schema, then proves the
    DuckDB/SQLite queryability requirement (§11) against a real session.
11. **Hardening & polish (K)** — capability dropping (§8), one full hermetic
    end-to-end scenario test exercising every subsystem together, and the
    written record of every §12 decision actually made.

## 2. Chunk map

| Chunk | Name | Depends on | Produces |
|---|---|---|---|
| A | Scaffolding | — | devShell, build skeletons for Rust/C/Python |
| B | Firecracker walking skeleton | A | booting VM, minimal kernel, pid1 v0 |
| C | vsock stdio + attach | B | interactive channel, terminal.jsonl |
| D | Host git mirror & service | A | local mirror manager, git-http-backend service |
| E | Block devices & workspace | B, D | device2/3 builders, overlay mount, diff extraction |
| F | Network egress | C, D, E | proxy shim, mitmproxy addons, host bridge |
| G | eBPF monitoring | B | BPF programs, loader, host receiver |
| H | Guest rootfs closure | F, G | real Device 1, CA bake-in, real agent exec target |
| I | Orchestration CLI | E, F, G, H | `launch`/`list`/`attach`/`stop`/`review` |
| J | Transcript unification | C, F, G, I | shared schema, DuckDB validation |
| K | Hardening & polish | everything | cap-drop, full E2E test, docs |

Steps within a chunk are numbered `<Chunk><n>`, e.g. `E3`. Each step below
maps 1:1 to one prompt in Part 4.

---

## 3. Right-sized steps

### Chunk A — Scaffolding
- **A1** Devshell/build environment: Rust musl target, clang+libbpf+bpftool, Python+pytest, firecracker binary, all pinned via the existing `lon` source mechanism.
- **A2** Python package skeleton with a `--version` CLI entrypoint and a Nix derivation packaging it.
- **A3** Rust workspace skeleton for pid1-init, cross-compiled static-musl, with a placeholder unit test and a Nix build.
- **A4** C/libbpf skeleton (Makefile + Nix derivation) producing a no-op CO-RE object and loader that exits 0.

### Chunk B — Firecracker walking skeleton
- **B1** Minimal guest kernel Nix build (virtio-blk, virtio-vsock, devtmpfs, tmpfs, overlay, squashfs, BPF configs).
- **B2** Device 1 image v0: squashfs containing only the pid1 binary as `/init`.
- **B3** pid1 v0: mount pseudo-filesystems, write a liveness line to the UART console, park.
- **B4** Python Firecracker launcher: assemble machine config, boot, capture console log to a file, assert liveness line, stop. Marked as a KVM-requiring integration test.

### Chunk C — vsock stdio + attach
- **C1** pid1: open an AF_VSOCK listener on the stdio port, accept once, exec a stub echo binary with stdio wired to that connection.
- **C2** Host session-manager: makes the one persistent host→guest vsock connection (via the Firecracker vsock UDS `CONNECT <port>\n` handshake) at VM start and keeps it open for the VM's lifetime, independent of any CLI attach.
- **C3** `terminal.jsonl` recorder tee'd onto C2's persistent connection, plus a local attach/detach Unix socket the CLI can connect to without disturbing the primary connection.

### Chunk D — Host git mirror & service
- **D1** Mirror manager: `ensure_mirror`/`sync_mirror` (clone --mirror if absent, else fetch --prune), tested against local `file://` repos.
- **D2** git-http-backend wrapper service bound to `127.0.0.1:<GIT_PORT>`, upload-pack only (decision: small custom `http.server` wrapper invoking `git http-backend` as CGI, not a general web server — fewer moving parts, easy to unit test).
- **D3** Defense-in-depth: reject any request path containing `git-receive-pack`, plus an access-log file for git requests.
- **D4** `prepare_repo(session)`: syncs the mirror and resolves the pinned commit, called once per launch, erroring loudly if the commit isn't reachable after sync.

### Chunk E — Block devices & workspace
- **E1** Device 3 builder: empty ext4 image of configurable size.
- **E2** Device 2 builder: shallow clone of the pinned commit from D2's service, packaged into a squashfs image (decision: squashfs over erofs — more mature tooling).
- **E3** pid1: mount device 2 (ro) + device 3 (rw) via overlayfs at `/workspace`.
- **E4** Result extraction: loop-mount device 3 post-session, resolve overlayfs whiteouts, and materialize a unified diff against the pinned commit.

### Chunk F — Network egress
- **F1** mitmproxy CA generation/persistence, idempotent, stored under `/persistent`.
- **F2** Allowlist addon: deny-by-default, domain entries, exact loopback entries, SSRF guard against other loopback/private ranges.
- **F3** Credential-injection addon: real Anthropic key swapped in only for the allowlisted Anthropic destination.
- **F4** `proxy.jsonl` transcript addon with mandatory Authorization redaction.
- **F5** Guest vsock↔TCP shim: pid1 spawns it as a background child before privilege drop.
- **F6** Host vsock↔mitmproxy bridge: accept-loop on the guest-initiated per-port UDS, relay to mitmproxy's TCP listener, supporting concurrent connections.
- **F7** Wire D2's git service into F2's allowlist as the loopback exception.
- **F8** Full egress end-to-end test: allowed domain succeeds, disallowed domain blocked+logged, git fetch through the loopback entry succeeds, DNS lookup fails fast.

### Chunk G — eBPF monitoring
- **G1** BPF program v1: exec tracing + loader emitting JSONL to stdout.
- **G2** Add connect/sendto tracing.
- **G3** Add file-open read/write-mode tracing.
- **G4** Add DNS-attempt detection (connect to port 53).
- **G5** Loader output redirected to the BPF vsock port; pid1 invokes it as a privileged setup step before dropping capabilities.
- **G6** Host BPF receiver: accept-loop, append-only `bpf.jsonl` writer.

### Chunk H — Guest rootfs closure
- **H1** Minimal self-contained closure (coreutils/bash/git/python3) via nixpkgs' squashfs-from-closure machinery; build-and-inspect test.
- **H2** Add Claude Code CLI + placeholder credential file + proxy env wiring.
- **H3** Bake F1's mitmproxy CA into the image trust store at build time; verified by a build-time cert-verification check.
- **H4** Per-tool proxy-honoring smoke test (git, curl, pip) using G's connect-tracing to catch any direct-connect fallback.
- **H5** Wire pid1's final `exec` to the real Claude Code CLI (replacing C1's stub), cwd `/workspace`, full env.

### Chunk I — Orchestration CLI
- **I1** `SessionConfig` model + on-disk registry.
- **I2** `launch`: wires D4→E2→E1→VM boot→C2/F6/G6 bridges→registry entry.
- **I3** `list`: registry + live Firecracker status probe.
- **I4** `attach`/`detach` CLI wrapper around C3's local socket.
- **I5** `stop`: graceful + force-kill fallback, registry update.
- **I6** Timeout enforcement (checked on every CLI invocation, plus a standalone reaper entrypoint for systemd-timer use).
- **I7** Concurrency cap enforced in `launch`.
- **I8** `review`: diff (E4) piped to `delta`/`less`, plus transcript path listing.

### Chunk J — Transcript unification
- **J1** Shared schema module; retrofit C3/F4/G6 to emit through it.
- **J2** DuckDB cross-file query integration test.

### Chunk K — Hardening & polish
- **K1** Capability dropping as pid1's final pre-exec step.
- **K2** Full hermetic end-to-end scenario test across every chunk.
- **K3** Runbook + written record of every §12 decision made.

That's 51 steps across 11 chunks — each independently testable, each no
larger than "one new capability wired into what already exists."

---

## 4. Prompts

Feed these to a code-generation LLM **in order**. Each assumes everything
from earlier prompts already exists and is merged. Write the failing test
first where the prompt says so, then the implementation, then confirm green.

### Chunk A — Scaffolding

#### A1

```text
We're starting a new subsystem in this NixOS repo (see docs/agent-vm-host-spec.md
and docs/agent-vm-host-plan.md for full context) that builds an isolated
Firecracker microVM host for running Claude Code agent sessions. This repo
already uses "lon" (lon.nix/lon.lock) for pinned sources — follow that
pattern for any new pinned input rather than introducing flakes or niv.

Create the initial directory layout for this subsystem under a new top-level
directory `agent-vm/`:
  agent-vm/
    host/        (Python orchestration package, later chunks)
    guest/       (Rust pid1-init, later chunks)
    bpf/         (C/libbpf programs, later chunks)
    nix/         (shared Nix build helpers)

Add `agent-vm/nix/devshell.nix` producing a `pkgs.mkShell` with: a Rust
toolchain targeting `x86_64-unknown-linux-musl` (use the nixpkgs-provided
musl target, not rustup), `clang`, `libbpf`, `bpftool`, `python3` with
`pytest` and `mypy`, and the `firecracker` package. Wire it into
`llm-host.nix`'s sources or a new small `agent-vm/nix/default.nix` that can
be `nix-build`'d standalone via `lon`'s existing `sources` mechanism —
do not modify the running host module (`llm-host.nix`'s `system`) yet.

Add a short `agent-vm/README.md` (one paragraph) pointing at the two docs
files. No application code yet. Verify with `nix-build agent-vm/nix -A
devshell` (or equivalent) that the shell evaluates.
```

#### A2

```text
Building on agent-vm/ from A1. Create the Python package skeleton at
agent-vm/host/:
  pyproject.toml (package name `agentvm`, pytest as dev dependency)
  src/agentvm/__init__.py (exposes __version__ = "0.0.1")
  src/agentvm/cli.py (argparse or click — pick click; a single `--version`
    flag that prints agentvm.__version__ and exits 0)
  tests/test_cli.py (invokes the CLI via subprocess or click's CliRunner,
    asserts the version string is printed)

Add a Nix derivation `agent-vm/nix/host-package.nix` that packages this with
`pkgs.python3Packages.buildPythonApplication`, producing an `agentvm`
executable. Add it to the devshell from A1 so `agentvm --version` works
inside the shell.

Write the test first, confirm it fails (no cli.py yet), then implement.
Run `pytest agent-vm/host` and confirm green. Do not add any other
subcommands yet — later chunks add `launch`/`list`/`attach`/`stop`/`review`
one at a time.
```

#### A3

```text
Building on agent-vm/ from A1/A2. Create a Rust workspace at agent-vm/guest/
for the pid1-init binary:
  Cargo.toml (workspace, one member `pid1-init`)
  pid1-init/Cargo.toml (binary crate, `#![no_std]` is NOT required — we're
    targeting musl userspace, not embedded; keep std)
  pid1-init/src/main.rs — for now, just `fn main() { println!("pid1-init
    placeholder"); }`
  pid1-init/src/lib.rs — empty, will hold testable logic (mount-option
    builders, etc.) as later chunks add it, since `main.rs` itself is hard
    to unit test.
  pid1-init/tests/placeholder.rs — one trivial `#[test]` asserting
    `1 + 1 == 2`, just to prove the test harness is wired, to be replaced by
    real tests in B3.

Add `agent-vm/nix/guest-init.nix`: a Nix derivation building this crate
statically for `x86_64-unknown-linux-musl` (use `pkgsStatic` or the
`rustPlatform` pattern nixpkgs uses for musl static binaries — confirm with
`file` on the output that it's statically linked, no dynamic interpreter).
Add it to the devshell. Run `cargo test --workspace` from within the
devshell and confirm the placeholder test passes.
```

#### A4

```text
Building on agent-vm/ from A1. Create the C/libbpf skeleton at agent-vm/bpf/:
  Makefile — compiles bpf/progs/noop.bpf.c (a CO-RE skeleton with zero
    programs attached, just valid BPF object headers) via clang -target bpf,
    and bpf/loader/main.c (a libbpf-based loader that opens/loads the object
    and immediately exits 0 — no attach yet).
  bpf/progs/noop.bpf.c — minimal valid libbpf CO-RE source (license section +
    one unused map or similar so it compiles) — this is scaffolding only,
    real programs come in chunk G.
  bpf/loader/main.c — uses libbpf's skeleton-header pattern (`bpftool
    gen skeleton`) to open+load noop.bpf.c's compiled object, then exit 0.

Add `agent-vm/nix/bpf.nix`: a Nix derivation invoking this Makefile with
clang/libbpf/bpftool from nixpkgs, producing the loader binary. Add it to
the devshell. Verify by running the built loader binary directly (may need
CAP_BPF/root — if the sandbox can't load BPF objects, at minimum verify the
build succeeds and `file` shows a valid ELF; note in a comment that the
load-time check needs root and defer full verification to chunk G's tests).
```

### Chunk B — Firecracker walking skeleton

#### B1

```text
Building on agent-vm/ scaffolding (A1-A4). We need a minimal guest kernel for
the microVMs described in docs/agent-vm-host-spec.md §3/§9/§12. Create
agent-vm/nix/guest-kernel.nix: a Nix derivation building a Linux kernel
(pin a specific LTS version consistent with whatever nixpkgs revision `lon`
already provides) with a config fragment enabling exactly: VIRTIO_BLK,
VIRTIO_VSOCKETS (+ VSOCKETS), DEVTMPFS (+ DEVTMPFS_MOUNT), TMPFS, OVERLAY_FS,
SQUASHFS, BPF + BPF_SYSCALL + kprobes/tracepoints support (KPROBES,
BPF_EVENTS), and PROC_FS/SYSFS. Disable modules (built-in only, since there's
no initrd to load them from) — set the config to a minimal non-modular
kernel. Use nixpkgs' `buildLinux`/kernel config-fragment mechanism, not a
hand-rolled kbuild invocation.

Produce a `bzImage` output. Add a check: a small derivation or shell script
that runs the built kernel's `make kernelrelease`-equivalent check, or at
minimum asserts the bzImage file exists and is non-empty and that `file`
reports it as a Linux kernel x86 boot executable. Add to the devshell as a
buildable attribute. This step has no VM boot test yet — that's B4.
```

#### B2

```text
Building on A3 (pid1-init crate) and B1 (kernel). Create
agent-vm/nix/device1-v0.nix: a Nix derivation that takes the pid1-init
static binary from A3 and packages a squashfs image containing exactly one
file, `/init`, being that binary (mode 0755). Use `mksquashfs` via nixpkgs.
This is the throwaway "Device 1 v0" used only to prove the boot path works;
chunk H replaces it with the real, full closure.

Add a small check derivation that runs `unsquashfs -l` on the output and
asserts the listing is exactly `/` and `/init`. No VM boot yet.
```

#### B3

```text
Building on A3's pid1-init crate. Implement pid1-init v0 in
agent-vm/guest/pid1-init/src/main.rs (delegate logic to lib.rs functions so
they're unit-testable without needing to actually be pid1):

1. A `mount_pseudo_filesystems()` function in lib.rs that mounts (using the
   `nix` crate's `mount()` wrapper — add it as a dependency) proc at /proc,
   sysfs at /sys, devtmpfs at /dev, and a tmpfs at /tmp. Structure it so the
   actual mount syscalls go through a small trait (e.g. `trait Mounter { fn
   mount(&self, ...) -> io::Result<()>; }`) with a real `SyscallMounter` and
   a `FakeMounter` used in tests, so you can unit-test "did we attempt to
   mount proc/sysfs/devtmpfs/tmpfs in the right order with the right flags"
   without needing actual mount capability in the test process.
2. `main()` calls `mount_pseudo_filesystems()`, then writes a single fixed
   liveness line (e.g. "pid1-init: alive\n") to `/dev/console` (open it
   directly — there's no libc buffering concern to worry about at this
   stage), then parks forever (loop { sleep }).

Write unit tests against `FakeMounter` first (assert the four expected mount
calls happen with expected source/target/fstype/flags), confirm they fail
against a stub, then implement. `cargo test` must pass without root. Update
B2's device1-v0.nix build to use this real main.rs (it already does, since
it just packages the crate's binary — no Nix change needed unless the
binary's build inputs changed).
```

#### B4

```text
Building on B1 (kernel), B2 (device1-v0 squashfs), B3 (pid1-init liveness).
In agent-vm/host/src/agentvm/, add a `firecracker.py` module with a minimal
`FirecrackerVM` class that:
  - Writes a Firecracker machine-config JSON (boot-source = B1's bzImage
    with kernel args `console=ttyS0 root=/dev/vda ro init=/init`, one drive
    pointing at B2's squashfs image as read-only root, minimal vcpu/mem).
  - Starts the `firecracker` binary against a fresh API unix socket, POSTs
    the config via its REST API (use `requests` with a Unix-socket adapter,
    or `httpx` with a custom transport — pick `requests` +
    `requests_unixsocket`-style adapter for simplicity), starts the
    instance, and redirects/captures the VM's console (UART) output to a
    per-call log file.
  - `stop()` sends the appropriate Firecracker action (SendCtrlAltDel or
    process termination) and waits for exit.

Add `agent-vm/host/tests/test_firecracker_boot.py`, marked with a pytest
marker `@pytest.mark.needs_kvm` (add a `conftest.py` that skips this marker
when `/dev/kvm` is absent or unreadable). The test: boot a VM with B2's
image, poll the console log file for up to N seconds for the exact string
"pid1-init: alive", assert found, then stop the VM and assert the process
exits. Run it on this host (which has kvm-amd/kvm-intel per llm-host.nix) and
confirm it passes.
```

### Chunk C — vsock stdio + attach

#### C1

```text
Building on B3's pid1-init and B4's boot harness. Extend pid1-init:

1. In lib.rs, add `bind_vsock_listener(port: u32) -> io::Result<VsockListener>`
   using the `vsock` crate (add as dependency) or raw AF_VSOCK syscalls via
   `nix` if the crate is unsuitable in a musl-static build — verify which
   compiles cleanly under the musl target and use that. Pick a fixed
   constant port for stdio (document it in a `ports.rs` module shared by
   later chunks, e.g. STDIO_PORT = 10000, PROXY_PORT = 10001, BPF_PORT =
   10002 — later chunks will reuse these constants).
2. `main()` now: mounts pseudo-fs (B3), binds the stdio vsock listener,
   accepts exactly one connection (blocking), then spawns a stub "agent"
   process with stdin/stdout/stderr dup2'd onto that connection's fd. For
   this step the stub agent is `/bin/echo_agent`, a tiny second binary in
   the same Cargo workspace (add it as a second workspace member) that
   just echoes each line it reads on stdin back to stdout prefixed with
   "echo: ". Package both binaries into device1-v0's squashfs (update
   B2's Nix derivation to include both `/init` and `/bin/echo_agent`).

Unit-test the listener/accept/spawn wiring using a fake "Spawner" trait
(same pattern as B3's Mounter) so you can assert "spawn was called with
stdio wired to the given fd" without a real vsock connection. Leave the
real end-to-end proof (host connecting and seeing the echo) to C2.
```

#### C2

```text
Building on C1. Firecracker exposes vsock to the host as a Unix domain
socket at a configured `uds_path`. Host-initiated connections: connect to
`uds_path`, write `CONNECT <port>\n`, read back `OK <assigned_port>\n`, then
the socket carries raw bytes to/from whatever the guest has AF_VSOCK-bound
on that port. (This is different from guest-initiated connections, which
appear on `<uds_path>_<port>` — later chunks F/G use that direction; this
step only needs the host-initiated direction.)

In agent-vm/host/src/agentvm/, add `vsock_bridge.py` with a function
`connect_guest_port(uds_path: str, port: int, timeout: float) -> socket.socket`
implementing that handshake, raising a clear exception on a malformed/failed
handshake reply. Unit-test it against a fake Unix-socket server (spun up in
the test via `socketserver`/raw `socket` in a background thread) that
scripts the `CONNECT`/`OK` exchange, including a test for the failure case
(server replies something else).

Then add `session_manager.py` with a `SessionManager` class that, given a VM
handle (from B4's `FirecrackerVM`) and its vsock `uds_path`, calls
`connect_guest_port` for the stdio port (C1's STDIO_PORT constant — mirror
it as a Python constant in a small shared `ports.py` so guest and host agree)
immediately after the VM reports running, and holds the resulting socket
open for the manager's lifetime (store it as `self.stdio_sock`).

Add an integration test (`@pytest.mark.needs_kvm`) that boots the C1 image,
constructs a SessionManager, writes b"hello\n" to `stdio_sock`, and asserts
it reads back b"echo: hello\n".
```

#### C3

```text
Building on C2's SessionManager. Two things must be true per
docs/agent-vm-host-spec.md §11 and §10: every byte on the stdio channel is
recorded to `terminal.jsonl` from the moment the session starts (not only
while a client is attached), and `attach`/`detach` must not kill or disturb
the underlying session.

1. In `session_manager.py`, add a background reader thread/task on
   `stdio_sock` that, for every chunk read, appends one JSON line to
   `<session_dir>/terminal.jsonl` with at least `{timestamp, session_id,
   stream: "terminal", direction: "guest_to_host", payload: <base64 or
   utf8-with-replacement>}` — pick base64 to be encoding-agnostic, note this
   choice in a comment. (Full schema unification happens in chunk J — this
   is a local, good-enough schema for now.)
2. Add a local Unix socket (`<session_dir>/attach.sock`) that
   SessionManager listens on. Any bytes a connected attach client sends are
   forwarded to `stdio_sock` (and logged as `direction: "host_to_guest"`);
   any bytes read from `stdio_sock` are forwarded to *all* currently
   connected attach clients (zero or more) as well as written to
   terminal.jsonl. Disconnecting an attach client must not affect
   `stdio_sock` or the recorder.

Unit-test the tee/multiplex logic with fake sockets (no real vsock or KVM
needed): one fake `stdio_sock`-like object, N fake attach-client sockets,
assert fan-out and logging both happen and that closing an attach client
doesn't close `stdio_sock`. Add one `@pytest.mark.needs_kvm` integration
test: boot C1's image, start SessionManager, connect two attach clients,
send from one, assert both receive the echo, disconnect one, assert the
other keeps working and `terminal.jsonl` has the expected lines.
```

### Chunk D — Host git mirror & service

#### D1

```text
This chunk is host-only Python, independent of the VM work so far — no KVM
needed for any test here. In agent-vm/host/src/agentvm/, add `git_mirror.py`:

`ensure_mirror(repo_url: str, mirror_path: Path) -> None`: if `mirror_path`
doesn't exist, `git clone --mirror <repo_url> <mirror_path>`; if it exists,
`git --git-dir=<mirror_path> fetch --prune origin '+refs/*:refs/*'`. Raise a
clear exception (with captured stderr) on any git failure.

Unit-test against real local repos using `git init --bare`/`git init` +
`file://` URLs created in a pytest tmp_path fixture (no network needed):
  - cloning a fresh mirror from a local repo with one commit.
  - re-running ensure_mirror after a new commit lands upstream, and
    asserting the mirror now has that commit (`git --git-dir=... cat-file
    -e <sha>`).
  - a failure case: pointing at a nonexistent path, asserting the raised
    exception's message includes the git stderr.

This is the "on-demand, immediately before task launch" sync from spec
§6.1 — no periodic/background timer logic here, `ensure_mirror` is just a
function later chunks call synchronously.
```

#### D2

```text
Building on D1. Add `git_service.py` implementing the host-local read-only
git server from spec §6.1.1. Decision (recorded per §12): implement a small
custom wrapper using Python's stdlib `http.server`/`socketserver` that
invokes `git http-backend` as a CGI subprocess per request (via
`subprocess.run` with the CGI env vars `git http-backend` expects:
GATEWAY_INTERFACE, REQUEST_METHOD, PATH_INFO, QUERY_STRING, CONTENT_TYPE,
CONTENT_LENGTH, and GIT_HTTP_EXPORT_ALL / GIT_PROJECT_ROOT pointed at a
directory of mirrors) — not a general-purpose CGI runner package, to keep
the dependency surface small and the request path easy to unit test and
log.

Class `GitHttpBackendServer`: binds to `127.0.0.1:<port>` (port 0 = pick
free port, expose `.port`), serves only `git-upload-pack`/`info/refs`
requests for repos under a configured root directory; must NOT expose
receive-pack (don't set `http.receivepack=true` anywhere, and don't route
`service=git-receive-pack` requests to the backend at all — return 403
directly without invoking git for those).

Unit/integration test (no KVM needed, real HTTP calls against
127.0.0.1): start the server against a D1-created mirror, use `git clone
http://127.0.0.1:<port>/<repo>.git` in a subprocess to prove upload-pack
works end-to-end, and separately issue a raw HTTP request for
`?service=git-receive-pack` and assert a 403 with no git subprocess
spawned (assert via a spy/monkeypatch on subprocess invocation, or by
checking the access log from D3 shows it was rejected pre-exec).
```

#### D3

```text
Building on D2. Add the defense-in-depth and observability spec §6.1.1
calls for:

1. In `git_service.py`, add an access-log file (`<log_dir>/git-access.jsonl`,
   one JSON line per request: timestamp, remote path requested, matched
   repo, whether allowed/rejected, reason if rejected). Every request,
   allowed or not, must be logged before or as part of handling it.
2. Explicitly reject (403, logged with reason `"receive-pack path"`) any
   request whose path contains the substring `git-receive-pack`, checked
   independently of the service=query-param check from D2 (belt-and-suspenders,
   since a client could try to hit `/repo.git/git-receive-pack` directly as
   a path segment rather than via the smart-HTTP `service=` query param).

Unit test: a request to `/repo.git/git-receive-pack` (path-based, no query
param) is rejected and logged with that reason, distinct from the D2
query-param case. Add a test asserting every one of D2's existing test
requests (both the successful clone and the receive-pack rejection) also
produced exactly one corresponding line in git-access.jsonl with the right
fields.
```

#### D4

```text
Building on D1 (ensure_mirror) and D2/D3 (the service). Add
`prepare_repo(repo_url: str, commit: str, workdir: Path) -> ResolvedRepo` in
`git_mirror.py` (or a new `repo_prep.py` if it reads more cleanly) that:
  1. Calls `ensure_mirror(repo_url, mirror_path)`.
  2. Verifies `commit` exists in the mirror (`git cat-file -e`); if not,
     raise a clear "commit not found after sync" error — no retry, no
     silent fallback to a branch tip.
  3. Returns a small `ResolvedRepo` dataclass (`mirror_path`, `commit`,
     `repo_name`) that chunk E's device-2 builder will consume.

This function is the one later called by `launch` (chunk I) "immediately
before each task launch" per spec §6.1. Unit test with a local fixture
repo: happy path (existing commit), and the not-found case (garbage sha)
raising with a message that names the sha. No KVM needed.
```

### Chunk E — Block devices & workspace

#### E1

```text
Host-only, no KVM needed. In agent-vm/host/src/agentvm/, add
`device_images.py` with `build_writable_overlay(path: Path, size_mb: int) ->
None`: creates an empty ext4 image of the given size at `path` (via
`truncate -s` + `mkfs.ext4 -F`), raising on any subprocess failure with
captured stderr.

Unit test: build one, then loop-mount it (`mount -o loop`) in the test
(skip the test if not running with permission to mount loop devices —
add a `@pytest.mark.needs_root` marker mirroring B4's `needs_kvm` pattern)
and assert it's an empty ext4 filesystem of roughly the requested size. Also
add a permission-independent test: run `mkfs.ext4`'s own `-n` (dry-run) or
inspect the image header bytes for the ext4 magic number directly (no mount
needed) so there's at least one test that runs without elevated privileges.
```

#### E2

```text
Building on D2 (git service) and E1's module. Add
`build_workspace_image(resolved: ResolvedRepo, git_service_port: int, path:
Path) -> None` in `device_images.py`:
  1. In a scratch directory, `git clone --depth 1 --no-checkout
     http://127.0.0.1:<git_service_port>/<repo_name>.git`, then `git fetch
     --depth 1 origin <commit>` and `git checkout <commit>` (a plain `git
     clone --depth 1` only gets the default branch tip, so the fetch+checkout
     two-step is required to land on an arbitrary pinned commit — note this
     in a comment since it's a common mistake).
  2. Package the resulting checkout (including its now-real, tiny `.git`
     directory with the git-service URL as `origin`) into a squashfs image
     at `path` via `mksquashfs`.

Integration test (real HTTP, no KVM): start a D2 `GitHttpBackendServer`
against a D1 mirror with two commits, call `build_workspace_image` pinned
at the first commit, then `unsquashfs -l` the result and assert the
expected files are present and a file only added in the second commit is
absent. Also assert `unsquashfs -cat` on `.git/config` shows the origin URL
pointing at `127.0.0.1:<git_service_port>`.
```

#### E3

```text
Building on B3/C1's pid1-init and E1/E2's image builders. Extend
lib.rs:
  - `mount_block_device(dev: &str, target: &str, fstype: &str, flags:
    MsFlags) -> io::Result<()>` (through the same Mounter trait as B3, so
    it's testable with FakeMounter).
  - `build_overlay_options(lower: &str, upper: &str, work: &str) -> String`
    — pure function, unit-test the exact string format (`lowerdir=...,
    upperdir=...,workdir=...`) with no I/O at all.
  - `assemble_workspace() -> io::Result<()>`: mounts `/dev/vdb` (device 2,
    ro, whatever fstype matches squashfs) at a fixed `/mnt/lower`, mounts
    `/dev/vdc` (device 3, ext4, rw) at a fixed `/mnt/upper` (with an
    `/mnt/upper/work` subdir created first), then mounts an overlay at
    `/workspace` using `build_overlay_options`.

Wire `assemble_workspace()` into `main()` right after `mount_pseudo_filesystems()`
and before the vsock/spawn logic from C1. Unit tests: the pure
`build_overlay_options` string test, plus a FakeMounter-based test asserting
`assemble_workspace` issues mounts in the right order with the right
fstypes/flags/paths.

Integration test (`needs_kvm`): boot a VM with a 3-drive config — B2-style
device1 (still the echo_agent stub), a real E2 workspace image as device 2,
a real E1 empty overlay as device 3 — send the echo_agent (via C2's
SessionManager) a command that writes a file under `/workspace` (extend
echo_agent minimally: if the line starts with `write:`, write the rest to
that path under `/workspace` instead of echoing), then stop the VM.
```

#### E4

```text
Building on E1/E2/E3. Add `extract_diff(device3_path: Path, resolved:
ResolvedRepo) -> str` in `device_images.py`:
  1. Loop-mount `device3_path` read-only (needs_root for the real mount;
     structure the function so the "read the upperdir tree" part is a
     separate, pure-ish function taking a directory path, so it's testable
     against a plain fixture directory without ever mounting anything).
  2. Interpret overlayfs upperdir semantics: a character device with
     major/minor 0/0 at some path means that path was deleted in the
     overlay (a "whiteout"); anything else present is added/modified.
  3. Materialize the result as a unified diff against `resolved`'s pinned
     commit: check out that commit into a scratch dir from the local
     mirror, apply the upperdir's added/modified files and remove its
     whiteout-marked paths, then run `git diff --no-index` (or init a
     throwaway repo, commit the base, apply changes, `git diff`) and return
     the diff text.

Unit tests against synthetic upperdir fixture directories (built directly
with `os.mknod` for the whiteout case) covering: a modified file, a newly
added file, and a whiteout-deleted file — assert the returned diff has the
expected `+`/`-` hunks for each, with no real mount involved.

Integration test (`needs_kvm`, extends E3's test): after E3's VM writes a
file under `/workspace` and the VM stops, call `extract_diff` on the
resulting device 3 image and assert the diff shows that file as added.
```

### Chunk F — Network egress

#### F1

```text
Host-only, no KVM. In agent-vm/host/src/agentvm/, add `mitm_ca.py` with
`ensure_ca(ca_dir: Path) -> Path`: if `ca_dir` already contains a generated
mitmproxy CA (mitmproxy creates one on first run — invoke `mitmdump` with
`--set confdir=<ca_dir>` briefly, e.g. `mitmdump --set confdir=<ca_dir> -q`
started and immediately terminated, or use mitmproxy's own
`mitmproxy.certs.CertStore` API directly to generate without spawning a
process — prefer the direct API since it's more testable and doesn't need a
running proxy), return the path to the generated CA cert
(`mitmproxy-ca-cert.pem`) without regenerating. If absent, generate it.

Unit test: calling `ensure_ca` twice on an empty `tmp_path` produces the
same cert file both times (same modification time / same file bytes on the
second call — assert it wasn't rewritten). This CA path is a build-time
input consumed later by chunk H (baked into the guest rootfs trust store)
and a runtime input for F2's mitmproxy instance.
```

#### F2

```text
Building on F1 conceptually (this step doesn't need the CA itself, just the
addon logic). In agent-vm/host/src/agentvm/mitm_addons/, add
`allowlist.py`: a mitmproxy addon class with a `request(flow)` hook.

Config shape: a list of entries, each `{"kind": "domain", "host": str,
"port": int}` or `{"kind": "loopback", "host": "127.0.0.1", "port": int}`.
Deny-by-default: any request whose destination doesn't exactly match an
entry gets `flow.response` set to a synthetic 403 (never forwarded), and is
recorded (store rejections on `flow.metadata["allowlist_decision"] =
"denied"` for F4 to log). A "loopback" entry must match `127.0.0.1` exactly
at that port only — any other loopback address or any RFC1918/private range
destination is denied even if not explicitly listed (the point being the
proxy can never be pivoted into an SSRF against other host-local services).

Unit tests using `mitmproxy.test.taddons`/`tflow` fixtures (no real network,
no KVM): allowed domain passes through untouched, disallowed domain gets
403, allowed loopback port passes, a *different* loopback port is denied, a
10.x.x.x destination is denied even though it's "private", and a request
path containing `git-receive-pack` to the allowlisted git loopback entry is
denied regardless of the allowlist match (this rule is specific to that one
entry — implement it as an extra check when `kind == "loopback"` and the
configured entry is tagged e.g. `"deny_paths_containing":
["git-receive-pack"]`).
```

#### F3

```text
Building on F2's addon pattern. Add `mitm_addons/credentials.py`: a
`request(flow)` hook that, only when the flow's destination exactly matches
a configured `(host, port)` for the Anthropic API, replaces the
`Authorization` header with a real value read once at proxy startup from a
host-local file path (never from an env var that might leak into a process
listing — read the key from a file, e.g. `/persistent/agentvm/anthropic-api-key`,
passed into the addon's constructor). For every other destination, leave
the header untouched (including leaving whatever placeholder the guest
sent, if any).

Unit tests with `tflow`: matching destination gets its Authorization header
replaced with the configured real value; a non-matching destination's
header (if present) is left exactly as the guest sent it, proving the real
key is never attached to unrelated requests.
```

#### F4

```text
Building on F2/F3. Add `mitm_addons/transcript.py`: a `response(flow)` hook
(fires after the exchange completes) that appends one JSON line per request
to `<session_dir>/proxy.jsonl` with: timestamp, session_id, method, host,
port, path, status_code (or None if F2 denied it before forwarding — read
`flow.metadata["allowlist_decision"]`), duration_ms, request/response byte
sizes. Mandatory rule: never include the literal Authorization header
value in the log line, for *any* request — redact it to a fixed placeholder
string like `"[REDACTED]"` if present at all, regardless of whether F3
rewrote it.

Unit tests with `tflow`: an allowed request produces a line with the right
fields and status; a denied request (from F2) produces a line with
`status_code: null` and a `decision: "denied"` field; a request carrying an
Authorization header (real or placeholder) never has that value appear
anywhere in the emitted JSON — assert by string-searching the serialized
line for the known secret value and asserting absence.
```

#### F5

```text
Building on C1's pid1-init spawn logic. Add a vsock↔TCP shim step to
pid1-init: before accepting the stdio connection, spawn (via the same
Spawner trait from C1) `socat TCP-LISTEN:<local_port>,bind=127.0.0.1,fork,
reuseaddr VSOCK-CONNECT:2:<PROXY_PORT>` as a detached background child
(port 2 = the well-known "host" CID in Firecracker's vsock addressing;
confirm this against Firecracker's vsock docs and use a named constant, not
a bare `2`, with a comment explaining what it is). Bundle `socat` into
device1-v0's squashfs (update B2/E3's Nix packaging to include a statically
linked socat — check nixpkgs for a static build or produce one; if
unavailable statically, note this as a decision point revisited in chunk H
when the real closure is built).

Unit test the exact argv constructed for the socat invocation (pure
function, no process spawning) given a chosen `local_port` and
`PROXY_PORT` constant. Integration test (`needs_kvm`): boot a VM with this
shim running, from the host open a listener on the *guest-facing* side of a
fake vsock peer (a raw AF_VSOCK socket bound to the host CID at
PROXY_PORT... note Firecracker vsock specifics may require this via the
`<uds_path>_<PROXY_PORT>` convention — implement the host side using F6's
bridge once it exists; if sequencing makes a standalone test awkward here,
it's acceptable to fold this step's integration test into F6/F8 instead —
state clearly in your PR/commit message which test proves this step and
why.
```

#### F6

```text
Building on F5. Firecracker vsock guest-initiated connections appear on the
host as new connections on `<uds_path>_<port>` — the host must bind/listen
on that exact path *before* the guest connects, and must accept-loop (a
socat `fork`ed shim on the guest side may open several concurrent
connections for concurrent HTTP requests).

In `vsock_bridge.py`, add `serve_guest_connections(uds_path: str, port: int,
relay_to: tuple[str, int]) -> GuestBridgeServer`: binds
`f"{uds_path}_{port}"`, accepts connections in a loop (thread-per-connection
or asyncio, pick whichever matches the rest of the codebase's style — if
none established yet, use `asyncio` since F's other components will also
need concurrency), and for each accepted connection opens a TCP connection
to `relay_to` and pipes bytes bidirectionally until either side closes.

Unit test with a fake TCP echo server standing in for `relay_to`: connect to
the bound `<uds_path>_<port>` socket as a fake "guest", send bytes, assert
they come back via the relay. Test two concurrent connections are both
served correctly (not serialized/blocked on each other).
```

#### F7

```text
Building on D2 (git service) and F2 (allowlist config shape). Add a small
`build_allowlist(git_service_port: int, anthropic_host: str, anthropic_port:
int) -> list[dict]` helper (in allowlist.py or a new `policy.py`) that
assembles the concrete allowlist used at runtime: the Anthropic API domain
entry, and a loopback entry for `127.0.0.1:<git_service_port>` tagged with
`deny_paths_containing: ["git-receive-pack"]` per F2's rule. Unit test it
returns exactly those two entries with correct shapes — this is the piece
that later gets threaded into F2's addon config by chunk I's `launch`.
```

#### F8

```text
Building on F1-F7 and E3 (workspace mount) and D2 (git service). This is
the full egress end-to-end test, `@pytest.mark.needs_kvm`. Set up:
  - A real `GitHttpBackendServer` (D2) over a fixture mirror.
  - A real mitmproxy instance (programmatically, via mitmproxy's
    `DumpMaster`/async API) loaded with F2+F3+F4 addons and F7's allowlist,
    plus one extra fake "allowlisted domain" entry pointed at a local
    HTTPS test server you stand up in the test (e.g. via `pytest-httpserver`
    or a bare `http.server` with a self-signed cert) standing in for
    api.anthropic.com.
  - F6's bridge relaying the VM's guest-initiated PROXY_PORT connections to
    that mitmproxy instance's TCP listener.
  - A VM booted with device1 including F5's socat shim, HTTP_PROXY/
    HTTPS_PROXY env pointed at the shim's local port, and an *empty*
    `/etc/resolv.conf`.

Extend echo_agent (guest stub) minimally to accept commands: `curl-allowed`,
`curl-denied`, `git-fetch`, `dns-lookup` — each performing the
corresponding action using tools already in device1's stub image (curl,
git; add a trivial DNS-lookup attempt via e.g. `getent hosts example.com`
or a tiny Rust/C helper if getent isn't available) and printing
success/failure to stdout.

Drive all four commands via C2's SessionManager and assert: curl-allowed
succeeds, curl-denied fails (proxy 403) and produces a `denied` line in
proxy.jsonl, git-fetch against the loopback entry succeeds, dns-lookup fails
fast (not a timeout) since resolv.conf is empty.
```

### Chunk G — eBPF monitoring

#### G1

```text
Building on A4's BPF skeleton. Replace the no-op program: add
bpf/progs/exec.bpf.c attaching to the `sched_process_exec` tracepoint (or
an `execve` kprobe if that's simpler with your libbpf CO-RE setup — prefer
the tracepoint, it's more stable across kernel versions), capturing pid,
ppid, comm, and argv (read via `bpf_probe_read_user`/tracepoint args as
available) into a BPF ring buffer.

Update bpf/loader/main.c to open+load exec.bpf.c's object, attach it, then
poll the ring buffer and print one JSON line per event to stdout (comm,
pid, ppid, argv joined, event_type: "exec"). Add
`@pytest.mark.needs_root`/needs_bpf test infrastructure (a marker + skip
condition analogous to `needs_kvm`) and one integration test: run the
loader as a subprocess, in parallel exec a known marker binary (e.g. `/bin/
true` with a unique argv sentinel), assert a matching JSON line appears in
the loader's stdout within a timeout. Also add a pure unit test (no BPF
needed) for the JSON-line serialization function in isolation (extract it
so it's testable independent of the ring-buffer plumbing).
```

#### G2

```text
Building on G1. Add bpf/progs/network.bpf.c (or extend the existing object)
attaching kprobes/tracepoints on `connect` and `sendto` syscalls, capturing
pid, comm, destination address/port (for AF_INET/AF_INET6; note AF_VSOCK
connects are expected and not inherently violations — still log them, just
don't treat vsock as suspicious) and emitting `event_type: "network"` JSON
lines via the same ring buffer/loader path as G1.

Extend the loader's serialization unit test (pure function) to cover this
event shape. Extend the G1-style integration test: spawn a process that
does a raw TCP connect to a throwaway local listener, assert a matching
"network" event appears.
```

#### G3

```text
Building on G1/G2. Add file-open tracing: attach to the `open`/`openat`
syscalls (kprobe or the `sys_enter_openat` tracepoint), capturing pid,
comm, path, and whether the open requested write access (derive from the
`flags` argument: check `O_WRONLY`/`O_RDWR`), emitting `event_type:
"file_open"` with a `mode: "read"|"write"` field.

Unit test the read/write classification as a pure function given raw flag
values (including edge cases like `O_RDWR|O_CREAT`). Integration test:
spawn a process that opens one file read-only and another write-only,
assert both appear with correct `mode`.
```

#### G4

```text
Building on G1/G2. Add DNS-attempt detection: since the guest has no
working resolver path, any `connect`/`sendto` to port 53 (UDP or TCP) is by
definition a DNS attempt bypassing the intended proxy path. Reuse G2's
existing connect/sendto capture — add a derived `event_type: "dns_attempt"`
emitted (in addition to, or instead of, the generic "network" event — prefer
emitting both so nothing is lost, with dns_attempt as an extra tagged
event) whenever the destination port is 53.

Unit test the port-53 classification as a pure function. Integration test:
have a spawned process attempt a UDP send to 127.0.0.1:53 (no listener
needed, sendto doesn't require one), assert a "dns_attempt" event appears.
This closes out spec §7.1's four required event categories.
```

#### G5

```text
Building on G1-G4 (loader now emits four event types to stdout) and F5's
constants module (BPF_PORT). Change the loader so instead of printing to
stdout, it connects to a vsock listener on BPF_PORT and writes JSONL there
(mirror C1's AF_VSOCK approach, but the loader is C, so use raw AF_VSOCK
socket calls directly — Linux's `<linux/vm_sockets.h>` is available even
without libvsock).

In pid1-init (Rust), add an invocation step: after mounting pseudo-fs and
before privilege drop (this must happen while still privileged enough to
load BPF programs — CAP_BPF/CAP_PERFMON or root, whichever this kernel
build ends up requiring; note whichever it is in a comment), spawn the BPF
loader binary as a background child via the Spawner trait, and bind an
AF_VSOCK listener on BPF_PORT for it to connect to (host will connect via
C2-style host-initiated `CONNECT <port>` since this is a single long-lived
connection, not per-request like the proxy — reuse that pattern rather than
F6's guest-initiated one).

Unit test (FakeSpawner) that pid1-init issues this spawn with the right
argv/timing (after mount, before the eventual privilege-drop step landing
in chunk K). Integration test (`needs_kvm` + `needs_root` for BPF): boot a
VM with the loader wired in, connect from the host the same way C2 does,
exec a marker command inside the guest via the stub agent, assert the exec
event arrives over that vsock connection.
```

#### G6

```text
Building on G5 and C2's host-initiated vsock connection pattern. Add
`bpf_receiver.py`: given a session's vsock connection (obtained via
`vsock_bridge.connect_guest_port` for BPF_PORT, same as C2 does for
STDIO_PORT), read newline-delimited JSON continuously and append each line
verbatim to `<session_dir>/bpf.jsonl`. No parsing/validation/alerting logic
— per spec §7.2 this is intentionally a dumb append-only sink.

Unit test with a fake socket feeding scripted JSONL chunks (including a
chunk split mid-line, to prove line-buffering is handled correctly), assert
the output file has exactly the right lines. Integration test
(`needs_kvm`+`needs_root`): reuse G5's integration test setup, but drive it
through `bpf_receiver.py` instead of a raw connection, assert `bpf.jsonl`
ends up with the exec event line.
```

### Chunk H — Guest rootfs closure

#### H1

```text
This replaces B2/E3's throwaway device1-v0 with the real Device 1 from spec
§9. Add `agent-vm/nix/device1.nix`: build a minimal but real closure
(coreutils, bash, git, python3 — the actual tool allowlist; keep it short,
this is the set later steps extend) using nixpkgs' existing
`<nixpkgs/nixos/lib/make-squashfs.nix>` (or equivalent current-nixpkgs
helper — this is exactly the "self-contained, host-store-independent
closure into a squashfs" mechanism spec §12 leaves open; using nixpkgs'
own helper is the concrete decision here, since it already produces a
closure with its own isolated `/nix/store` prefix rather than bind-mounting
the host's). Confirm the *build sandbox's* `/nix/store` is not what ends up
mounted at runtime — the derivation output is a self-contained image file.

Add a check derivation: `unsquashfs -l` the output and assert it contains a
`/nix/store` with the expected packages and does NOT contain anything
identifying it as sharing paths with the host's live store (e.g. assert the
image is a plain file, not a bind-mount reference). This is a build-and-
inspect test, no VM boot needed yet.
```

#### H2

```text
Building on H1. Extend device1.nix's closure: add the `claude-code`
package (already used elsewhere in this repo's `llm-host.nix`, which sets
`nixpkgs.config.allowUnfreePredicate` for it — mirror that same
allow-unfree handling in this derivation's own pkgs instantiation). Add a
placeholder credentials file baked into the image at a fixed path (e.g.
`/etc/agentvm/anthropic-api-key.placeholder`, containing a literal
placeholder string like `"placeholder-do-not-use"`), and have pid1-init
(extend the env-setup step) export `ANTHROPIC_API_KEY` read from that file
plus `HTTP_PROXY`/`HTTPS_PROXY` pointing at F5's local shim port, as env
vars for whatever it execs next.

Unit test (Rust): the env-assembly function (pure, given a placeholder-file
path and a proxy port, returns the expected map of env vars) — no I/O
faking needed beyond reading a real temp file. Build check: `unsquashfs
-cat` the placeholder file path from the image and assert its contents.
```

#### H3

```text
Building on H1/H2 and F1 (mitmproxy CA generation). device1.nix must accept
a CA cert file path as a build input and install it into the image's TLS
trust store (path depends on whichever libc/cert-bundle mechanism the
closure uses — likely need `cacert`'s update mechanism or manually appending
to a `ca-bundle.crt` and pointing `SSL_CERT_FILE`/`SSL_CERT_DIR` at it for
whatever HTTP clients are in the closure, e.g. curl/git/python's `ssl`
module — verify what each actually consults for musl/nix builds and wire
all of them consistently).

Add a build-time check derivation: generate a test leaf certificate signed
by the same CA (using F1's `ensure_ca` output as the Nix build input,
threaded in via an `--arg` or similar), install it into a copy of the trust
bundle this derivation produces, and run `openssl verify -CAfile
<the produced bundle> <test leaf cert>` asserting success — this proves the
bake-in without needing to boot a VM.
```

#### H4

```text
Building on H1-H3 and G2 (network connect tracing) and F8's egress harness.
Add an integration test (`needs_kvm`+`needs_root`) that boots a VM with the
real H3 device1 image (not the stub), F5's shim configured, F8-style
mitmproxy+bridge running, and G5's BPF loader wired in. Inside the guest,
run each tool actually shipped in the closure that talks HTTP(S) — at
minimum `git ls-remote` against the loopback git entry, and `curl` against
the fake allowlisted domain from F8. Assert two things per tool: the
request succeeds through the proxy (proxy.jsonl shows it, allowed), and
bpf.jsonl shows *zero* "network" events whose destination is anything other
than the shim's own loopback port (i.e., no tool fell back to a direct
connect attempt bypassing the proxy). Document in a code comment that this
is the "loud failure, not silent exfiltration" smoke test spec §5.1.1
calls for, and that adding a new tool to the closure later must extend this
same test.
```

#### H5

```text
Building on H1-H4 (real closure with Claude Code CLI present) and C1/E3
(pid1-init currently execs the echo_agent stub with stdio wired to vsock,
cwd unset). Change pid1-init's final exec target from `/bin/echo_agent` to
the real Claude Code CLI binary path in the closure, with working directory
set to `/workspace` (E3's overlay mount point) and env vars from H2's
env-assembly function applied.

This is a wiring change, not new logic — update the FakeSpawner-based unit
test from C1 to assert the new binary path/cwd/env are what gets passed to
spawn, and update/replace the C1-derived and F8/H4 integration tests that
depended on echo_agent's specific stub commands: since Claude Code needs a
real task/prompt to do anything, for now assert only that (a) the process
starts, (b) its stdio is reachable via C2's SessionManager exactly as
before, and (c) it can see `/workspace` contents from E2's checked-out
commit (e.g. by sending it a trivial prompt/command that lists files, if
Claude Code CLI supports a fully non-interactive one-shot mode — otherwise
assert reachability via the terminal channel only, and note that full
task-completion testing is deferred to chunk K's end-to-end scenario test).
```

### Chunk I — Orchestration CLI

#### I1

```text
Building on A2's CLI skeleton. Add `session.py`: a `SessionConfig` dataclass
(repo_url, commit, task_input, vcpu, mem_mb, timeout_seconds) with
validation (reject empty repo_url/commit, non-positive resource values),
and a `SessionRegistry` class backed by a directory of one JSON file per
session (`<state_dir>/sessions/<session_id>.json`) holding
{session_id, config, status: "starting"|"running"|"stopped"|"failed",
started_at, ended_at, pid/vm handle info, paths to session_dir/log files}.
Provide `create()`, `update(session_id, **fields)`, `get(session_id)`,
`list_all()`.

Unit tests: validation rejects the bad configs above; registry round-trips
correctly through a `tmp_path`; `list_all()` reflects concurrent writes from
multiple `update()` calls. No KVM needed.
```

#### I2

```text
Building on I1 and every prior chunk (D4, E1/E2, B4/F5/F6/G5/G6/H5, C2/C3).
Add the `launch` CLI command wiring the full pipeline:
  1. Validate + create a `SessionConfig`/registry entry (I1), status
     "starting".
  2. `prepare_repo` (D4) to sync the mirror and resolve the commit.
  3. Build device 2 (E2) and device 3 (E1) images into the session's
     directory.
  4. Ensure the git service (D2) and mitmproxy (F1-F4, F7 for the
     allowlist) are running (module-level singletons shared across
     sessions, started lazily on first launch, referenced by later
     sessions rather than restarted).
  5. Boot the VM (B4/H5's real device1, E2/E1 as devices 2/3) with F5's
     shim baked in and G5's loader wired in.
  6. Start C2/C3's SessionManager (stdio + terminal.jsonl + attach socket),
     F6's guest-bridge for the proxy port, and G6's BPF receiver, all
     pointed at this session's directory.
  7. Update the registry to "running".

Structure this as a `LaunchOrchestrator` class with each subsystem injected
via constructor (so unit tests can substitute fakes for all of them) rather
than importing/instantiating concretes inline. Unit test: with every
dependency faked, assert the steps happen in the right order and the
registry ends up "running" with the right paths recorded; assert a failure
in any step (raise from a fake) leaves the registry in "failed" with the
error captured, not "running". One real `needs_kvm` integration test:
launch against a tiny fixture repo end-to-end and confirm a running session
is observable via C2's stdio connection.
```

#### I3

```text
Building on I1/I2. Add the `list` CLI command: enumerate
`SessionRegistry.list_all()`, and for any entry marked "running", probe
Firecracker's instance-info REST endpoint (B4's VM handle) to confirm it's
actually still alive, correcting the registry to "stopped"/"failed" if the
process/VM is gone but the registry hadn't been updated (crash recovery).
Print a table (session_id, status, repo, commit, started_at, elapsed).

Unit test the reconciliation logic with a fake VM-status prober returning
"gone" for a registry entry claiming "running", asserting the registry gets
corrected. Unit test the table formatting separately from the reconciliation
logic.
```

#### I4

```text
Building on I2/I3 and C3's attach.sock. Add `attach`/`detach` CLI commands:
`attach <session_id>` looks up the session's `attach.sock` from the
registry, connects, and does a raw-terminal passthrough (set the local tty
to raw mode via `termios`, restore on exit) between the user's terminal and
that socket until the user detaches (a fixed escape sequence, e.g.
Ctrl-], mirroring screen/tmux) — detaching must close only the local
connection, not send anything that would affect C3's persistent
stdio_sock or other attached clients.

Unit test the escape-sequence detection as a pure function over a byte
stream (given bytes including the escape sequence split across two reads,
correctly detect it without swallowing legitimate data). Integration test
(`needs_kvm`): launch a session (I2), attach, type a line, assert it's
echoed per H5's agent behavior (or, if Claude Code needs a real prompt to
respond, use a controllable stub/dry-run mode if the CLI has one, or fall
back to asserting the same echo_agent-based flow from C3's own test still
works when substituted in this integration test's config).
```

#### I5

```text
Building on I2/I3. Add the `stop` CLI command: look up the session, attempt
a graceful stop via B4's `FirecrackerVM.stop()`, wait up to a short timeout,
and SIGKILL the firecracker process if it hasn't exited, then update the
registry to "stopped" with `ended_at` set, and tear down this session's
SessionManager/bridges/receiver background tasks/threads.

Unit test with a fake VM handle that doesn't respond to graceful stop,
asserting the force-kill path is taken after the timeout and the registry
still ends up correctly "stopped". Integration test (`needs_kvm`): launch,
stop, assert the firecracker process is actually gone (not just the
registry saying so) and I3's `list` reflects "stopped".
```

#### I6

```text
Building on I1/I5. Add timeout enforcement per spec §10: every session has
`timeout_seconds` (I1). Add `reap_overdue_sessions(registry)` — checks every
"running" entry's `started_at + timeout_seconds` against now, and calls the
same stop logic as I5 for any overdue session, updating status to "stopped"
with a reason field `"timeout"`.

Wire this function to run at the start of every CLI invocation (in
`cli.py`'s top-level setup, before dispatching to the subcommand) so a
`list`/`launch`/etc. call always reaps first. Also add a standalone `agentvm
reap` subcommand intended to be invoked periodically by an external
systemd timer (document this in a comment: CLI-triggered reaping alone
can't catch an overdue session if no CLI command runs for hours, hence the
standalone entrypoint for a timer to call).

Unit test with a fake clock (inject "now" as a parameter rather than calling
`time.time()` directly) asserting sessions past their deadline get stopped
and sessions within their deadline are untouched.
```

#### I7

```text
Building on I1/I2/I6. Add a concurrency cap: a configured
`max_concurrent_sessions` (module-level default constant, overridable via a
config file/env var — pick one and document it), enforced in `launch`
*after* I6's reaping runs (so a just-timed-out session frees its slot before
the cap is checked): if `len([s for s in registry.list_all() if s.status ==
"running"]) >= max_concurrent_sessions`, reject the launch with a clear
error and do not create a registry entry or start any subsystem.

Unit test: with the cap set to 1 and a fake registry already showing one
"running" session, assert `launch` raises the expected error and I2's
`LaunchOrchestrator` steps are never invoked (assert via a spy that none of
the injected fakes were called). Assert a session in "stopped"/"failed"
status doesn't count against the cap.
```

#### I8

```text
Building on E4 (diff extraction) and I1/I3. Add the `review` CLI command:
look up the session, require it be "stopped"/"failed" (refuse with a clear
message if still "running" — must stop it first), call E4's
`extract_diff`, and pipe the result to `delta` if present on PATH else
`less`(subprocess, inheriting the terminal). Also add a `transcript
<session_id>` command that just prints the three jsonl file paths
(terminal/proxy/bpf) for the session, plus one ready-to-copy example DuckDB
command (`duckdb -c "select * from read_json_auto('<path>/*.jsonl')"`) —
this doesn't need to *run* DuckDB, just tell the user how to, per spec §11.

Unit test the "must be stopped first" guard, and the pager-selection logic
(delta vs less) via a fake `shutil.which`. Integration test (`needs_kvm`):
run I2 launch → I5 stop → I8 review end-to-end against a fixture repo with
a real change, asserting the diff output contains the expected added file.
```

### Chunk J — Transcript unification

#### J1

```text
Building on C3 (terminal.jsonl), F4 (proxy.jsonl), G6 (bpf.jsonl) — each
currently writes its own ad hoc JSON shape. Add `transcript_schema.py`
defining one shared model (a dataclass or pydantic model, matching
whichever style the rest of `agentvm` already leans toward — check I1's
`SessionConfig` and follow its pattern): `{timestamp: float (unix,
subsecond), session_id: str, stream: Literal["terminal","proxy","bpf"],
event_type: str, payload: dict}`, plus one `write_event(fp, **kwargs)`
helper that all three writers now call instead of hand-building JSON.

Retrofit C3's recorder, F4's addon, and G6's receiver to import and use
this shared writer (payload becomes whatever stream-specific fields they
already had — direction/base64 for terminal, method/host/status/etc for
proxy, the raw BPF event dict for bpf). Update each chunk's existing unit
tests only as needed to match the new shared field names (`stream`/
`event_type`/`payload` wrapper) — do not change what information is
captured, only its envelope. Add one new unit test per writer asserting the
top-level envelope now conforms to the shared schema.
```

#### J2

```text
Building on J1 and I2 (a full launch produces all three jsonl files) or, if
DuckDB availability makes that heavy, a synthetic fixture producing three
small jsonl files via J1's `write_event` directly (prefer this — it doesn't
need KVM and is faster/more deterministic). Add a test using the `duckdb`
Python package (add as a test dependency) running `SELECT stream,
count(*) FROM read_json_auto('<dir>/*.jsonl') GROUP BY stream` against the
fixture directory, asserting all three streams appear with the expected
row counts and that `timestamp`/`session_id`/`event_type` columns are
present with correct types. This proves spec §11's "directly queryable via
DuckDB" requirement against real files, not just against the writers'
in-memory representation.
```

### Chunk K — Hardening & polish

#### K1

```text
Building on H5 (pid1-init's final exec target) and every earlier privileged
setup step (B3 mounts, E3 device mounts, F5 shim spawn, G5 BPF loader
spawn — all of which need root/elevated capabilities). Add the capability-
drop step from spec §4 step 6 / §8: a pure function
`build_cap_drop_plan(target_uid: u32) -> CapDropPlan` (a small struct
listing "setuid to this uid" + "clear this capability set") that's
unit-testable without actually calling any syscalls, plus a real
`apply_cap_drop(plan: &CapDropPlan) -> io::Result<()>` using the `caps`
crate (or raw `prctl`/`capset` via `nix` if that crate doesn't fit the
musl-static build — verify which compiles and use that) to setuid and clear
all capability sets.

Call `apply_cap_drop` as the *last* pid1-init step before H5's exec — after
every other setup step (mounts, shim spawn, BPF loader spawn) has already
run as those still need elevated privileges.

Unit test `build_cap_drop_plan`'s output shape. Integration test
(`needs_kvm`): boot a VM, have the exec'd process (temporarily point it at a
tiny helper that dumps `/proc/self/status`'s `Uid`/`CapEff` lines to stdout
before H5's real Claude Code CLI takes over — gate this behind a
build-time/env flag so it's easy to swap back) and assert over C2's stdio
channel that Uid is non-zero and CapEff is all zero.
```

#### K2

```text
Building on every prior chunk. Add one hermetic end-to-end scenario test,
`test_full_scenario.py`, `@pytest.mark.needs_kvm` (+`needs_root` for BPF).
Use a stub "agent" script (not the real Claude Code CLI, to keep this test
deterministic and offline) substituted via H5's build-time flag from K1: it
reads a known file under `/workspace`, appends a line to it, and exits 0.

Drive the full flow through the real CLI commands built in chunk I only
(not by calling internal modules directly) against a fixture repo with that
known file: `launch`, poll `list` until "stopped", `review` (assert the
diff shows exactly the expected line added), inspect `terminal.jsonl` for
the stub's expected output, inspect `proxy.jsonl` for the git-fetch-through-
loopback entry and confirm no disallowed destinations appear, inspect
`bpf.jsonl` for the stub's exec event and at least one file_open event with
mode "write" for the modified file. Additionally: launch a second session
while the cap (I7) is set to 1 and assert it's rejected; let a session's
`timeout_seconds` be set very low and assert I6's reaping stops it
automatically. This test is the acceptance test for the whole spec —
keep it slow-but-thorough rather than trying to make it fast.
```

#### K3

```text
Building on the finished system. Write agent-vm/README.md into a real
runbook covering: how to rebuild each Nix image and when it's necessary
(device1 closure changes → rebuild on tool-allowlist changes only, per
spec §9; device2 → rebuilt per commit automatically by `launch`; kernel →
rarely, only on config changes), the full CLI command reference
(launch/list/attach/stop/review/reap), where to look for each transcript
stream and the DuckDB one-liner from I8, and a "Decisions made" section
recording, with a one-line rationale each, every item from spec §12:
git-http-backend wrapping (D2's custom CGI wrapper), package registry
strategy (explicitly still deferred — state this rather than inventing an
answer, since the spec says it's decided per-ecosystem as needed and none
were added in this plan), guest kernel config specifics (B1's fragment
list), Nix closure isolation mechanism (H1's make-squashfs-based approach),
and vsock↔TCP shim implementation (F5's socat choice, noting the static-
linking caveat raised there). No code changes in this step — documentation
only, but grep the actual final code to make sure every claim in the
runbook matches what was actually built, not what was originally planned.
```

---

## 5. Using this plan

- Run chunks in order; within a chunk, steps are ordered by dependency —
  don't skip ahead.
- Every step's prompt names exactly what already exists and what it wires
  into — if a code-gen LLM produces something that doesn't integrate with
  the named prior artifact, that's a signal the prompt was followed
  incorrectly, not that the plan is wrong.
- `needs_kvm`/`needs_root`/`needs_bpf` markers exist so the bulk of the
  suite (pure logic, host-only network/git code) runs anywhere, while the
  true integration tests only run on hardware like this repo's actual
  target host (which already has nested KVM enabled per `llm-host.nix`).
- Chunk boundaries (A–K) are good checkpoint/review points; step boundaries
  are good commit points.
