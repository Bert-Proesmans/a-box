---
tags:
  - spec
  - volatile-host
status: draft
---
# 01 Publisher

Index: [[00-index]]. Rationale: [[decisions#D5 Published pointer: unsigned file, signed closure]], [[decisions#D6 Personal cache hosting: GitHub Pages, static nix cache layout]], [[decisions#D7 Main UKI built in CI as part of the toplevel closure]], [[decisions#D9 Bad release recovery: operator re-runs the workflow on an older ref]], [[decisions#D11 Up-to-date check compares the ESP UKI file hash]], [[decisions#D19 Publish trigger: GitHub Actions, manual dispatch]], [[decisions#D20 Cache retention: latest release only]], [[decisions#D21 Updater UKI is frozen after provisioning]], [[decisions#D22 Acceptance: NixOS VM test]], [[decisions#D26 Release closure: one symlink-farm store path]].

Builds the release closure from the class configuration of [[03-main-base]], signs it, assembles the cache site and the pointer, and deploys to GitHub Pages. Owns the CI-side derivations `main.efi` (wrapper) and `release`. Each run publishes one release, the latest, and replaces everything that was on the site ([[decisions#D20 Cache retention: latest release only]]).

## Interfaces

`<site-root>` is `https://<owner>.github.io/<repo>` with no trailing slash. Its default is one constant, kept in a file in the repo that both the workflow and the updater build read; the updater bakes it ([[decisions#D21 Updater UKI is frozen after provisioning]]). The site build step (Behavior, steps 1 to 4) takes `<site-root>` as a parameter, so the VM test can pass its local server URL to both the site build and the updater build.

Output, consumed by [[02-updater]]:

| Path | Content |
|---|---|
| `nix-cache-info` | `StoreDir: /nix/store`; written by `nix copy --to file://`, not by a separate step |
| `<store-hash>.narinfo`, `nar/*` | static nix binary cache (NARs xz-compressed, the `nix copy` default); every narinfo signed with the cache key |
| `pointer` | one line, the cache URL of the release's narinfo |

`nix copy --to file://` also creates empty `log/` and `realisations/` directories. They are ignored by the updater and harmless in the Pages artifact.

Pointer format ([[decisions#D5 Published pointer: unsigned file, signed closure]]): a regular text file, one line, `<site-root>/<32-char nix-base32 store hash>.narinfo`, one trailing newline. It is a symlink by convention only; the Pages artifact cannot contain real symbolic links.

The pointer carries no hash. The UKI content hash is the `NarHash` in the signed narinfo of the UKI ([[decisions#D11 Up-to-date check compares the ESP UKI file hash]]). The narinfo spells it in nix-base32 (`sha256:<base32>`); `nix path-info --json --json-format 1` and `nix hash path` spell it as SRI (`sha256-<base64>`). Same value, different encoding; the updater compares the SRI forms.

Release closure ([[decisions#D26 Release closure: one symlink-farm store path]]), the object the pointer names:

```
<release>/toplevel -> /nix/store/<hash>-nixos-system-...
<release>/main.efi -> /nix/store/<hash>-main.efi    (single regular file, mode 0444)
```

Its `References` are exactly those two store paths.

Consumes from [[03-main-base]]: the class configuration attribute `system` (the NixOS evaluation of the host class, as in the archive's README), with `boot.uki` enabled: `system.config.system.build.toplevel` and `system.config.system.build.uki`. `system.build.uki` is a directory containing one `<name>_<version>.efi` (read from the pinned `nixos` source, not built).

## Trigger

The operator clicks the workflow button in the GitHub UI ([[decisions#D19 Publish trigger: GitHub Actions, manual dispatch]]). `workflow_dispatch` is the only trigger and takes no inputs. The workflow builds the ref selected in the dispatch UI. There are no tags and no release keys.

- `concurrency` group `pages-publish`, `cancel-in-progress: false`: a second click queues behind the first. This is not a failure.
- The cache signing key is an Actions secret. The matching public key is baked into [[02-updater]].
- Recovery from a bad release is the same button with an older ref selected ([[decisions#D9 Bad release recovery: operator re-runs the workflow on an older ref]]).

## Behavior

The site directory is produced by a build step that does not depend on Pages upload, so the VM test ([[decisions#D22 Acceptance: NixOS VM test]]) reuses it with a local server. Steps 1 to 4 produce it; steps 5 and 6 gate and upload. The live site is never read.

Inputs of the build step: `<site-root>`, the signing key, and the cache.nixos.org lookup of step 2. In CI the lookup is live. The VM test supplies a test signing key, its own `<site-root>`, and a lookup that excludes nothing (the offline VM has no cache.nixos.org, so every closure path goes on the test site). "Served unchanged" for the VM test means the server adds nothing to and removes nothing from the directory; it does not mean the same bytes as production.

1. Check out the selected ref. Install nix. In the flake-less lon-pinned entry point ([[decisions#D22 Acceptance: NixOS VM test]]) build, with `nix-build -A <attr>` (attribute names fixed at implementation): the toplevel and `system.build.uki` of `system`; the wrapper `main.efi` (copies the `.efi` from `system.build.uki` into a single-file store object and runs `chmod 0444` before the output is finalized, [[decisions#D7 Main UKI built in CI as part of the toplevel closure]]; the wrapper fails unless `system.build.uki` contains exactly one `*.efi`); and the `release` symlink farm. The wrapper and `release` are not part of `system.build.toplevel`.
2. Decide which closure paths go on the site: for each store path in the closure of `release`, `HEAD https://cache.nixos.org/<hash>.narinfo` (no signature check at publish time). 200 excludes the path, 404 includes it, anything else fails the run. The release, toplevel and UKI are never on cache.nixos.org, so they are always included.
3. Sign each included path with the cache key (`nix store sign`) and copy it into an empty site directory as a binary cache (`nix copy --to file://<site-dir>` style, xz). This also writes `nix-cache-info`.
4. Write `pointer`.
5. Fail if the site directory exceeds 1 GB (10^9 bytes, `du -sb`; the Pages limit, [[decisions#D6 Personal cache hosting: GitHub Pages, static nix cache layout]]). The limit is a parameter of the check so a test can lower it. No deploy.
6. Upload the site directory as the Pages artifact and deploy (`actions/upload-pages-artifact`, `actions/deploy-pages`; Pages source set to GitHub Actions). The deploy replaces the whole site.

[INFERENCE] The default `github-pages` environment may restrict deployments to the default branch, which would reject the rollback case of an older ref ([[decisions#D9 Bad release recovery: operator re-runs the workflow on an older ref]]). The environment's branch rules may need to allow the refs the operator uses. Check when the workflow is first set up.

## Data and state

No state outside the Pages site and the signing secret. The site holds exactly one release; the workflow does not look at what was there before.

## Failure modes

Failures in steps 1 to 5 stop the run before upload; the live site and pointer are unchanged. The deploy row is the exception: it fails in step 6.

| Failure | Result |
|---|---|
| Build failure; `system.build.uki` does not contain exactly one `.efi` (the wrapper fails) | run fails |
| Signing secret missing or unusable key | run fails |
| cache.nixos.org lookup returns anything other than 200 or 404 | run fails |
| Site exceeds 1 GB | run fails |
| Pages deploy fails or times out (10 min, [[decisions#D6 Personal cache hosting: GitHub Pages, static nix cache layout]]) | deploy fails; [INFERENCE] the previous site stays live, because Pages publishes a whole artifact. Verify during implementation |

Risk, not a failure: a path excluded because cache.nixos.org had it can later be evicted from there, which would make the latest release unfetchable until the next publish. cache.nixos.org gives no retention guarantee (Open gaps in [[00-index]]).

Signing key lost or leaked: not designed here. Key rotation is deferred to a later spec ([[decisions#D21 Updater UKI is frozen after provisioning]]).

## Acceptance criteria

Checked in the VM test or in a CI-level check on the build step's output, as marked.

- (VM test, CI check) A run on a clean checkout yields a site where, with only the site and cache.nixos.org as substituters, `trusted-public-keys` = the cache.nixos.org key plus the personal key, and `require-sigs` on, realising the release path named by `pointer` in an empty store succeeds. `nix store verify --no-contents --store <site-url> --sigs-needed 1 --trusted-public-keys <personal key> <path>` exits 0 for the release path and for its two references.
- `pointer` contains exactly one line, `<site-root>/<32-char nix-base32 hash>.narinfo`, with one trailing newline, and the pointed-at narinfo exists on the site. `<site-root>` has no trailing slash.
- The release narinfo's `References` are exactly two paths: one named `main.efi`, one `nixos-system-*`. Its `main.efi` symlink resolves to the first, its `toplevel` symlink to the second.
- The `main.efi` store object is a single regular file with mode `0444`, and `nix hash path --type sha256 <uki>` equals the `narHash` that `nix path-info --json --json-format 1 --store <site-url>` reports for the UKI (both SRI form).
- `system.build.uki` of the class configuration contains exactly one `.efi`; a stand-in with two `.efi` files makes the wrapper fail.
- (CI check only; not VM-verified, depends on live cache.nixos.org state) For each narinfo on the site, `HEAD https://cache.nixos.org/<hash>.narinfo` returns 404.
- The site contains exactly one release: a second run on a different ref leaves no path of the first release on the site except paths both closures share.
- With the oversize limit lowered through the check's parameter, the run fails and the live site is unchanged.
- A missing signing key fails the run before upload. A lookup that returns neither 200 nor 404 fails the run. A second dispatch while one runs queues behind it. Not VM-verified: these are workflow-level behaviors, checked when the workflow is first set up.
- The site directory produced by the build step is served by the VM test's local server without modification ([[decisions#D22 Acceptance: NixOS VM test]]).
