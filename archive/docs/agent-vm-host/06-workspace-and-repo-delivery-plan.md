---
component: workspace-and-repo-delivery-plan
source: 06-workspace-and-repo-delivery.md
tags:
- agent-vm-host
- spec-plan
---

# Workspace & Repository Delivery — Implementation Plan

## Blueprint

[[06-workspace-and-repo-delivery]] specifies how the guest gets code without
ever reaching GitHub directly: a host-local full-mirror clone kept fresh
on-demand right before each launch, a read-only git-protocol service
exposing only `upload-pack` over the host's own loopback, the two
host-built content devices (workspace checkout, writable overlay) that ride
the three-block-device layout Firecracker attaches, and a post-session
extraction/diff path for manual review. Nothing in this component exists
yet. The finished state this plan builds toward: a callable mirror-
maintenance tool; a `git-http-backend` wrapper running as its own host-wide
singleton systemd service, read-only by construction; a device-2 build tool
producing a shallow-clone workspace-checkout image whose one remote points
at that service, and a device-3 build tool producing a small, empty
writable ext4 image; and a post-session tool that loop-mounts only device
3, reconstructs its change-set from overlayfs upperdir semantics, and
renders a terminal-viewable unified diff against the pinned base commit.

Build order follows the spec's own dependency chain: the git-http-backend
service has nothing to serve until a mirror exists, so mirror maintenance
comes first; the service itself must be live and read-only-enforced before
anything downstream can be shown to reach it correctly; device 2's shallow
clone is only meaningfully wired once it can point its remote at a real,
running service and be proven to actually fetch through it; device 3 has
no dependency on any of the above but is grouped alongside device 2 since
both are "per-guest workspace content" the same downstream consumer (the
guest's overlayfs mount) expects together; and result extraction is last
because it consumes a device-3 artifact that must already exist and have
been written to by a realistic session before there is anything to
extract.

This plan does not build: the Firecracker device/vsock model or the
three-block-device attachment ([[03-vmm-firecracker]], already planned at
[[03-vmm-firecracker-plan#Step 3 — Full block-device model: three virtio-block devices]]),
the guest-side overlayfs mount that combines devices 2 and 3 inside the
guest ([[04-guest-pid1-init]], already planned at
[[04-guest-pid1-init-plan#Step 1.2 — Block-device mounts & overlayfs workspace assembly]]),
device 1's rootfs image ([[09-guest-rootfs]], already planned in
[[09-guest-rootfs-plan]]), the proxy path or the loopback allowlist entry
that gates guest reachability to the git service
([[05-network-egress-control]] — this component's own upload-pack-only
backend config is the actual read-only enforcement per the spec; the
proxy's `git-receive-pack` path rejection is defense-in-depth on top of it,
built at
[[05-network-egress-control-plan#Step 3.2 — Real allowlist entries, git-receive-pack rejection, package-registry gap]]),
BPF's independent audit trail ([[07-bpf-monitoring]]), and the session unit
graph, `launch`/`stop` CLI, and `Requires=`/`After=` wiring from a
session's VM unit to this component's host-wide singleton service
([[10-session-lifecycle-orchestration]], which has no plan note yet). Where
a step needs a stand-in for one of those (a direct call in place of a real
`launch`, a throwaway test unit declaring `Requires=`/`After=`), that is
called out explicitly as throwaway/simulated, not as that component's real
deliverable.

**Open gap check:** [[15-decisions-log]] tags exactly one resolved decision
against this spec — "`git-http-backend` wrapping" (a small custom wrapper
using stdlib `http.server` invoking `git http-backend` as CGI per request,
not a general-purpose CGI runner) — folded into Step 2.1 below, not
re-derived. No item in that log's "Still open" section is tagged against
this spec. This plan flags one further gap of its own, from spec silence
rather than the decisions log: §6's three-block-device table names device
2's image format only as "squashfs/erofs," picking neither, and no
decisions-log entry resolves it — the log's only related format decision
([[09-guest-rootfs-plan#Step 1 — Self-contained, whitelisted-tool Nix closure]],
"Nix closure isolation mechanism") is specific to packaging a Nix-store
closure and does not transfer to device 2, which packages a plain
checked-out directory tree. Flagged explicitly at Step 3.1, with
`mksquashfs` kept as a working default so the step stays actionable rather
than blocked.

## Chunks

1. **Chunk 1 — Host-local git mirror maintenance.** The on-demand mirror
   creation/fetch tool every downstream chunk depends on for content.
   (Step 1.1)
2. **Chunk 2 — Git-http-backend service.** The read-only `upload-pack`-only
   wrapper and its host-wide singleton systemd unit. (Steps 2.1–2.2)
3. **Chunk 3 — Per-guest workspace block-device content.** Device 2's
   shallow-clone checkout image and device 3's empty writable overlay
   image. (Steps 3.1–3.2)
4. **Chunk 4 — Result extraction & review.** The post-session
   device-3-only diff tool. (Step 4.1)

---

## Step 1.1 — Host-local git mirror creation & on-demand fetch tool

Chunk 1, single step. Foundation — no prior step exists yet in this plan.

```text
You are building a component of a Firecracker-based guest VM subsystem's
workspace-and-repository-delivery path, from its specification, from
scratch. Nothing has been implemented for this component yet.

Specification facts to ground this task in: the host keeps full local
mirror clones of relevant repositories — not shallow, not
on-demand-per-file — to cut latency and enable local dedup/reuse. The guest
never reaches GitHub directly; everything it can eventually see comes from
this host-local mirror. The host fetches/updates its local mirror from
upstream on-demand, immediately before each task launch — not on a
periodic background timer. Every session is meant to start from fresh
upstream state, and launch time is expected to include the cost of one
fetch. There is no central daemon anywhere in this subsystem
([[10-session-lifecycle-orchestration]]) — every host-side action is a
one-shot, separately-invoked call, not a long-lived background process.

Task: build a standalone CLI tool that, given a repository identifier (its
upstream clone URL and a local name/slug), does one of two things
depending on whether a bare mirror clone for that identifier already
exists locally: if not, creates one via a full (non-shallow) bare clone of
the upstream URL; if one already exists, runs a fetch against it to bring
every ref up to date with upstream. The tool must be a single, one-shot,
blocking invocation — it performs its work synchronously and exits, with
no scheduling, timer, or daemon behavior of any kind built into it, so that
"on-demand, immediately before each task launch" is satisfied purely by
whoever calls it once per launch (a future orchestration component, not
built here), not by anything this tool does on its own. Store each
repository's mirror at a stable, predictable on-disk path derived from its
local name/slug, so a later invocation for the same repository finds and
updates the same mirror rather than creating a duplicate.

Verify: point the tool at a throwaway local upstream repository (a plain
git repo you create for this test, standing in for a real GitHub upstream
— no real network dependency needed to prove this). First invocation:
confirm a full bare mirror clone is created at the stable path, containing
every branch/commit from the throwaway upstream. Add a new commit to the
throwaway upstream, then invoke the tool again with the same repository
identifier: confirm the existing mirror is fetched (not recreated) and now
contains the new commit. Invoke the tool a third time with no upstream
changes: confirm it completes cleanly with no error and no spurious
duplicate mirror. This proves the tool is both create-or-update and safely
idempotent — the exact contract "immediately before every launch" needs,
once a future orchestration step starts calling it that way.
```

---

## Step 2.1 — git-http-backend wrapper: read-only, upload-pack-only

Chunk 2, first step. Builds on Step 1.1's mirror — this is what the
wrapper serves.

```text
Context already built: a standalone CLI tool that creates or fetches a
bare, full-history local mirror clone of a repository at a stable on-disk
path, one-shot and idempotent, with no scheduling behavior of its own.

Specification facts for this task: the host runs git-http-backend bound to
127.0.0.1:<GIT_PORT>, serving the mirror over plain HTTP — no TLS needed,
since this leg never leaves the host's own loopback interface. It is
configured to expose only the upload-pack service (fetch/clone/ls-remote);
receive-pack is not wired up at all. That is the actual read-only
enforcement for this whole design — it lives in the git server's own
configuration, not in any proxy rule sitting in front of it (a proxy-side
rejection of git-receive-pack against this same address is built
independently, as defense-in-depth, at
[[05-network-egress-control-plan#Step 3.2 — Real allowlist entries, git-receive-pack rejection, package-registry gap]]
— not built here).

A settled build decision, already resolved and not to be re-derived (see
[[15-decisions-log]]'s "`git-http-backend` wrapping" entry): implement this
as a small custom wrapper using the standard library's `http.server`,
invoking `git http-backend` as CGI per incoming request — not a
general-purpose CGI runner, and not any other existing HTTP-server-plus-CGI
framework.

Task: build this wrapper as a standalone, directly runnable long-lived
process (matching how a systemd service would eventually exec it — the
unit file itself is the next, separate step) that: binds
`127.0.0.1:<GIT_PORT>` (a fixed, well-known port for this component); for
each incoming HTTP request, invokes `git http-backend` as a CGI subprocess
against the repository the request's path names, resolved to that
repository's mirror path from the previous step's stable on-disk layout;
sets the environment/configuration so that only the `upload-pack` service
(`git-upload-pack`, `info/refs?service=git-upload-pack`, and plain
dumb-HTTP file fetches as needed) is enabled, with `receive-pack` not
enabled or reachable through this wrapper under any request path. Do not
add any allowlist, proxy, or network-facing policy logic here — this
process only ever listens on the host's own loopback interface; guest
reachability through the vsock/proxy path is a different, already
independently-built component.

Verify: start the wrapper pointed at a mirror created by the previous
step's tool. From a plain git client running directly on the host (not
through any guest or proxy path), confirm `git ls-remote
http://127.0.0.1:<GIT_PORT>/<repo>.git`, `git clone --depth=1
http://127.0.0.1:<GIT_PORT>/<repo>.git`, and `git log`/fetch-based history
browsing against that clone all succeed. Confirm a `git push` attempt (or
a direct `git-receive-pack` request against the same URL) fails at this
layer — not merely blocked upstream — proving receive-pack is genuinely
unwired in the backend's own configuration, independent of any proxy rule.
```

## Step 2.2 — Host-wide singleton systemd unit for the git service

Chunk 2, second step. Builds directly on Step 2.1's wrapper program.

```text
Context already built: a standalone, directly runnable git-http-backend
wrapper process (stdlib http.server invoking git http-backend as CGI per
request) bound to 127.0.0.1:<GIT_PORT>, upload-pack-only, proven against a
plain host-side git client.

Specification facts for this task: this service runs as its own host-wide
singleton systemd service (`agentvm-git-service.service`), independent of
any session's lifecycle — started independently of any session and
outliving all of them, per [[10-session-lifecycle-orchestration]]. Every
session's VM unit is meant to declare a one-way `Requires=`+`After=`
dependency on this unit (must be up before that session starts, but this
unit's own lifetime is never coupled to any one session) — building that
session-side dependency edge, the session unit graph itself, and the
`launch`/`stop` CLI that renders it are
[[10-session-lifecycle-orchestration]]'s job, which has no plan note yet;
this task builds only this unit's own definition, not anything that
depends on it.

Task: write the systemd unit file for `agentvm-git-service.service`: a
service unit whose `ExecStart=` runs the wrapper program from the previous
step directly (no shell wrapper), configured to start automatically at
boot or on host-service enablement (independent of any session), and to
keep running indefinitely as a long-lived foreground process rather than a
one-shot. Give it a restart policy appropriate for a long-lived singleton
service that should recover from a crash on its own (unlike this
subsystem's per-session units, which are deliberately `Restart=no` — this
unit is not per-session and has no session-scoped state to lose). Do not
add any `Requires=`/`After=`/`BindsTo=` edges pointing at this unit from
anywhere — that direction of dependency belongs to a session's own VM
unit, not built here.

To prove the ordering contract this unit is meant to support without
waiting for a real session unit graph to exist, define one throwaway test
systemd unit purely for this task's own verification, with a
`Requires=`+`After=` edge pointing at `agentvm-git-service.service`, and
note explicitly in your output that this test unit is a simulated stand-in
for a real session's VM unit, not [[10-session-lifecycle-orchestration]]'s
actual deliverable.

Verify: `systemctl start agentvm-git-service.service` and confirm it
reports active/running; repeat the previous step's plain-git-client checks
(`ls-remote`, shallow clone, receive-pack rejection) against the
now-systemd-managed process to confirm behavior is unchanged from running
it directly. Start the throwaway test unit and confirm systemd brings
`agentvm-git-service.service` up first (or leaves it up, if already
running) before starting the test unit, proving the `Requires=`+`After=`
ordering works as the future session unit graph will rely on it. Stop the
test unit and confirm `agentvm-git-service.service` remains running,
unaffected — proving its lifetime is not coupled to the (simulated)
session-side unit, exactly as the "outliving all of them" framing
requires. Remove the throwaway test unit once this is proven; it exists
only for this verification.
```

---

## Step 3.1 — Device 2: shallow-clone workspace-checkout image

Chunk 3, first step. Builds on Step 1.1's mirror content and Step 2.2's
live git service (needed for this step's own remote-wiring verification).

```text
Context already built: a host-local mirror-maintenance tool (create-or-
fetch, one-shot, idempotent) and a running `agentvm-git-service.service`
singleton wrapping git-http-backend, upload-pack-only, bound to
`127.0.0.1:<GIT_PORT>`.

Specification facts for this task: device 2 in the guest's
three-block-device layout is a workspace checkout — a read-only filesystem
image built from a checkout of the local mirror at a pinned commit, shared
across all concurrently-running tasks on that commit, rebuilt per commit
(not per session). It is built as a shallow clone (`--depth=1`) of the
pinned commit from the local mirror, not a bare file export, giving the
guest a real (if tiny) `.git` directory with exactly one remote
configured: `http://127.0.0.1:<GIT_PORT>/<repo>.git` — this component's own
git service, never GitHub and never the raw local mirror path. Startup
cost barely changes versus a flat checkout (still one commit's worth of
objects), but the guest's own git client can later extend history on
demand (fetch more commits, blame, browse branches) through that one
configured remote.

Open gap, flagged rather than resolved here: the image format is named
only as "squashfs/erofs" in the spec, with no decision between them, and
no decisions-log entry resolves it for this directory-tree case (device
1's Nix-closure-specific squashfs helper,
[[09-guest-rootfs-plan#Step 1 — Self-contained, whitelisted-tool Nix closure]],
doesn't transfer — it packages a Nix store closure, not a plain
checked-out tree). Default to `mksquashfs` for this task so the step stays
actionable, and note this substitution explicitly in your output as an
open choice for confirmation, not a settled decision.

Task: build a standalone tool that, given a repository identifier
(resolving to a mirror already maintained by Step 1.1's tool) and a pinned
commit, performs a shallow (`--depth=1`) clone of that exact commit from
the local mirror into a temporary working directory, then rewrites that
checkout's `origin` remote URL to point at this component's git service
(`http://127.0.0.1:<GIT_PORT>/<repo>.git`) rather than the local mirror
path the shallow clone actually pulled from, then packages the resulting
directory (working tree plus its now-real, tiny `.git` directory) into a
read-only filesystem image at a given output path using `mksquashfs` (per
the open gap above).

Verify: run the tool against a mirror and pinned commit from Step 1.1's
test upstream. Loop-mount the produced image read-only and confirm: the
working tree matches exactly the pinned commit's content; the `.git`
directory is present and real (not a stub); its configured `origin` remote
is the git service URL, not the local mirror's filesystem path. With
`agentvm-git-service.service` from Step 2.2 running and serving the same
mirror, `cd` into the mounted image and run `git fetch` (or `git log
--all`) directly against its configured `origin`: confirm it succeeds and
can retrieve history beyond the single pinned commit, proving the remote
wiring is genuinely functional end to end, not just a correctly-formatted
string.
```

## Step 3.2 — Device 3: empty writable overlay image

Chunk 3, second step. Independent of Step 3.1's git content — builds only
on the plan's general on-disk-image conventions.

```text
Context already built: a device-2 build tool producing a read-only
squashfs image of a shallow-clone workspace checkout, with its `.git`
remote pointed at this component's own git service.

Specification facts for this task: device 3 in the guest's
three-block-device layout is a small, empty ext4 image — the per-task
writable overlay, read-write, scoped to one task only (never shared or
reused across tasks, unlike devices 1 and 2). The guest combines this
device (as overlayfs upper) with device 2 (as overlayfs lower) inside the
guest to produce the merged, writable workspace view — that guest-side
mount is already built, at
[[04-guest-pid1-init-plan#Step 1.2 — Block-device mounts & overlayfs workspace assembly]];
this task only produces the empty image device 3 itself, never mounts or
overlays it.

Task: build a standalone tool that, given an output path and a size,
creates a small, empty ext4 filesystem image at that path, ready to be
attached as a guest's device 3.

Verify: run the tool and confirm the produced file is a valid ext4
filesystem, empty of any content beyond the filesystem's own reserved
structures. Loop-mount it read-write on the host, write a test file into
it, unmount, then loop-mount it again and confirm the test file is still
present — proving it round-trips as a genuine writable filesystem, not an
inert placeholder file. Run the tool twice at two different output paths
and confirm each produces an independent, distinct image (no shared state
between two per-task images), matching the "per-task only" reuse scope
this device requires.
```

---

## Step 4.1 — Result extraction & review: device-3-only diff

Chunk 4, single step, closing the plan. Builds on Step 1.1's mirror (for
base-commit blob access) and Step 3.2's empty-image tool (to construct a
realistic test session's device 3 for verification), plus Step 3.1's
device-2 image (used only as this step's own test-harness lower layer, not
mounted by the tool it builds).

```text
Context already built: a mirror-maintenance tool (Step 1.1), a
git-http-backend singleton service (Chunk 2), a device-2 build tool
producing a pinned-commit shallow-clone image with its remote wired to
that service (Step 3.1), and a device-3 build tool producing an empty,
writable ext4 image (Step 3.2).

Specification facts for this task: after a session ends, no automatic git
integration happens — nothing is applied to any branch, committed, or
pushed automatically. The host loop-mounts only device 3 (the small
writable overlay) to extract the changed files; it does not mount device 2
for this. The extracted result is presented as a terminal-based diff
(standard unified diff / `git diff` against the pinned base commit,
viewable via existing tools like `delta`/`less`) for manual review — this
fits the terminal-first interaction model used throughout the design, so
this task must not build any custom diff-rendering UI, only produce
standard unified-diff-format output that hands off cleanly to those
existing tools.

Implementation grounding needed for this task, not a guess: an overlayfs
upper directory (this design's device 3, once a session has actually
written to the merged workspace through it) represents changes using
standard, documented overlayfs conventions — a modified or newly-created
regular file appears directly in the upper directory at its path; a
deleted file is represented by a character-device whiteout entry
(major/minor 0/0) at that path; a directory whose entire contents were
replaced is marked with a `trusted.overlay.opaque` extended attribute.
Reconstructing "what changed" from device 3 alone means walking its
contents and interpreting exactly these three cases — there is no other
source of truth on device 3 for what changed, since it never contains the
unmodified lower-layer (device 2) content itself.

Task: build a standalone tool that, given a completed session's device-3
image path, and the repository identifier plus pinned commit that
session's device-2 workspace was built from (Step 3.1's inputs, assumed
already known from that session's launch record — not re-derived here):
loop-mounts device 3 read-only, walks it to build a change-set (added,
modified, or deleted path, per the overlayfs upperdir conventions above),
and for each changed path retrieves the corresponding blob at the pinned
base commit directly from the repository's local mirror (Step 1.1's
on-disk mirror path — no need to mount device 2 for this comparison) to
render a standard unified diff for that path; assembles every path's diff
into one combined unified diff covering the whole change-set; unmounts
device 3 when done, leaving it unmodified. Do not implement any
interactive pager or viewer — emit plain unified-diff text that a caller
can pipe into `delta` or `less` themselves.

Verify: using Step 3.2's tool, create a device-3 image, then independently
mount it (host-side, purely as this task's own test harness — not reusing
guest boot machinery) as the overlayfs upper layer against a device-2
image from Step 3.1 as the lower layer, and through that merged view:
modify one existing file, create one new file, and delete one existing
file, then unmount the merged view (leaving device 3 holding exactly those
three changes in upperdir form). Run this task's extraction tool against
that device-3 image and the same repository/commit device 2 was built
from: confirm the produced unified diff shows the modification as a
changed-content hunk, the new file as an added-file diff, and the deleted
file as a removed-file diff, with nothing else present. Run the extraction
tool a second time against the same, now-unmodified-since device-3 image
and confirm it produces an identical diff and leaves device 3 unchanged —
proving extraction is read-only and idempotent. This closes the plan:
mirror maintenance, the read-only git service, both per-guest content
devices, and post-session review are now all built and provable, matching
every property [[06-workspace-and-repo-delivery]] specifies.
```

## Related

- [[06-workspace-and-repo-delivery]] — the spec this plan implements.
- [[15-decisions-log]] — resolved "`git-http-backend` wrapping" folded into
  Step 2.1; no open item tagged against this spec; this plan's own
  device-2-image-format gap is flagged at Step 3.1 instead of guessed.
- [[05-network-egress-control-plan]] — Step 3.2 builds the loopback
  allowlist entry and `git-receive-pack` proxy-side rejection that gate
  guest reachability to this component's service; this plan's Step 2.1
  builds the actual read-only enforcement that rejection backs up as
  defense-in-depth.
- [[03-vmm-firecracker-plan]] — Step 3 attaches all three block devices,
  including this plan's device 2 and 3 artifacts, at fixed guest slots.
- [[04-guest-pid1-init-plan]] — Step 1.2 mounts devices 2 and 3 via
  overlayfs inside the guest, consuming the images this plan's Steps
  3.1–3.2 produce; not rebuilt here.
- [[09-guest-rootfs-plan]] — owns device 1; its Step 1 Nix-closure
  squashfs helper is a related but distinct format decision that doesn't
  transfer to this plan's device-2 image (flagged at Step 3.1).
- [[07-bpf-monitoring]] — independent audit trail on top of this
  component's own read-only enforcement and the proxy's defense-in-depth
  rejection; not built here.
- [[10-session-lifecycle-orchestration]] — owns the host-wide-singleton
  framing this plan's Step 2.2 unit fits into, the session VM unit's
  `Requires=`/`After=` edge onto it (simulated with a throwaway test unit
  in Step 2.2), and the future `launch`/`stop` calls into this plan's
  mirror-fetch, device-2/3 build, and extraction tools; has no plan note
  yet.
