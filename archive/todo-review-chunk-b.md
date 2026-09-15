# Chunk B Code Review — Fix Checklist

Findings from the `/code-review` pass over commit `7211c23` ("Implement
chunk B: Firecracker walking skeleton"), reported via `ReportFindings` on
2026-09-15. Ranked most-severe first. Work top to bottom; each item lists
the problem, the concrete fix, and how to verify it before checking off.

Re-run after every fix (from `agent-vm/host/`, inside the devshell):

```
nix-shell ../nix -A devshell --run "pytest -v"
```

and after any Rust change (from `agent-vm/guest/`):

```
nix-shell ../nix -A devshell --run "cargo test --workspace"
```

**Status: all items resolved and verified on 2026-09-15.** Each `[x]` below
was individually confirmed (unit tests, `cargo test --workspace`, `pytest`,
and a real `needs_kvm` boot) before checking off.

---

## 1 — `start()` leaks the process/fd on any config error

- **File**: `agent-vm/host/src/agentvm/firecracker.py:66` (`FirecrackerVM.start`)
- **Problem**: Once `subprocess.Popen(...)` succeeds (line 74), any later
  failure — `_wait_for_api_socket()` timing out, or any of the four
  `_put()` calls raising `FirecrackerApiError` — propagates straight out
  of `start()`. Nothing kills `self._process` or closes
  `self._console_fh` first.
- **Failure scenario**: A bad `kernel_image`/`rootfs_image` path makes
  `/boot-source` or `/drives/rootfs` return 4xx → `_put()` raises →
  `start()` exits via exception with the firecracker child still running
  and the console log fd still open. Every configuration mistake leaks a
  process and a file descriptor.
- [x] Wrap the body of `start()` (from the `Popen` call onward) in a
      `try/except` that, on any exception, best-effort kills
      `self._process` (if set and still running) and closes
      `self._console_fh` (if open), then re-raises the original
      exception.
- [x] Consider factoring the "kill process + close fh" logic into a
      small private helper (`_force_cleanup()`) so `start()`'s except
      block and `stop()`'s force-kill path can share it (see #9 for the
      broader duplication point — at minimum don't hand-roll a third
      variant here).
- [x] Unit test: a fake/failing `_put` (monkeypatched or via a stub
      `requests_unixsocket.Session`) that raises on the first PUT; assert
      the firecracker subprocess is no longer running and the console log
      fh is closed after `start()` raises. This can be a pure Python unit
      test with a fake session object — no real firecracker/KVM needed.
- [x] Confirm the existing `needs_kvm` boot test in
      `test_firecracker_boot.py` still passes unmodified (happy path
      unaffected).

**Resolved**: `start()` now wraps everything after `Popen()` in
`try/except Exception: self._force_cleanup(); raise`. `_force_cleanup()`
kills the process (if still running) and closes/clears `_console_fh`;
`stop()`'s force-kill path was left as its own short block (see #9's
resolution note on why `_force_cleanup` wasn't reused there). Covered by
`test_start_cleans_up_process_and_console_log_on_put_failure` in the new
`agent-vm/host/tests/test_firecracker.py` (uses a fake shell-script
"firecracker" that creates the socket file then hangs, so the first real
PUT fails with a connection error).

## 2 — Test's `vm.start()` call sits outside the `try/finally`

- **File**: `agent-vm/host/tests/test_firecracker_boot.py:65`
- **Problem**:
  ```python
  vm.start()
  try:
      vm.wait_for_console_string(LIVENESS_MESSAGE, timeout=15.0)
  finally:
      vm.stop()
  ```
  Only `wait_for_console_string()` is guarded. If `start()` itself raises,
  `vm.stop()` never runs.
- **Failure scenario**: Once #1 is fixed, `start()` cleans up after
  itself on failure, so this is lower-stakes than before — but it's still
  incorrect defensively, and matters for cases where `start()` succeeds
  partially in ways `stop()` still needs to unwind (e.g. the process is
  running but boot never reaches liveness in some *other* future variant
  of this test).
