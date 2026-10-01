---
tags:
  - spec
  - volatile-host
status: draft
---
# Decisions log

Index: [[00-index]]

## D1 Scale: few hosts, single operator

- Decision: a few hosts, operated by one person. All hosts are one host class: identical configuration, one toplevel, one pointer at a fixed path. The updater needs no host identity.
- Why: staged rollouts, audit and per-host publishing are not needed; per-host identity beyond machine-id and whatever identity paths workload modules preserve (D10) is not needed.
- Rejected: one host only (hides per-host state problems); fleet with multiple operators (needs rollout channels, access control); several host classes (needs identity discovery in the updater: cmdline, SMBIOS UUID or ESP file; out of scope until a second class exists).

## D2 Volatility: RAM root, on-disk /nix

- Decision: root is RAM-backed (zram ext4, see [[#D16 Disk layout and main root]]); `/nix` lives on a local disk and serves as the download cache.
- Why: reboots stay fast and only changed store paths are fetched; the disk holds reproducible data only.
- Rejected: everything in RAM (full closure re-download every boot, RAM sized to closure); disk-backed root wiped on boot (needs snapshot rollback machinery, state is not guaranteed gone).

## D3 Two-stage boot: updater image + main system

- Decision: a small updater (own kernel + initrd, own UKI) sits on the ESP next to the main system. It boots first on every power-on/reboot, checks and fetches updates, then reboots into the main system. The main system keeps a simple initrd; a main-system kernel update is just a restart.
- Why: the updater runs in a minimal, rarely-changing environment, separate from what it updates. Main initrd carries no network/fetch logic.
- Rejected: update in the main initrd (couples fetch logic to every kernel/initrd change); boot last-good + kexec (two full boots, kexec hardware dependence); live `switch-to-configuration` (no kernel updates).
- UKI = Unified Kernel Image: one EFI executable bundling kernel + initrd + kernel command line, bootable directly by UEFI firmware.

## D4 Handoff: two UKIs + firmware BootNext

- Decision: ESP holds two UKIs, no bootloader. Firmware boot order default = updater UKI. Updater sets `BootNext` = main UKI (efibootmgr) and reboots. The main system's next reboot falls back to the default, the updater.
- Why: fewest moving parts; no bootloader to maintain.
- Requirement: persistent UEFI NVRAM. Under QEMU/OVMF the varstore must be a persistent pflash file.
- Evidence: edk2 BDS handles `BootNext` ([BdsEntry.c](https://qemu.googlesource.com/edk2/+/refs/heads/StructurePcd/IntelFrameworkModulePkg/Universal/BdsDxe/BdsEntry.c)). Read from source, not run: no qemu on the authoring host. See Open gaps in [[00-index]].
- Fallback: systemd-boot with `LoaderEntryOneShot` if BootNext fails on the QEMU test setup (user condition: two UKIs only if QEMU supports it).
- Rejected: systemd-boot rewriting ESP files (fragile writes, brick risk).

## D5 Published pointer: unsigned file, signed closure

- Decision: the pointer is one file, `pointer`, at a fixed path at the root of the GitHub Pages cache (D6). It holds one line: the absolute cache URL of the narinfo of the release closure (D26), `<site-root>/<32-char store hash>.narinfo`. It is a "symlink" by convention only: real symbolic links cannot be deployed, because the Pages artifact must not contain symbolic or hard links ([GitHub docs](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages), read). The file is not signed and carries no content hash (the store hash in the URL only locates the narinfo). Trust comes from the object it points to: the release path and every fetched store path must carry a valid narinfo signature from the personal cache key (or the cache.nixos.org key) in the updater's baked-in `trusted-public-keys`. The UKI content hash used by D11 is the `NarHash` of the signed narinfo.
- Validation: the updater rejects a pointer whose URL is not exactly `<baked-site-root>/<32-char nix-base32 hash>.narinfo`. The URL supplies only the store hash; the updater never fetches from an arbitrary host named in a pointer.
- Consistency: the pointer names a single signed object (D26) whose references are exactly the toplevel and the UKI, so a toplevel and UKI from different releases cannot be combined. There is one file to read, so no two-file race.
- Why: user decision. No custom file-signing code; `nix key` only generates and converts keys (nix 2.34.8, checked), so signing an arbitrary file would need custom crypto.
- Accepted (user decision): pointing hosts at an older release is a non-issue as long as that release was signed. Downgrade and replay by a Pages writer are therefore not defended against. They cannot make a host run unsigned code.
- Cost: a tampered pointer can only name another signed path, or a path that does not exist or is untrusted, which fails the update (D8).
- Rejected: two pointer files `pointer-toplevel` and `pointer-uki` (a stale copy of one file can pair a toplevel and UKI from different releases; needed an extra reference check); single `pointer.json` with a sha256; detached signature over the pointer with the same key via openssl (custom verifier); pointer as a signed store path (name file still unsigned); ssh-keygen signature with a second key; unsigned `uki_sha256` in the pointer (superseded by the narinfo `NarHash`, see D11).

## D6 Personal cache hosting: GitHub Pages, static nix cache layout

- Decision: the personal binary cache is a static nix cache (`nix-cache-info`, `*.narinfo`, `nar/`) served by GitHub Pages and used as a native substituter next to cache.nixos.org.
- Why: no custom fetch code in the updater; the pointer (D5) lives in the same site.
- Limits ([GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)): published site ≤ 1 GB, deployment timeout 10 min, soft 100 GB/month bandwidth. The personal cache must hold only paths missing from cache.nixos.org; D20 keeps only the latest release.
- Rejected: raw files in a git repo (history grows forever, repo ≤ 1 GB recommended); Releases assets with custom import (more updater code).

## D7 Main UKI built in CI as part of the toplevel closure

- Decision: the main UKI is built in CI (kernel + initrd + cmdline with `init=<toplevel>/init`) and is part of the published release closure (D26). The updater copies it from the fetched release to the ESP (temp file, fsync, rename).
- Single-file store object: `system.build.uki` in the pinned `nixos` source (`c59305ba`, `nixos/modules/system/boot/uki.nix`, read, not built) is a directory `$out/<name>_<version>.efi`, not a file. D11 compares the NAR hash of the ESP file, so a wrapper derivation named `main.efi` copies the `.efi` out of it into a store object that is a single regular file. The wrapper fails unless the directory contains exactly one `*.efi`.
- Ownership: the wrapper and the `release` derivation (D26) are defined CI-side, owned by the publisher ([[01-publisher]]), outside the toplevel closure. The main base ([[03-main-base]]) only provides the class configuration with `boot.uki` enabled.
- Permission bits: the wrapper MUST set the file mode explicitly (`chmod 0444`, no executable bit) before the output is finalized. The NAR serialization used for `NarHash` includes the executable flag; the same bytes at mode 444 and 755 hash differently (tested, nix 2.34.8). The mode the file has on the ESP must therefore always match the mode of the store object (see D11 and D16).
- Why: nothing is built on the host; the UKI is covered by cache signatures (D5).
- Rejected: updater assembles the UKI locally (build tools in the updater, no signature coverage); separate signed UKI artifact (can drift from the toplevel).

## D8 Update failure: boot the installed system, retry on next reboot

- Decision: on unreachable caches, signature failure or incomplete download, the updater boots the installed main UKI. The ESP main UKI is replaced only after the full closure is fetched and verified. The next reboot retries. With no main system present (first boot) the updater waits with backoff and retries from the start. Only unrecoverable setup failures (mount, boot entry, `efibootmgr`, reboot) halt.
- Why: the host stays available through outages; the old UKI stays bootable throughout. The installed system is the fallback, not a previously published one, because the installed system is known to have booted on this hardware (user decision).
- Accepted (user decision): a host may run a stale system while offline or failing to update. Operators interact with these hosts manually, so no alerting or enforcement is needed.
- Rejected: bounded retry before fallback (extra boot delay); block until success (cache outage means host down); falling back to the previously published release (not proven on the hardware, D20).

## D9 Bad release recovery: operator re-runs the workflow on an older ref

- Decision: no automatic rollback, and no older release is kept anywhere (D20). If a toplevel boots but is broken, the operator clicks the workflow button (D19) with an older ref selected in the GitHub dispatch UI. That rebuilds the older ref and publishes it as the new latest; hosts pick it up on their next reboot. A host whose update fails keeps booting its installed system (D8). A host that already booted the broken release recovers on its next reset, because the updater is the default boot entry (D3, D4); out-of-band access (console, hypervisor, power control) is needed only to force that reset.
- Why: avoids boot counters, a health definition and a second UKI slot. Matches few hosts, one operator.
- Cost: a rollback is a full workflow run; the rebuilt NAR bytes may differ from what was published before, which does not matter because nothing compares them.
- Rejected: keeping the previous release on the site or in the local store (D20); automatic fallback after unconfirmed boots (state and health logic).

## D10 Per-host state: /persistent via preservation

- Decision: per-host state lives in the btrfs `@persistent` subvolume mounted at `/persistent` on the same disk as `/nix`. The [preservation](https://github.com/nix-community/preservation) NixOS module (not impermanence) links or binds an explicit list of paths from it. The base preserves `/etc/machine-id` only. Modules that need identity add their own paths, for example sshd host keys or workload data. Everything else is lost on reboot.
- Scope: the base does not enable sshd or define users (D14). Preserving SSH host keys belongs to whichever module enables sshd.
- Why: preservation is the stated choice; `archive/llm-host.nix` already uses it this way.
- Cost: secrets at rest on disk unencrypted (D13).
- Rejected: impermanence module (user preference); no persist, identity injected each boot (needs secret delivery; no workload data); persist plus repo-encrypted secrets (key bootstrap and tool dependency); sshd and its key preservation in the base (workload scope).

## D11 Up-to-date check compares the ESP UKI file hash

- Decision: the up-to-date check is content-addressed by the UKI's `NarHash`. The updater (1) reads `pointer` (D5), (2) reads the release store path from the pointed-at narinfo and verifies its signature against the personal cache, (3) reads the release's `References` (exactly two: the UKI and the toplevel, D26), (4) verifies the UKI's narinfo the same way and reads its `NarHash`, (5) computes `nix hash path --type sha256` of `main.efi` on the ESP, and (6) compares. The release is realised (toplevel and UKI fetched, signature-checked) on every pass (D25); on a mismatch the updater also copies the UKI to the ESP. After the copy the ESP file's `nix hash path` must equal the verified `NarHash`, else the update counts as failed (D8).
- Evidence (nix 2.34.8, tested):
  - A narinfo is a plain-text file at `<cache>/<32-char store hash>.narinfo` (checked with curl over HTTP). It lists `StorePath`, `NarHash`, `NarSize`, `References` and `Sig`.
  - `nix hash path --type sha256 <file>` on a plain file outside the store equals the narinfo `NarHash` of that file added to the store.
  - The path convention does not verify anything. `nix store verify --no-contents --store <cache-url> --sigs-needed 1 --trusted-public-keys <key> <store-path>` does: exit 0 with the right key, exit 2 (untrusted) with a wrong key, exit 2 with a tampered `NarHash` in the narinfo, exit 4 for a path absent from the cache. It works over `file://` and `http://`, without downloading the NAR. It needs the full store path including the name, so the updater reads the `StorePath` line from the pointed-at narinfo as an unverified hint; the signature covers the store path, so a wrong hint fails the verify.
  - `nix store verify` trusts content-addressed (`ca`) paths without a signature. The release, wrapper and toplevel are input-addressed derivation outputs, so their signatures are checked.
  - `nix path-info --json --json-format 1 --store <cache-url> <path>` returns `narHash` and `references` without checking signatures; use it only after the verify call succeeded.
  - A derivation that creates symlinks to two store paths has exactly those two paths as `References` (tested).
- Why: detects corrupt or tampered ESP UKIs as well as stale ones, and the compared value comes from a signed source (the narinfo), not from the unsigned pointer. Deviates from a plain toplevel-hash comparison.
- Cost: reads the whole UKI each boot; a few small requests to the cache before the compare; the ESP file mode must match the store object's (D7, D16).
- Rejected: unsigned `uki_sha256` in the pointer (tampered value causes refetch loops); parse `init=` from the UKI cmdline (needs PE section reader); marker file on the ESP (can drift from the UKI); CA-derivations (experimental feature, and the updater would still have to map the ESP file to a path).

## D12 Reboots are manual

- Decision: no reboot timer, no pointer polling in the main system. The operator reboots a host to apply an update.
- Why: predictable; workloads are never interrupted by the system.
- Accepted (user decision): hosts can run stale indefinitely; operators interact with them manually.
- Rejected: main system polls pointer and reboots on change; nightly periodic reboot.

## D13 Threat model: network and supply-chain only

- Decision: defend against remote and supply-chain attackers via narinfo signatures on every fetched path (D5). The physical host and its disk are trusted. ESP and `/persistent` are unencrypted; no Secure Boot, no TPM.
- Why: personal lab scale; simple unattended reboots; works in QEMU testing.
- Cost: anyone with disk access can modify the ESP or read `/persistent`. Downgrade to an older signed release is accepted (D5).
- Rejected: encrypted `/persistent` (unlock complicates unattended boot); Secure Boot with CI-signed UKIs (key enrollment per host, signing flow).

## D14 Spec scope: platform only

- Decision: the spec covers the updater image, the main-system base and the publishing pipeline. Workloads are added per host later as ordinary NixOS modules.
- Why: smallest independently testable slice in QEMU.
- Rejected: a reference workload; a per-host repo layout spec.

## D15 Component split: publisher, updater, main base

- Decision: three independently buildable components. The publisher owns the CI-side derivations (`main.efi` wrapper, `release`), builds the release, pushes the cache and publishes the pointer. The updater is the updater UKI that checks, fetches, writes the ESP and sets BootNext. The main base is the class NixOS configuration: zram root, disk layout, `/persistent`, the simple initrd, `boot.uki` enabled, GC timer.
- Why: separate build and verify cycles. Interfaces: cache layout + pointer format (publisher→updater), disk and ESP layout (updater↔main base), `system.build.toplevel` and `system.build.uki` of the class configuration (main base→publisher).
- Rejected: two components, updater merged with main base (shared layout but inseparable verification); one component.

## D16 Disk layout and main root

- Decision: one disk, disko-managed GPT, modelled on `archive/llm-host.nix`: 1G ESP (vfat, GPT type EF00, partlabel `ESP`, `/boot`, mount options `fmask=0177,dmask=0077`), 4G zram backing partition (partlabel `zram-backing-device`), btrfs data partition (partlabel `data`) with subvolumes `@nix` (`/nix`) and `@persistent` (`/persistent`), both `compress=zstd,noatime,nodiratime,discard`. Main root is a zram ext4 device sized to 50% of RAM (zstd, `backing_dev` set to the backing partition), created by an initrd systemd unit that formats it each boot. Weekly btrfs scrub. The updater finds partitions through `/dev/disk/by-partlabel/{ESP,data}` (the archive's own unit uses by-partlabel for the backing partition). The target disk is one fixed device path set in the class configuration (the archive uses `/dev/sda`).
- Partlabels: in disko the GPT partlabel is a partition's `label`, not its `name`. `label` defaults to `<parent type>-<parent name>-<partition name>` (`gpt-main-ESP`, `gpt-main-data` for the archive's layout). The archive sets `label` only on the zram backing partition. This layout sets `label = "ESP"`, `label = "data"` and `label = "zram-backing-device"` explicitly. [Source: a review subagent read `lib/types/gpt.nix` of the pinned disko (`725ea35e`); not run.]
- ESP mount options: the archive's `umask=0077` is replaced. On FAT the mount options decide the mode bits files show, and `umask=0077` presents files as `0700` (executable). The D11 hash includes the executable flag, so the ESP MUST present UKIs as non-executable (`fmask=0177` gives `0600`). The updater and the main system use the same options. [INFERENCE: FAT mode behavior is not yet tested; the VM test must assert it, see Open gaps in [[00-index]].]
- Mount failure behavior: `nofail` is dropped from `/nix` and `/persistent` (the archive has it). With `neededForBoot = true` and no `nofail`, a failed mount fails the boot instead of continuing without the store, where `init=<toplevel>/init` could not exist anyway. [INFERENCE: not tested; see Open gaps in [[00-index]].]
- Console recovery: `boot.initrd.systemd.emergencyAccess = true` stays on (the archive marks it DEBUG). It covers initrd failures, such as a failed mount; physical access is trusted (D13). D9 recovery needs no console beyond forcing a reset.
- zram writeback: `backing_dev` is set as in the archive, but nothing triggers writeback (the archive has no trigger either). The claim that the root can exceed free RAM through writeback is withdrawn; capacity is the compressed 50%-of-RAM device. A writeback trigger is an open gap.
- Differs from the archive: no `EF02` BIOS boot partition (UEFI only, D4); ESP mode options as above; explicit partlabels; no `nofail`; no bootloader on the ESP, which holds the two UKIs (D3, D4); no sshd and no users (D10, D14); no `hypervGuest`, `kvm-*` modules, vm sysctl or `psi`/`lru_gen` tuning (host or workload scope); `zswap.enabled=0` kept.
- Why: reuse a proven layout.
- Rejected: tmpfs root (uncompressed, RAM-hungry); second disk for store and persist (two disks per host and per QEMU test); installer ISO (separate artifact).
- Provisioning: a one-off disko script run from an installer environment partitions the disk, creates the two UEFI boot entries and copies the updater UKI; the first boot fetches the main system (D8 first-boot retry case).

## D17 Updater runtime: initrd-only systemd image

- Decision: the updater UKI is a kernel + systemd initrd that never switch-roots. The update runs as an initrd unit with network, the fetch tool, efibootmgr and CA roots. It mounts the ESP and `@nix` and reboots when done.
- Why: smallest image; no second NixOS root to build and keep bootable.
- Cost: everything the updater needs sits in RAM inside the initrd; debugging is harder than in a full system.
- Rejected: small full NixOS system as its own UKI (larger, second closure).

## D18 Observability: console/serial only

- Decision: the updater logs to console/serial; the journal is in RAM and lost on reboot. No log file, no status file.
- Why: simplest; the updater mounts nothing extra.
- Cost: failure reasons are only visible live. Matches D8: a failed update is silent until noticed.
- Rejected: log on `/persistent`; status file on the ESP.

## D19 Publish trigger: GitHub Actions, manual dispatch

- Decision: a GitHub Actions workflow builds the release closure (D26), signs the paths it publishes with the cache key, assembles the site and publishes the pointer. The only trigger is `workflow_dispatch` with no inputs: the operator clicks the button in the GitHub UI, and the workflow builds the ref selected there. There are no tags and no release keys. Runs are single-flight (`concurrency` group, no cancel-in-progress) so two clicks cannot deploy at once.
- Why: hosts change only when the operator decides; the simplest possible trigger (user decision).
- Rejected: git tags as release keys (user decision: not needed, nothing older is kept, D20); on every push to main (ungated bad merge goes live); local machine build (depends on one machine, matching inputs).

## D20 Cache retention: latest release only

- Decision: the Pages site holds only the latest published release. Each run builds the whole site from scratch (a Pages deploy replaces the site anyway). It does not read the live site, carries nothing over, and the site has no `releases/` directory. No previous release is kept on the site, and none is rooted or deliberately retained in the hosts' stores (user decision); old closures linger unrooted until GC (D25).
- Why: no carry-over logic, no dependency on the live site, the smallest site (D6). The fallback for a failed update is the host's installed system, which is proven on its hardware, not an older publish (D8, D9).
- Cost: older releases vanish from the site on the next publish; a rollback is a rebuild of an older ref (D9).
- Rejected: current + previous release (user decision); last N releases (the 1 GB cap limits N); byte-for-byte carry-over of old releases from the live site (complexity for no remaining use).

## D21 Updater UKI is frozen after provisioning

- Decision: the updater UKI on the ESP is replaced only by re-provisioning. Its fetch logic, substituter URLs, pointer URL and `trusted-public-keys` are baked in.
- Why: smallest moving parts; no self-update that could brick the update path (D4: the main system boots only via the updater).
- Cost: updater bugs need a hands-on ESP rewrite per host.
- Deferred (user decision): cache-key rotation is a non-issue for now. A later spec covers it; this spec does not design it. Under D21 as written a rotation implies re-provisioning every host.
- Rejected: updater replaces itself via the pointer; main system replaces the updater.

## D22 Acceptance: NixOS VM test

- Decision: end-to-end behavior is verified by a `lib.nixos.runTest` NixOS VM test (pattern: `archive/agent-vm-host-platform-test.nix`). The setup is flake-less (user decision): no `flake.nix`, no `nix flake check`. The test is a plain attribute of the repo's lon-pinned entry point, built with `nix-build -A <attr>`, as in the archive. A local static cache and pointer stand in for GitHub Pages. Scenarios are listed in [[00-index#System acceptance criteria]].
- Why: reproducible, no manual steps, matches the existing repo convention.
- Risk: the test driver must support persistent UEFI NVRAM across reboots and a prebuilt disk layout with two UKIs; unverified (see Open gaps in [[00-index]]). Fallback: the scripted raw-QEMU harness.
- Rejected: raw QEMU/OVMF script as the primary harness (not integrated with the repo's build; kept only as the fallback above); manual smoke checklist.

## D23 Updater network: DHCP on all wired interfaces

- Decision: systemd-networkd in the updater initrd runs DHCP on all wired interfaces. No static addressing, wifi or VLANs.
- Why: one generic updater for the host class; nothing environment-specific baked into the frozen UKI (D21).
- Rejected: DHCP plus `ip=` cmdline for static setups (static values frozen in the UKI).

## D24 Fetch tool: stock nix against the on-disk store

- Decision: the updater uses stock `nix-store --realise` against the chroot store, with substituters `https://cache.nixos.org` and the Pages cache, `require-sigs` on, and the baked `trusted-public-keys`. `nix copy` is not used: it copies from one explicit `--from` store and substitutes only with `--substitute-on-destination` (checked with `nix copy --help`, nix 2.34.8).
- Why: native narinfo signature checking, multiple caches, per-path resumability; no reimplementation of trust logic.
- Cost: the nix closure sits in the initrd, in RAM. [INFERENCE: roughly 100+ MB uncompressed; not measured.]
- Rejected: custom curl-based fetcher (high risk of trust bugs).

## D25 Store GC: weekly timer in the main system

- Decision: the updater maintains one GC root, `current`, a symlink to a release path (D26); the release's references keep the toplevel and UKI alive. Invariant: `current` is the release whose UKI is on the ESP and therefore the one the main system boots from. The updater reconciles the root on every successful pass, including when nothing changed, so a crash between the ESP write and the root update is repaired on the next boot. The updater also checks that the pointed-at release is present in the local store even when the ESP is up to date. A timer in the main base runs `nix-collect-garbage` (no `--delete-old`; there are no profile generations) over `/nix`. Timer: `OnUnitActiveSec=1w` (user decision), plus `OnBootSec=1w` as its required first trigger. The updater does not GC.
- Why `OnBootSec=1w` is there: tested with systemd on the authoring host (`systemd-run --user --on-unit-active=3s`): a timer with only `OnUnitActiveSec=` never elapses (`NEXT` stays `-`, the service never starts), because the service has no last-activation time to count from. The monotonic first trigger starts the cycle one week after boot, then `OnUnitActiveSec=1w` repeats it. A calendar timer would lose its state on every reboot (volatile root, D2). Not `OnBootSec=1h`: user decision to not GC shortly after every boot.
- Why: keeps GC off the boot path; the booted release is always rooted, except in one window: if the root update (updater step 10) fails after the ESP write, the booted release stays unrooted until the next boot's reconcile, and a GC in that uptime can delete it.
- Cost: timers are monotonic and the root is volatile, so a host that reboots more often than weekly never reaches its first trigger and never collects garbage. Each update then adds unreachable store paths until the disk fills (D8 falls back to the installed system when a fetch fails for lack of space). The main system needs write access to the store DB.
- Rejected: GC in the updater (boot delay); never GC (reprovisioning wipes `/persistent`); a `previous` root and a calendar-based timer (superseded); `OnBootSec=1h` (GC shortly after every boot, user decision against).

## D26 Release closure: one symlink-farm store path

- Decision: CI builds a derivation named `release` whose output is a directory with two symlinks: `toplevel` → the system toplevel and `main.efi` → the single-file UKI object (D7). Its `References` are exactly those two paths (tested: a derivation creating symlinks to two store paths records exactly those two). The pointer (D5) names this one path. The updater realises it to get both. In the updater, the UKI is the reference whose store-path name is `main.efi`, the toplevel is the other.
- Ownership: defined by the publisher ([[01-publisher]]) in CI-side Nix, outside `config.system.build.toplevel`. The toplevel cannot contain it (hash cycle, below).
- Does not exist upstream: the pinned `nixos` source (`c59305ba`) has `system.build.toplevel` and `system.build.uki` (read from `nixos/modules/system/boot/uki.nix`), but no output combining them. The UKI's cmdline contains `init=${toplevel}/init`, so the UKI depends on the toplevel and the toplevel cannot reference the UKI. The combining object must be a third derivation.
- Why: toplevel and UKI of one build are bound by one signature, so the pair is consistent by construction. One pointer, one GC root.
- Cost: the `main.efi` name convention is how the updater tells the two references apart; a wrapper-name change is a breaking change of the updater, which is frozen (D21). Symlink targets are absolute store paths, so reading the farm needs the store root the paths live under (the updater copies from the store, not through the symlink).
- Rejected: two pointer files (D5); a single "toplevel" pointer that is derived from the UKI's references (works, but needs the UKI's NarHash first and offers no object that names both).

## Non-goals

- Fleet management with multiple operators, staged rollouts, update channels ([[#D1 Scale: few hosts, single operator]]).
- Disk encryption of `/persistent`, Secure Boot, TPM: sound in general, not needed for a trusted physical host ([[#D13 Threat model: network and supply-chain only]]).
- Signed pointer files and protection against downgrade to an older signed release ([[#D5 Published pointer: unsigned file, signed closure]]).
- Detecting or alerting on stale hosts; operators interact with hosts manually ([[#D8 Update failure: boot the installed system, retry on next reboot]], [[#D12 Reboots are manual]]).
- Cache-key rotation: deferred to a later spec ([[#D21 Updater UKI is frozen after provisioning]]).
- Release history: no previous release is kept on the site or on hosts; no tags ([[#D20 Cache retention: latest release only]], [[#D19 Publish trigger: GitHub Actions, manual dispatch]]).
- Automatic rollback and boot-health confirmation ([[#D9 Bad release recovery: operator re-runs the workflow on an older ref]]).
- Automatic or scheduled reboots ([[#D12 Reboots are manual]]).
- Persistent update logs or status reporting ([[#D18 Observability: console/serial only]]).
- Reference workload and per-host repo layout ([[#D14 Spec scope: platform only]]).
- Flakes ([[#D22 Acceptance: NixOS VM test]]).
