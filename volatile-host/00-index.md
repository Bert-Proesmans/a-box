---
tags:
  - spec
  - volatile-host
status: draft
---
# Volatile NixOS host: spec index

Decisions and rationale: [[decisions]]

## Overview

Volatile NixOS host. Root is a zram ext4 device; `/nix` and `/persistent` are on a local disk. On every boot an updater image compares the main UKI on the ESP, by NAR hash, to the signed `NarHash` of the published UKI. On mismatch it fetches the closure from the public cache (cache.nixos.org) and a personal cache on GitHub Pages, verifies narinfo signatures, writes the new UKI to the ESP, then hands over to the main system. A failed update boots the installed system when one exists; on first boot the updater retries with backoff, and mount or boot-entry failures halt ([[decisions#D8 Update failure: boot the installed system, retry on next reboot]]).

## Purpose and users

One operator, a few hosts of one host class (identical config, one pointer at a fixed path): [[decisions#D1 Scale: few hosts, single operator]]. Scope: platform only, no workload: [[decisions#D14 Spec scope: platform only]].

## Scale and threat model

- Scale: [[decisions#D1 Scale: few hosts, single operator]]
- Threat model: [[decisions#D13 Threat model: network and supply-chain only]]

## Architecture

- RAM root, on-disk `/nix`: [[decisions#D2 Volatility: RAM root, on-disk /nix]]
- Updater image then main system: [[decisions#D3 Two-stage boot: updater image + main system]]
- Handoff via two UKIs and BootNext: [[decisions#D4 Handoff: two UKIs + firmware BootNext]]
- Disk layout and zram root: [[decisions#D16 Disk layout and main root]]
- Updater runtime, network, fetch tool, frozen after provisioning: [[decisions#D17 Updater runtime: initrd-only systemd image]], [[decisions#D23 Updater network: DHCP on all wired interfaces]], [[decisions#D24 Fetch tool: stock nix against the on-disk store]], [[decisions#D21 Updater UKI is frozen after provisioning]]
- Publishing: one `pointer` file holding the narinfo URL of the release closure: [[decisions#D5 Published pointer: unsigned file, signed closure]], [[decisions#D26 Release closure: one symlink-farm store path]]; [[decisions#D6 Personal cache hosting: GitHub Pages, static nix cache layout]], [[decisions#D7 Main UKI built in CI as part of the toplevel closure]]; manual button, latest release only: [[decisions#D19 Publish trigger: GitHub Actions, manual dispatch]], [[decisions#D20 Cache retention: latest release only]]
- Up-to-date check by signed NarHash: [[decisions#D11 Up-to-date check compares the ESP UKI file hash]]

```
release = { toplevel -> nixos-system-..., main.efi -> UKI file }   (signed)

power-on/reboot
   |
   v
[updater UKI]  default boot entry, initrd-only
   | read pointer (narinfo URL of the release)
   | verify release + UKI narinfo signatures
   | narHash = signed NarHash of the UKI
   | realise release (toplevel + UKI, cache.nixos.org + GitHub Pages),
   |   every pass; a no-op when the store already has it
   | nix hash path(main UKI on ESP) != narHash ?
   |  yes -> write UKI to ESP
   | failure in the fetch/verify steps -> boot the installed system
   |   (first boot: back off and retry; mount/boot-entry failure: halt)
   | efibootmgr BootNext = main; reboot
   v
[main UKI]  zram root, /nix + /persistent from disk
   | operator reboots -> back to updater
```

## Failure modes and state

- Update failure boots the installed main UKI: [[decisions#D8 Update failure: boot the installed system, retry on next reboot]]
- Bad release recovery by re-running the workflow on an older ref: [[decisions#D9 Bad release recovery: operator re-runs the workflow on an older ref]]
- Per-host state in `/persistent` via preservation: [[decisions#D10 Per-host state: /persistent via preservation]]

## Operations

- Update check: [[decisions#D11 Up-to-date check compares the ESP UKI file hash]]
- Manual reboots only: [[decisions#D12 Reboots are manual]]
- Observability, console/serial only: [[decisions#D18 Observability: console/serial only]]
- Store GC, one `current` root, timer in the main system: [[decisions#D25 Store GC: weekly timer in the main system]]
- Provisioning: [[02-updater#Provisioning]]. Key rotation: deferred to a later spec ([[decisions#D21 Updater UKI is frozen after provisioning]]).

## Components and build order

Split: [[decisions#D15 Component split: publisher, updater, main base]].

1. [[01-publisher]]: cache layout, pointer format, workflow.
2. [[02-updater]]: updater UKI, ESP contract, provisioning. Verified against a static test cache.
3. [[03-main-base]]: disko layout, zram root, preservation, GC timer. Shares the ESP/disk contract with the updater.

Build order: publisher, updater, main base. The updater and main base need each other for the end-to-end test, so the VM test lands with the main base.

## System acceptance criteria

Verified by a `lib.nixos.runTest` VM test ([[decisions#D22 Acceptance: NixOS VM test]]), with a local server standing in for Pages and serving the publisher's site directory without modification (the test passes its own `<site-root>` and signing key to the site build, [[01-publisher#Behavior]]):

1. Fresh provisioned disk: updater fetches, main boots, `nix hash path` of `main.efi` on the ESP equals the signed `NarHash` of the release's UKI, and the `current` GC root names the release.
2. Reboot from main returns to the updater.
3. Unchanged pointer: no store path or NAR is fetched (only the pointer and narinfos are read), main boots.
4. New pointer: only missing paths fetched, main runs the new toplevel.
5. Cache unreachable, bad signature, or tampered narinfo `NarHash`: the installed main boots, ESP unchanged.
6. Pointer to an older build (published by the workflow on an older ref): that toplevel boots.
7. Root contents lost on reboot; machine-id survives.
8. The UKI shows no executable bit in the store and on the mounted ESP.
9. Pointer URL outside the site root, or a release without exactly the `main.efi` and toplevel references: update rejected, installed main boots.

Per-component criteria are in the child notes.

## Coverage checklist

- [x] Purpose and users
- [x] Scale and threat model
- [x] Components and interfaces ([[01-publisher]], [[02-updater]], [[03-main-base]])
- [x] Data and state
- [x] Failure modes and recovery
- [x] Operations
- [x] Acceptance criteria
- [x] Non-goals (see [[decisions#Non-goals]])

## Open gaps

- BootNext and persistent UEFI NVRAM inside `runNixOSTest`: unconfirmed. D4 and D22 depend on it. Fallbacks: systemd-boot one-shot (D4), raw QEMU harness (D22). Blocks: acceptance test, [[02-updater]] handoff.
- Clock source in the updater initrd (RTC vs NTP): unspecified. A wrong clock breaks TLS and silently triggers the D8 fallback. Blocks: [[02-updater]] reliability on hardware without a correct RTC.
- Nix chroot-store layout used by the updater must match what the main system sees at `/nix`: unverified ([[02-updater#Behavior]]).
- Pages publishes the site atomically, so a failed deploy leaves the old site live: unverified ([[01-publisher#Failure modes]]).
- The default `github-pages` environment may reject deployments from refs other than the default branch, which would block the rollback case of D9: unverified, check when the workflow is set up ([[01-publisher#Behavior]]).
- GC never runs on hosts that reboot more often than weekly: the timer is monotonic (`OnBootSec=1w`, `OnUnitActiveSec=1w`), so its first trigger needs a week of uptime, and the store grows with every update ([[decisions#D25 Store GC: weekly timer in the main system]]). Accepted for now; revisit if hosts reboot often.
- Cache-key rotation: deferred by the operator to a later spec. Matters because the key is baked into the frozen updater (D21). Depends on it: [[01-publisher]], [[02-updater]].
- FAT mount options `fmask=0177,dmask=0077` yielding a non-executable file on the ESP: unverified (only the executable-flag effect on `nix hash path` was tested, on a normal filesystem). D11 depends on it. Covered by acceptance criteria in [[02-updater]] and [[03-main-base]].
- vfat rename atomicity under power loss, which the ESP update relies on: untested ([[02-updater#Failure modes and recovery]]).
- `nix store verify` as the signature check for the narinfo lookup was tested over `file://` and `http://` only, not against GitHub Pages ([[decisions#D11 Up-to-date check compares the ESP UKI file hash]]).
- The release and wrapper derivations (D7, D26) were tested on stand-in derivations, not on a real `boot.uki` build; in particular that `system.build.uki` yields exactly one `.efi` at the pinned `nixos` source. Asserted by [[03-main-base]] and [[01-publisher]] acceptance criteria.
- cache.nixos.org has no retention guarantee. Paths the publisher excludes because cache.nixos.org has them can later be evicted, which would make the latest release unfetchable until the next publish ([[01-publisher#Failure modes]]). Mitigation, if wanted: publish those paths too, at the cost of the 1 GB limit.
- zram writeback trigger: `backing_dev` is set but nothing triggers writeback, so the 4G backing partition is unused ([[decisions#D16 Disk layout and main root]]). Whether to add a trigger, or drop the partition, is undecided.
- Disko partlabels: the GPT partlabel is the `label` option (set explicitly to `ESP`, `data`, `zram-backing-device`), read from the pinned disko source by a review subagent, not run. Covered by the by-partlabel criterion in [[03-main-base]] ([[decisions#D16 Disk layout and main root]]).
- Main-system mount-failure behavior without `nofail` (`/nix`, `/persistent`, `/boot` fail the boot or drop to the emergency prompt): untested ([[decisions#D16 Disk layout and main root]], [[03-main-base#Failure modes and recovery]]).
- Whether `sleep` and `basename` resolve inside the zram unit in the systemd initrd: not shown by the archive ([[03-main-base#Root and boot]]).
- Updater timeout values (DHCP 60 s, curl and nix 10 s connect / 60 s stall): spec defaults, not tuned ([[02-updater#Interfaces]]).
- Pages URL, repo name, cache key name, attribute names and exact UKI file names: fixed at implementation.