- [x] Move `vm.start()` inside the `try` block, so any exception from
      `start()` still triggers `vm.stop()` in `finally`.
- [x] Re-run `test_boots_and_reaches_liveness` (needs_kvm, real boot) and
      confirm it still passes end-to-end.

**Resolved**: `vm.start()` moved inside the `try:` in
`test_firecracker_boot.py`. Real boot confirmed passing after the change
(and again after every subsequent fix below).

## 3 — `SendCtrlAltDel` graceful-stop path is dead code

- **File**: `agent-vm/host/src/agentvm/firecracker.py:131` (inside `stop()`)
- **Problem**: `agent-vm/nix/guest-kernel.nix`'s `structuredExtraConfig`
  enables no i8042/keyboard/input driver support. Firecracker's
  `SendCtrlAltDel` action relies on the guest's i8042 controller emulation
  to signal a reset — with no driver to notice it, the guest never
  reacts.
- **Failure scenario**: Every single `stop()` call sends
  `SendCtrlAltDel`, gets no guest reaction, blocks for the full `timeout`
  (default 5s) in `self._process.wait(timeout=timeout)`, then falls
  through to `terminate()`. This is a needless multi-second delay on
  every VM stop, in tests and in real orchestration later (chunk I).
- [x] Decide: either (a) add the minimal kernel config for
      `SendCtrlAltDel` to actually work (i8042 + related input config,
      confirmed by an actual boot+stop cycle), or (b) drop the
      `SendCtrlAltDel` attempt entirely and go straight to
      `terminate()`/`kill()`, documenting *why* in a comment (mirrors the
      B4 prompt's "SendCtrlAltDel **or** process termination" wording —
      termination alone is an explicitly allowed choice).
      Recommendation: (b) — it's simpler, doesn't couple stop() latency
      to kernel config, and this microVM model doesn't need graceful
      guest shutdown (it's meant to be reaped, not gracefully powered
      off; see spec).
