---
component: workspace-and-repo-delivery-todo
source: 06-workspace-and-repo-delivery-plan.md
tags:
- agent-vm-host
- spec-todo
---
# Workspace & Repository Delivery — Build Checklist

A step's top-level box is a summary — check it only when every nested box under it is checked.

## Chunk 1 — Host-local git mirror maintenance

- [ ] **Step 1 — Host-local git mirror creation & on-demand fetch tool** [[06-workspace-and-repo-delivery-plan#Step 1.1 — Host-local git mirror creation & on-demand fetch tool]]
  - [ ] Standalone CLI tool: given a repo identifier (upstream clone URL + local name/slug), creates a full non-shallow bare mirror clone if none exists locally
  - [ ] If a mirror already exists, runs a fetch against it to bring every ref up to date with upstream
  - [ ] Single, one-shot, blocking invocation — no scheduling/timer/daemon behavior of any kind
  - [ ] Stores each repo's mirror at a stable, predictable on-disk path derived from its local name/slug
  - [ ] Verify: point at a throwaway local upstream repo; first invocation creates a full bare mirror clone at the stable path containing every branch/commit
  - [ ] Verify: add a new commit to the throwaway upstream, invoke again, confirm the existing mirror is fetched (not recreated) and now contains the new commit
  - [ ] Verify: invoke a third time with no upstream changes, confirm it completes cleanly with no error and no spurious duplicate mirror

## Chunk 2 — Git-http-backend service

- [ ] **Step 1 — git-http-backend wrapper: read-only, upload-pack-only** [[06-workspace-and-repo-delivery-plan#Step 2.1 — git-http-backend wrapper: read-only, upload-pack-only]]
  - [ ] Standalone, directly runnable long-lived process binds `127.0.0.1:<GIT_PORT>`
  - [ ] For each incoming HTTP request, invokes `git http-backend` as a CGI subprocess against the repo the request's path names, resolved to that repo's mirror path from Step 1
  - [ ] Only the `upload-pack` service is enabled (`git-upload-pack`, `info/refs?service=git-upload-pack`, plain dumb-HTTP fetches); `receive-pack` is not enabled or reachable under any request path
  - No allowlist, proxy, or network-facing policy logic here — loopback-only listener
  - [ ] Verify: start the wrapper pointed at a mirror from Step 1; from a plain git client on the host (not via guest/proxy) confirm `git ls-remote http://127.0.0.1:<GIT_PORT>/<repo>.git`, `git clone --depth=1 ...`, and log/fetch-based history browsing all succeed
  - [ ] Verify: a `git push` attempt (or a direct `git-receive-pack` request) fails at this layer, not merely blocked upstream
- [ ] **Step 2 — Host-wide singleton systemd unit for the git service** [[06-workspace-and-repo-delivery-plan#Step 2.2 — Host-wide singleton systemd unit for the git service]]
  - [ ] Write the systemd unit file for `agentvm-git-service.service`: `ExecStart=` runs the wrapper directly (no shell wrapper), starts automatically at boot/host-service enablement, keeps running indefinitely as a long-lived foreground process
  - [ ] Restart policy appropriate for a long-lived singleton service that recovers from a crash on its own (unlike per-session units' `Restart=no`)
  - [ ] No `Requires=`/`After=`/`BindsTo=` edges pointing at this unit from anywhere
  - [ ] Define one throwaway test systemd unit, for verification only, with `Requires=`+`After=` pointing at `agentvm-git-service.service`, explicitly noted as a simulated stand-in for a real session's VM unit
  - [ ] Verify: `systemctl start agentvm-git-service.service` reports active/running
  - [ ] Verify: repeat Step 1's plain-git-client checks (ls-remote, shallow clone, receive-pack rejection) against the now-systemd-managed process — behavior unchanged
  - [ ] Verify: start the throwaway test unit, confirm systemd brings `agentvm-git-service.service` up first (or leaves it up) before starting the test unit
  - [ ] Verify: stop the test unit, confirm `agentvm-git-service.service` remains running, unaffected
  - [ ] Remove the throwaway test unit once proven

## Chunk 3 — Per-guest workspace block-device content

- [ ] **Step 1 — Device 2: shallow-clone workspace-checkout image** [[06-workspace-and-repo-delivery-plan#Step 3.1 — Device 2: shallow-clone workspace-checkout image]]
  - [ ] Standalone tool: given a repo identifier (resolving to a Step-1 mirror) + a pinned commit, performs a shallow (`--depth=1`) clone of that exact commit from the local mirror into a temp working directory
  - [ ] Rewrites the checkout's `origin` remote URL to point at the git service (`http://127.0.0.1:<GIT_PORT>/<repo>.git`), not the local mirror path
  - [ ] Packages the resulting directory (working tree + real tiny `.git` directory) into a read-only filesystem image via `mksquashfs` at a given output path
  - Image format (`mksquashfs`) is an open, flagged choice — spec only names "squashfs/erofs," no decision resolves it for this directory-tree case — note explicitly as open for confirmation
  - [ ] Verify: run against a mirror + pinned commit from Step 1's test upstream; loop-mount the produced image read-only, confirm the working tree matches the pinned commit's content exactly
  - [ ] Verify: `.git` directory is present and real (not a stub); its configured `origin` remote is the git service URL, not the local mirror's filesystem path
  - [ ] Verify: with `agentvm-git-service.service` from Chunk 2 running and serving the same mirror, `cd` into the mounted image and run `git fetch` (or `git log --all`) against its configured `origin` — succeeds and retrieves history beyond the single pinned commit
- [ ] **Step 2 — Device 3: empty writable overlay image** [[06-workspace-and-repo-delivery-plan#Step 3.2 — Device 3: empty writable overlay image]]
  - [ ] Standalone tool: given an output path and a size, creates a small, empty ext4 filesystem image at that path, ready to be attached as a guest's device 3
  - [ ] Verify: produced file is a valid ext4 filesystem, empty beyond the filesystem's own reserved structures
  - [ ] Verify: loop-mount read-write on host, write a test file, unmount, loop-mount again, confirm the test file is still present
  - [ ] Verify: run the tool twice at two different output paths, confirm each produces an independent, distinct image with no shared state

## Chunk 4 — Result extraction & review

- [ ] **Step 1 — Result extraction & review: device-3-only diff** [[06-workspace-and-repo-delivery-plan#Step 4.1 — Result extraction & review: device-3-only diff]]
  - [ ] Standalone tool: given a completed session's device-3 image path, plus the repo identifier + pinned commit that session's device-2 workspace was built from, loop-mounts device 3 read-only
  - [ ] Walks device 3 to build a change-set per overlayfs upperdir conventions: regular file present = added/modified, char-device whiteout (major/minor 0/0) = deleted, `trusted.overlay.opaque` xattr = directory contents replaced
  - [ ] For each changed path, retrieves the corresponding blob at the pinned base commit directly from the repo's local mirror (no need to mount device 2) and renders a standard unified diff for that path
  - [ ] Assembles every path's diff into one combined unified diff covering the whole change-set
  - [ ] Unmounts device 3 when done, leaving it unmodified
  - Does not implement any interactive pager/viewer — emits plain unified-diff text for `delta`/`less` to consume
  - [ ] Verify: using Chunk 3 Step 2's tool, create a device-3 image; mount it (host-side test harness) as overlayfs upper against a Chunk 3 Step 1 device-2 image as lower; through the merged view modify one existing file, create one new file, delete one existing file; unmount, leaving device 3 holding exactly those three changes in upperdir form
  - [ ] Verify: run the extraction tool against that device-3 image + the same repo/commit device 2 was built from — produced unified diff shows the modification as a changed-content hunk, the new file as an added-file diff, the deleted file as a removed-file diff, nothing else present
  - [ ] Verify: run the extraction tool a second time against the same, now-unmodified-since device-3 image — produces an identical diff and leaves device 3 unchanged (read-only + idempotent)

## Related

- [[06-workspace-and-repo-delivery]] — the spec this plan implements.
- [[06-workspace-and-repo-delivery-plan]] — the plan this checklist tracks.
