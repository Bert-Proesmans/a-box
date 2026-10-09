---
tags:
  - spec
  - volatile-host
status: draft
---
# 02 Updater

Index: [[00-index]]. Rationale: [[decisions#D3 Two-stage boot: updater image + main system]], [[decisions#D4 Handoff: two UKIs + firmware BootNext]], [[decisions#D5 Published pointer: unsigned file, signed closure]], [[decisions#D8 Update failure: boot the installed system, retry on next reboot]], [[decisions#D9 Bad release recovery: operator re-runs the workflow on an older ref]], [[decisions#D11 Up-to-date check compares the ESP UKI file hash]], [[decisions#D16 Disk layout and main root]], [[decisions#D17 Updater runtime: initrd-only systemd image]], [[decisions#D20 Cache retention: latest release only]], [[decisions#D21 Updater UKI is frozen after provisioning]], [[decisions#D23 Updater network: DHCP on all wired interfaces]], [[decisions#D24 Fetch tool: stock nix against the on-disk store]], [[decisions#D25 Store GC: weekly timer in the main system]], [[decisions#D26 Release closure: one symlink-farm store path]].

The updater UKI: default firmware boot entry, kernel + systemd initrd, never switch-roots. Checks the pointer, fetches and verifies, replaces the main UKI on the ESP, keeps the GC root in step, sets `BootNext`, reboots.

## Interfaces

Baked into the UKI ([[decisions#D21 Updater UKI is frozen after provisioning]]): `<site-root>` (the Pages site, no trailing slash), substituters (`https://cache.nixos.org`, `<site-root>`), `trusted-public-keys` (cache.nixos.org key, personal cache key), and the timeouts below.

Tools in the initrd ([[decisions#D17 Updater runtime: initrd-only systemd image]]): systemd-networkd, curl (pointer and narinfo reads), nix (verify, path-info, hash, realise), efibootmgr, CA roots, coreutils.

Input: `<site-root>/pointer` (one line: a narinfo URL) and the signed narinfos it leads to. The release closure is defined in [[decisions#D26 Release closure: one symlink-farm store path]]. The site holds only the latest release ([[decisions#D20 Cache retention: latest release only]]).

Disk and firmware contract, shared with [[03-main-base]]. [[03-main-base]] is authoritative for the disko layout and mount options; this table is the runtime contract the updater relies on:

| Item | Value |
|---|---|
| ESP | `/dev/disk/by-partlabel/ESP`, vfat, mounted at `/boot` with `fmask=0177,dmask=0077`: files MUST appear non-executable |
| Updater UKI | `/boot/EFI/Linux/updater.efi`, boot entry label `updater`, first in `BootOrder` |
| Main UKI | `/boot/EFI/Linux/main.efi`, boot entry label `main`, not in `BootOrder` |
| Temp UKI | `/boot/EFI/Linux/main.efi.new` |
| Store partition | `/dev/disk/by-partlabel/data`, btrfs, subvolume `@nix` (mount options as in [[03-main-base]]) |
| Store root | `@nix` is mounted at `/run/store-root/nix`; the store root is `/run/store-root` |
| GC root | `<store-root>/nix/var/nix/gcroots/volatile/current`, a symlink whose target is the release path as the main system sees it, `/nix/store/<hash>-release` |

Permission bits: `nix hash path` includes the executable flag. The copied `main.efi` must have the same executable flag as the store object (none). The updater mounts the ESP with the options above and, after every copy, re-hashes the file on the ESP ([[decisions#D11 Up-to-date check compares the ESP UKI file hash]]). [INFERENCE: FAT mode behavior under these options is untested; see Open gaps in [[00-index]].]

Timeouts, so a stalled network reaches `FALLBACK` instead of hanging (values are the spec defaults, tuned at implementation): DHCP wait 60 s; `curl --connect-timeout 10 --max-time 60`; nix `connect-timeout = 10`, `stalled-download-timeout = 60`.

## Behavior

Definitions. `FALLBACK`: if `main.efi` exists, go to step 11 (the installed system boots, [[decisions#D8 Update failure: boot the installed system, retry on next reboot]]); otherwise wait with backoff (30 s, doubling to a 5 min cap) and restart from step 1. Every failure in steps 1 to 9 is `FALLBACK` unless stated otherwise (mount failures in step 1 halt). Any non-zero exit of a `nix` or `curl` command is a failure, except the hash call in step 7.

1. Bring up the network (DHCP, all wired interfaces; bounded wait). Mount the ESP and `@nix` at `/run/store-root/nix`, and `efivarfs`; a mount that is already in place on a restart is skipped. Create `<store-root>/nix/var/nix/gcroots/volatile` if absent. Delete `main.efi.new` if present. A mount failure (ESP, `@nix` or `efivarfs`) is not `FALLBACK`: log and halt.
2. Fetch `<site-root>/pointer`. Its content, with at most one trailing newline removed, MUST be exactly `<site-root>/<32-char nix-base32 hash>.narinfo`. Take the hash.
3. Fetch that narinfo. Read its `StorePath` line as an unverified hint for the full release store path. The hint MUST be `/nix/store/<hash>-<name>` with `<hash>` equal to the pointer hash, else failure.
4. Verify the release: `nix store verify --no-contents --store <site-root> --sigs-needed 1 --trusted-public-keys <personal-key> <release-path>` must exit 0. Then `nix path-info --json --json-format 1 --store <site-root> <release-path>` gives `references`. Do not use them unless the verify call succeeded. The personal key alone is used here and in step 6, because the release, wrapper and toplevel exist only on the personal cache.
5. Require exactly two references: exactly one whose store-path name is `main.efi` (the UKI), and one other whose name starts with `nixos-system-` (the toplevel). Anything else is a failure.
6. Verify the UKI the same way (verify call, then `path-info`; the narinfo is at `<site-root>/<uki-hash>.narinfo`) and read its `narHash`.
7. If `/boot/EFI/Linux/main.efi` does not exist, it is a mismatch. Otherwise compute `nix hash path --type sha256` of it; if it equals `narHash`, set `UP_TO_DATE`. A failing hash call on an existing file is a failure.
8. Realise the release in the chroot store (`nix-store --store 'local?root=/run/store-root' --realise <release-path>`) with `require-sigs = true` and the baked substituters and keys; this fetches the toplevel and the UKI. `nix copy` is not used ([[decisions#D24 Fetch tool: stock nix against the on-disk store]]). It runs on every pass: when the release is already valid in the local store nothing is fetched and no network is needed, and when `UP_TO_DATE` but the store lost the release (wiped or collected) it is restored.
9. If not `UP_TO_DATE`: copy `<store-root>/nix/store/<uki-basename>` (the reference path from step 5, not the `<release>/main.efi` symlink, whose absolute target does not resolve under the store root) to `main.efi.new` without preserving mode, fsync, check `nix hash path --type sha256 main.efi.new` equals `narHash`, rename over `main.efi`, fsync the directory. On a failed copy or a failed check delete `main.efi.new`.
10. Reconcile the GC root ([[decisions#D25 Store GC: weekly timer in the main system]]): if `current` does not point at `<release-path>`, set it to `<release-path>`, written as a temporary symlink and renamed over the old one. This runs on every pass, including `UP_TO_DATE`. A failure here is logged and does not stop step 11.
11. Find the boot entry labelled `main` in `efibootmgr` output; `efibootmgr --bootnext <entry>`; reboot.

The installed `current` root stays in place until step 10 replaces it, so when step 9 did not run (or failed) a failed update never unroots the installed system. If step 9 succeeded and step 10 fails, the new release is unrooted until the next boot's step 10, and a GC in that uptime can delete it ([[decisions#D25 Store GC: weekly timer in the main system]]); accepted, the next boot repairs the root.

The narinfo location is a plain path convention: `<site-root>/<32-char store hash>.narinfo`. The updater reads one line (`StorePath`) from it as a hint; everything it acts on comes from `nix store verify` and `nix path-info` ([[decisions#D11 Up-to-date check compares the ESP UKI file hash]] lists what was tested, over `file://` and `http://`; [INFERENCE] https against GitHub Pages behaves the same).

Store access in step 8 uses the chroot store at `/run/store-root`, not `/nix`: in the initrd `/nix` holds the updater's own tools and must not be hidden. [INFERENCE: the layout of the nix state under that root matches what the main system sees at `/nix`; verify in the VM test.] Steps 2 to 7 use no local store.

GC is not run here ([[decisions#D25 Store GC: weekly timer in the main system]]).

## Data and state

No persistent state of its own. On the ESP: the two UKIs. In `@nix`: the store, its DB and the one GC root. Logs go to console/serial only ([[decisions#D18 Observability: console/serial only]]).

## Failure modes and recovery

| Failure | Result |
|---|---|
| ESP, `@nix` or `efivarfs` mount fails; `main` boot entry missing; `efibootmgr` or reboot fails (step 11) | log and halt; operator action (broken provisioning or hardware) |
| No DHCP lease within the wait; pointer unreachable, malformed, or its URL not exactly under the baked `<site-root>`; a stalled connection (timeouts above) | `FALLBACK` |
| Release narinfo hint hash differs from the pointer hash | `FALLBACK`; ESP and root unchanged |
| Release or UKI narinfo missing or untrusted (verify exit 2 or 4, or any non-zero exit) | `FALLBACK`; ESP and root unchanged |
| Release does not have exactly two references, or not exactly one named `main.efi` and one `nixos-system-*` | `FALLBACK`; ESP and root unchanged |
| Realise fails, signature invalid, path missing from both caches | `FALLBACK`; ESP and root unchanged |
| Copy or post-copy hash check fails (including a wrong executable flag) | delete `main.efi.new`; `FALLBACK` |
| Wrong clock makes TLS validation fail | same as unreachable; `FALLBACK` |
| `main.efi` does not exist (first boot) | `FALLBACK` waits with backoff and restarts from step 1 until an update succeeds |
| Power loss during step 9 | `main.efi` is either old or new, never partial, by rename [INFERENCE: vfat rename atomicity under power loss is untested; Open gaps in [[00-index]]]; `main.efi.new` is deleted by step 1 on the next run |
| Power loss between step 9 and step 10 | next run: `UP_TO_DATE`, step 10 repairs the root |
| Root cannot be written (step 10) | log, continue to step 11; the new release is unrooted until the next boot's step 10 (see Behavior); the next run retries |

On a hash mismatch followed by failed update, the old `main.efi` is still booted. It is the installed system, proven on this hardware ([[decisions#D8 Update failure: boot the installed system, retry on next reboot]]). A tampered or corrupt old UKI therefore boots; accepted ([[decisions#D13 Threat model: network and supply-chain only]]).

Recovery for a broken release: [[decisions#D9 Bad release recovery: operator re-runs the workflow on an older ref]]. The updater needs no special logic: an older build published as the new latest is just a hash mismatch.

## Provisioning

One-off script run from an installer environment. `<mnt>` is the disko mount prefix (the disko default is `/mnt`); at runtime the ESP is `/boot`.

1. Run the disko script from [[03-main-base]] (partitions, formats, mounts under `<mnt>`). The script takes a prebuilt `updater.efi` (built from this repo; where it is built is fixed at implementation) as input.
2. Create `<mnt>/boot/EFI/Linux` and write `updater.efi` to it.
3. Create boot entries `updater` and `main` with `efibootmgr --create`. `main` points at `main.efi`, which does not exist yet. Set `BootOrder` to the `updater` entry only (`efibootmgr --create` prepends new entries, so `main` is removed from the order explicitly).
4. Reboot. The updater runs the first-boot flow.

Provisioning also fixes the baked values; changing them means re-provisioning.

## Acceptance criteria

Verified by the VM test ([[decisions#D22 Acceptance: NixOS VM test]]):

- First boot with no `main.efi`: updater fetches, writes `main.efi`, main boots, `nix hash path` of `main.efi` equals the signed `NarHash` of the release's UKI (both SRI form), and `current` points at the release path.
- First boot with the cache unreachable: the updater retries with backoff (waits of 30 s, 60 s, 120 s, ... capped at 5 min, observed in the log) and never sets `BootNext`; once the cache returns, it completes.
- On the mounted ESP, `main.efi` has no executable bit, and its `nix hash path` equals the store object's `narHash`.
- Reboot from main returns to the updater, not to main (BootNext is one-shot).
- Unchanged pointer: no NAR or store path is downloaded (only the pointer and narinfo reads happen), main boots, `current` does not change.
- New pointer: only missing paths are fetched, `/run/current-system` in main equals the release's `toplevel` target, `current` is the new release.
- Cache unreachable after first boot: main boots unchanged, ESP unchanged, `current` unchanged.
- Update fails (for example a bad signature on the new release): the installed `main.efi` boots and `current` still names the installed release.
- Narinfo with a bad signature, a tampered `NarHash`, or a pointer to an unsigned path: update rejected, old main boots.
- Pointer file with a URL outside the baked `<site-root>`, with a hash that is not 32-char nix-base32, or with more than one line: update rejected, old main boots.
- Release narinfo whose `StorePath` hash differs from the pointer hash: update rejected, old main boots.
- Release with a third reference, or without a `main.efi` reference: update rejected, old main boots.
- Realise fails because a toplevel dependency is missing from both caches: update rejected, ESP and `current` unchanged, old main boots.
- `main.efi` altered: hash mismatch triggers rewrite.
- `main.efi` deleted while the cache is reachable: rewritten.
- Release collected from the store while the ESP is up to date: step 8 restores it before `BootNext`.
- Pointer to a different (older) build: that toplevel boots and `current` names it.
- Kill during step 9: `main.efi` is intact and no `main.efi.new` remains after the next run.
- Kill between step 9 and step 10: the next run sets `current` to the booted release.
- Wrong clock (VM with a skewed clock, https cache): update fails, old main boots. Skipped if the test cache is plain http.
- The regular files on the ESP after a completed update are exactly `EFI/Linux/updater.efi` and `EFI/Linux/main.efi` (no `main.efi.new`, no bootloader files).
- Blackholed network (packets dropped, no reset): the updater reaches `FALLBACK` within the timeouts instead of hanging.
- Not VM-verified: ESP, `@nix` or `efivarfs` mount failure, `efibootmgr` failure, missing `main` boot entry (halt paths); a step 10 write failure; vfat rename atomicity under power loss; the provisioning script on real hardware (the VM test builds its disk and boot entries equivalently).