- [x] If (b): reduce or drop the artificial wait before `terminate()`
      (e.g. call `terminate()` directly rather than waiting out a
      `timeout` that's known to always expire).
- [x] Update `stop()`'s docstring ("try a guest reset first...") to match
      whichever approach is chosen.
- [x] Time the `needs_kvm` boot test before/after to confirm `stop()` is
      measurably faster (should drop by roughly `timeout` seconds if (b)
      is chosen).

**Resolved**: chose (b). `stop()` now calls `self._process.terminate()`
directly (no `SendCtrlAltDel` PUT at all), waits up to `timeout`, falls
back to `kill()`. Docstring rewritten to explain there's no working
graceful path given the kernel config, and that this microVM model is
meant to be reaped, not gracefully powered off. Measured effect: the full
`test_boots_and_reaches_liveness` run time dropped from ~7.6s (with the
dead `SendCtrlAltDel` wait) to ~2.8s; the console log for a passing run no
longer contains a `SendCtrlAltDel` API log line at all.

## 4 — Poll loops don't notice the process has already died

- **File**: `agent-vm/host/src/agentvm/firecracker.py:58` (`_wait_for_api_socket`) and `:108` (`wait_for_console_string`)
- **Problem**: Both loops only check their own condition (socket exists /
  string present) against a wall-clock deadline. Neither checks
  `self._process.poll()`.
- **Failure scenario**: If firecracker or the guest kernel crashes right
  after `InstanceStart` (e.g. the "Invalid Elf magic number" failure mode
  documented in `guest-kernel.nix`'s comments, or a future kernel-config
  regression), the loop keeps re-reading the static console log for the
  full 15s (or blocks 5s on the socket wait) instead of failing fast with
  the real cause. This actively slowed down debugging during chunk B
  itself.
- [x] In `wait_for_console_string()`, on each poll iteration check
      `self._process.poll() is not None` (process exited); if so, raise
      immediately with a message that includes the process's exit code
      and the console log tail (or full contents, given the log is
      small), rather than waiting out the full timeout.
- [x] In `_wait_for_api_socket()`, same idea: if the process has already
      exited before the socket appears, raise immediately (include exit
      code) instead of waiting out the timeout.
- [x] Unit test (no KVM needed): start a fake/trivial subprocess that
      exits immediately (e.g. `["false"]` or `["true"]` as a stand-in for
      `firecracker_binary` via a constructed `FirecrackerVM`, or test the
      polling helper directly if extracted per #9), assert the wait
      raises promptly (well under the configured timeout) rather than
      blocking for the full duration.
- [x] Confirm the real `needs_kvm` boot test still passes (happy path:
      process stays alive the whole time, no regression to normal
      timing).

**Resolved**: implemented as part of the shared `_poll_until()` helper
(see #9) — every poll site now checks `self._process.poll()` on each
iteration and raises `FirecrackerProcessExited` (new exception, includes
exit code + full console log text) immediately on process death. Covered
by `test_wait_for_api_socket_fails_fast_when_process_exits` (fake binary
that `exit 1`s immediately; asserts the failure surfaces in well under
2s against a 5s timeout). Real boot test confirmed still passing at
normal speed.

## 5 — Swallowed exception in `stop()`'s reset attempt

- **File**: `agent-vm/host/src/agentvm/firecracker.py:132`
- **Problem**: `except Exception: pass` around the `SendCtrlAltDel` PUT
  discards *any* exception, including `_put()`'s
  `assert self._session is not None` (line 50) firing if `stop()` is
  called after a partial/failed `start()` (before `self._session` is
  assigned).
- **Failure scenario**: Once #1's cleanup-on-failure calls into
  process-killing logic that might route through `stop()` (or a shared
  helper), an `AssertionError` indicating a real programming bug (calling
  API methods before the session exists) would be silently discarded
  instead of surfacing.
- [x] Narrow the caught exception type to what's actually
      expected/recoverable here (network/API errors: `FirecrackerApiError`,
      `requests.RequestException`), not bare `Exception`.
- [x] Guard the `SendCtrlAltDel` attempt with `if self._session is not
      None:` (or equivalent) so it's simply skipped — not exception-caught
      — when `start()` never got that far, rather than relying on a swallowed
      `AssertionError` to paper over it.
- [x] This item is coupled to #3's decision: if `SendCtrlAltDel` is
      dropped entirely (option b), this finding may become moot — resolve
      #3 first and re-check whether this still applies.

**Resolved**: moot per #3 — `stop()` no longer sends `SendCtrlAltDel` (or
any other API call) at all, so there's no `except Exception: pass` left
to narrow and nothing that can hit `_put()`'s session assertion from
`stop()`. `_force_cleanup()` (used by `start()`'s failure path) also
never touches the API/session, only the raw process and file handle, so
it has no analogous exception to swallow either.

## 6 — Stale comment: says devtmpfs is mounted by pid1-init

- **File**: `agent-vm/nix/device1-v0.nix:18`
- **Problem**: Comment reads "B3's pid1-init mounts
  proc/sysfs/devtmpfs/tmpfs onto /proc /sys /dev /tmp at boot", but
  `agent-vm/guest/pid1-init/src/mount.rs`'s `pseudo_filesystem_mounts()`
  deliberately excludes devtmpfs (own doc comment there explains the
  kernel's `DEVTMPFS_MOUNT=y` already auto-mounts it, and a second manual
  mount fails `EBUSY` — confirmed by an actual boot in B4).
- **Failure scenario**: A future contributor trusting this stale comment
  instead of reading `mount.rs` could "fix" pid1-init by re-adding an
  explicit devtmpfs mount call, reintroducing the exact `EBUSY` boot
  failure chunk B4 already hit and fixed.
- [x] Update the comment in `device1-v0.nix` to match `mount.rs`'s
      actual behavior: pid1-init mounts proc/sysfs/tmpfs; `/dev` is still
      needed as an empty directory because the *kernel* auto-mounts
      devtmpfs onto it before init runs (not because pid1-init mounts it
      itself).
- [x] Cross-check every other comment/doc in the chunk B files
      (`guest-kernel.nix`, `guest-kernel-check.nix`, `device1-v0-check.nix`,
      `todo.md`) for the same "devtmpfs mounted by pid1-init" claim and
      fix any that repeat it.

**Resolved**: `device1-v0.nix`'s comment rewritten to explain the actual
split (pid1-init mounts proc/sysfs/tmpfs; the kernel itself auto-mounts
devtmpfs onto the pre-existing `/dev` directory) and cross-references
`mount.rs::pseudo_filesystem_mounts()` by path. Grepped
`agent-vm/nix/*.nix`, `todo.md`, and `mount.rs` for the stale claim —
`mount.rs` and `todo.md` already had it right (from the original B3/B4
work); only `device1-v0.nix` needed the fix.

## 7 — `vmlinux` copy relies on a fragile bare relative path

- **File**: `agent-vm/nix/guest-kernel.nix:117` (the `overrideAttrs` postInstall)
- **Problem**: `cp vmlinux $out/vmlinux` depends on (a) running with cwd
  still at the kernel build root, and (b) running *before* the upstream
  isModular `postInstall` `cd`s into a copied-out source tree — enforced
  only by prepending this snippet ahead of `previousAttrs.postInstall`,
  documented in a comment rather than structurally guaranteed.
- **Failure scenario**: A future nixpkgs revision that reorders its own
  postInstall internals, or changes where/whether `vmlinux` sits at
  postInstall time, breaks this silently with a confusing
  "cp: cannot stat 'vmlinux'" error — exactly the failure this was
  already hit and fixed during chunk B (see the session's build-log
  history).
- [x] Investigate whether nixpkgs' kernel builder already exposes a
      stable, absolute reference to the built `vmlinux` (e.g. via
      `$buildRoot` or a similar env var set by `build.nix`) that doesn't
      depend on cwd ordering. Check `pkgs/os-specific/linux/kernel/build.nix`
      in the pinned nixpkgs revision (`lon.nix` → `nixpkgs`) for such a
      variable.
- [x] If a stable path exists, reference it directly instead of the bare
      `vmlinux` relative path.
- [x] If no stable path exists, at minimum make the ordering dependency
      impossible to silently break: e.g. `test -f vmlinux || (echo
      "vmlinux not found at expected build-root location - nixpkgs'
      kernel postInstall internals may have changed ordering" >&2; exit
      1)` before the `cp`, so a future breakage fails loudly with a
      pointer to this comment instead of a bare "file not found".
- [x] Rebuild `guest-kernel` and `guest-kernel-check` from scratch
      (`nix-build agent-vm/nix -A guest-kernel-check`) to confirm the
      fix doesn't regress the working build.

**Resolved**: a stable path *does* exist. nixpkgs'
`pkgs/os-specific/linux/kernel/build.nix` (a) always adds a plain
`vmlinux` build target regardless of the `target` attribute (`buildFlags`
includes `"vmlinux"` unconditionally, "for perf and things like that"),
and (b) its own `isModular` postInstall block already does
`cp vmlinux $dev/` early on. Since this kernel has `MODULES = yes` (see
its own comment on why), it *is* `isModular` in nixpkgs' eyes, so `$dev`
already reliably contains `vmlinux` with zero custom code needed. Deleted
the entire `overrideAttrs`/custom-`postInstall` hack from
`guest-kernel.nix` and switched every consumer
(`guest-kernel-check.nix`, `test_firecracker_boot.py`) from
`${kernel}/vmlinux` to `${kernel.dev}/vmlinux`. This is strictly better
than the guard-and-hope fallback: it rides on nixpkgs' own already-tested
mechanism instead of a bolt-on. Rebuilt `guest-kernel-check` from scratch
(full kernel recompile, since the derivation changed) — passed, and the
real `needs_kvm` boot test passed against the new `.dev` output.

## 8 — Mount-point directories duplicated instead of derived from `mount.rs`

- **File**: `agent-vm/nix/device1-v0.nix:22`
- **Problem**: The `/proc /sys /dev /tmp` directories are a hand-written
  `mkdir -p` list in Nix, disconnected from
  `mount.rs::pseudo_filesystem_mounts()` — the actual source of truth for
  what pid1-init mounts (plus `/dev`, needed for the kernel's own
  devtmpfs auto-mount per #6).
- **Failure scenario**: Per `todo.md`, chunk H replaces this file with
  the real rootfs image closure. That new builder will have to
  re-duplicate this exact directory list by hand with no shared source
  of truth. A future change to `pseudo_filesystem_mounts()` (e.g. adding
  a new mount target) can silently fail to update the image-building Nix
  code, surfacing only as a boot-time mount failure (`ENOENT` on a
  missing mount point) — exactly the class of bug B3 already hit once
  with the original "just `/init`" image.
- [x] Decide the scope of the fix for *this* chunk: full automation
      (e.g. a generated file listing mount targets that both Rust and Nix
      read) is likely overkill for a throwaway v0 image due to be deleted
      in chunk H. Prefer a lighter fix: a code comment in
      `device1-v0.nix` that explicitly cross-references
      `mount.rs::pseudo_filesystem_mounts()` by name/path, so the two
      stay discoverable-in-sync even though not mechanically linked.
- [x] Add a note to chunk H's checklist in `todo.md` (H1) flagging that
      the real rootfs closure must independently ensure these same
      mount-point directories exist, and why.
- [x] If effort allows and it's cheap: add a unit test (in the Rust
      crate) that asserts `pseudo_filesystem_mounts()` only ever targets
      a fixed, known set of paths (`/proc`, `/sys`, `/tmp`) — a change
      to that set failing a test is a cheap tripwire that should prompt
      updating `device1-v0.nix` (and later chunk H) in the same PR.

**Resolved**: went with the lighter fix (full automation judged overkill
for a v0 image already scheduled for deletion in chunk H) — same edit as
#6 added the cross-reference comment in `device1-v0.nix`. Added a bullet
to chunk H's **H1** entry in `todo.md` flagging that the real rootfs
closure must independently ensure these mount-point directories exist.
The "cheap tripwire" unit test already exists and needed no new code:
`mount.rs`'s existing
`mounts_proc_sysfs_tmpfs_in_order_with_expected_options` test (from B3)
already asserts the exact fixed set (`len() == 3`, targets `/proc`,
`/sys`, `/tmp` by name) — any future change to that set fails this test,
which is exactly the intended tripwire. Added no duplicate test.

## 9 — Duplicated polling loops with inconsistent parameters

- **File**: `agent-vm/host/src/agentvm/firecracker.py:58` and `:108`
- **Problem**: `_wait_for_api_socket()` and `wait_for_console_string()`
  are near-identical deadline-polling loops that already differ
  arbitrarily: poll interval (0.05s vs 0.1s) and timeout-exception type
  (builtin `TimeoutError` vs custom `FirecrackerBootTimeout`).
- **Failure scenario**: A future third poll (e.g. waiting for guest
  shutdown, or a vsock connection in chunk C) will likely hand-roll a
  third variant instead of reusing shared logic, compounding
  inconsistent timeout/interval/exception semantics across the module
  and making all of them harder to fix together (e.g. for #4's
  process-death check, which should apply to every poll site).
- [x] Extract a private helper, e.g.:
      ```python
      def _poll_until(self, condition: Callable[[], bool], timeout: float,
                       interval: float, on_timeout: Callable[[], Exception]) -> None:
      ```
      or a simpler condition-returns-bool-or-raises variant — pick
      whichever reads more naturally against the two call sites without
      over-engineering for hypothetical future pollers.
- [x] Fold #4's "check process death every iteration" logic into this
      one shared helper, so both current call sites (and any future one)
      get it for free.
- [x] Re-run the full `pytest` suite (unit + `needs_kvm` boot test) to
      confirm behavior is unchanged for the happy path.

**Resolved**: added `_poll_until(condition, timeout, interval,
make_timeout_error)` to `FirecrackerVM`; both `_wait_for_api_socket()`
and `wait_for_console_string()` are now thin wrappers over it, each
keeping their own interval and timeout-exception factory (the two
deliberate differences are preserved, just no longer duplicated
plumbing). `_force_cleanup()` (a separate small helper, #1) was
deliberately kept distinct from `stop()`'s own terminate/kill sequence
rather than unified into one shared "kill" helper: `_force_cleanup()`
always does an immediate hard `kill()` (used only on the already-failed
`start()` path, where there's nothing graceful left to attempt), while
`stop()`'s normal path is `terminate()` then a timeout-bounded `wait()`
then `kill()` as a last resort — different enough semantics that forcing
them through one helper would need extra parameters for little benefit.
Full `pytest` suite (5 tests: cli + 3 new firecracker unit tests + the
real boot) and `cargo test --workspace` both green.

## 10 — Socket-path URL encoding only escapes `/`

- **File**: `agent-vm/host/src/agentvm/firecracker.py:46` (`_api_url`)
- **Problem**: `str(self.api_socket).replace("/", "%2F")` hand-rolls
  percent-encoding for exactly one character, instead of using
  `urllib.parse.quote`.
- **Failure scenario**: A socket path containing a `%`, space, or
  non-ASCII byte (e.g. under a differently-named tmp/home directory,
  or a session dir name derived from user input in a later chunk)
  produces a malformed `http+unix://` URL, causing a confusing
  connection failure instead of a correctly percent-encoded request.
- [x] Replace the manual `.replace()` with
      `urllib.parse.quote(str(self.api_socket), safe="")` (encode
      everything, since the whole path segment needs to survive being
      embedded in the authority-like position `requests_unixsocket`
      expects).
- [x] Add a small unit test constructing a `FirecrackerVM` with an
      `api_socket` path containing a character beyond `/` that needs
      escaping (e.g. a space) and asserting `_api_url()` produces the
      correctly encoded result — no real socket/process needed.
- [x] Re-run the `needs_kvm` boot test to confirm normal (non-exotic)
      paths still work.

**Resolved**: `_api_url()` now uses `urllib.parse.quote(str(self.api_socket),
safe="")`. Verified this round-trips correctly against
`requests_unixsocket`'s own decoding (`unquote(urlparse(url).netloc)`,
read directly from its installed source in this nixpkgs revision) rather
than assuming. Covered by
`test_api_url_percent_encodes_special_characters_round_trip`, using a
path with both a space and a `%` character. Real boot test (plain,
non-exotic tmp paths) still passes.

---

## Final sign-off

- [x] All ten items above checked off.
- [x] Full suite green: `pytest -v` (host, inside devshell) and
      `cargo test --workspace` (guest, inside devshell).
- [x] `nix-build agent-vm/nix -A guest-kernel-check -A device1-v0-check`
      (or per-attribute) still succeeds after the `guest-kernel.nix` and
      `device1-v0.nix` changes.
- [x] Real `needs_kvm` boot test (`test_boots_and_reaches_liveness`)
      passes end-to-end on this host.
- [x] `todo.md`'s chunk B entries updated if any of the above changes
      alter previously-recorded decisions (e.g. #3's stop() behavior,
      #6/#8's devtmpfs wording).
- [x] Commit and push.

`todo.md`'s existing chunk B checklist text didn't need further edits
beyond what was already done for chunk B itself (it never documented
`stop()`'s internal retry sequence at that level of detail); the H1 note
from #8 is the one addition. This file is archived to `archive/` after
the final commit, per the coordinator's instruction.
