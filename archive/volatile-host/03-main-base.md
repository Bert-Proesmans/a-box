---
tags:
  - spec
  - volatile-host
status: draft
---
# 03 Main base

Index: [[00-index]]. Rationale: [[decisions#D2 Volatility: RAM root, on-disk /nix]], [[decisions#D3 Two-stage boot: updater image + main system]], [[decisions#D4 Handoff: two UKIs + firmware BootNext]], [[decisions#D9 Bad release recovery: operator re-runs the workflow on an older ref]], [[decisions#D10 Per-host state: /persistent via preservation]], [[decisions#D12 Reboots are manual]], [[decisions#D13 Threat model: network and supply-chain only]], [[decisions#D14 Spec scope: platform only]], [[decisions#D16 Disk layout and main root]], [[decisions#D25 Store GC: weekly timer in the main system]].

The NixOS module and class configuration that every host in the class imports: disk layout, zram root, `/persistent`, UKI-only boot, GC timer. Workloads, users and sshd are added on top as ordinary modules ([[decisions#D14 Spec scope: platform only]]). Per [[decisions#D12 Reboots are manual]] the base has no reboot timer and no update polling.

## Interfaces

Produces for [[01-publisher]]: the class configuration attribute `system` (the NixOS evaluation of the host class, as in the archive's README) with `boot.uki` enabled, so that `system.config.system.build.toplevel` and `system.config.system.build.uki` exist. `system.build.uki` contains exactly one `<name>_<version>.efi`. The `main.efi` wrapper and the `release` symlink farm are not part of this component: the publisher owns them and builds them outside the toplevel closure ([[decisions#D7 Main UKI built in CI as part of the toplevel closure]], [[decisions#D26 Release closure: one symlink-farm store path]]).

Shared with [[02-updater]]: this note is authoritative for the disko layout and the mount options; the runtime contract table in [[02-updater]] repeats the values the updater relies on.

The main system consumes the store contents under `/nix` and the GC root the updater maintains. It does not read the ESP at runtime and writes nothing to it (no bootloader).

## Disk layout (disko)

Based on `archive/llm-host.nix`, one disk ([[decisions#D16 Disk layout and main root]]). The target device is one fixed path set in the class configuration (the archive uses `/dev/sda`).

| Partition | Size | Content |
|---|---|---|
| `ESP` (type EF00) | 1G | disko `label = "ESP"`; vfat, `/boot`, `fmask=0177,dmask=0077` (files non-executable; the archive's `umask=0077` is not used) |
| zram backing | 4G | disko `label = "zram-backing-device"`, raw |
| `data` | rest | disko `label = "data"`; btrfs: `@nix` at `/nix`, `@persistent` at `/persistent`; `compress=zstd,noatime,nodiratime,discard` |

The GPT partlabel is disko's `label`, not `name`. The archive sets `label` only on the zram partition, so `ESP` and `data` get explicit labels here, a difference from the archive ([[decisions#D16 Disk layout and main root]]). [Source: read from `lib/types/gpt.nix` of the pinned disko by a review subagent; not run.]

No `EF02` partition. `fileSystems."/nix"` and `"/persistent"` have `neededForBoot = true` and no `nofail` (the archive has `nofail`; dropped, [[decisions#D16 Disk layout and main root]]). `/boot` is mounted by systemd like any other filesystem in the main system and is not `neededForBoot`; if it fails to mount, `local-fs.target` fails and the host drops to the emergency prompt. `fileSystems."/"` is `/dev/zram0`, ext4, `neededForBoot = false`, `noCheck = true`. Weekly `services.btrfs.autoScrub`. [INFERENCE: the ESP mount options produce non-executable files; untested.]

## Root and boot

- Root: `/dev/zram0`, ext4 without journal, created each boot by an initrd systemd unit (`init-zram-root` in the archive): waits for the backing partition, sets zstd, `backing_dev`, and `disksize` = 50% of RAM, then `mkfs.ext4 -O ^has_journal`. The archive's unit settings stay: `TimeoutStartSec=15`, `OnFailure=emergency.target`, `UMask=0077`. `zramSwap` and `zram-generator` stay disabled so no second zram device exists. Nothing triggers zram writeback (the archive has no trigger); the backing partition is configured but unused until a trigger is specified (Open gaps in [[00-index]]).
- The unit script uses bash builtins, `sleep`, `basename`, `/proc`, `/sys` and `mkfs.ext4`. The archive references `mkfs.ext4` by store path and sets no `path` for the others. [INFERENCE: `sleep` and `basename` resolve in the systemd initrd (coreutils); the archive does not show it. The VM test confirms, or the unit sets `path` explicitly.]
- Required initrd and kernel pieces: kernel modules `zram` and `zstd` in the initrd, `supportedFilesystems` `btrfs` and `ext4`, `system.requiredKernelConfig` for `ZRAM` (the archive) and `ZRAM_WRITEBACK` (needed for `backing_dev`; `option yes` in the pinned `common-config.nix`, read by a review subagent). Storage driver modules (sata, nvme, virtio_blk) are a hardware concern left to the host's hardware module; the archive imports `not-detected.nix` for this and the VM test must provide `virtio_blk`.
- `zswap.enabled=0` kernel parameter is required (zram replaces it). `psi=1`, `lru_gen=enabled` and the archive's `vm.*` sysctls are not part of this spec (host or workload tuning).
- No bootloader: `boot.loader` systemd-boot and grub disabled. The main UKI is built by the publisher and delivered by [[02-updater]].
- Initrd stays simple: systemd initrd, the zram unit, btrfs and ext4 support. No network, no fetch logic ([[decisions#D3 Two-stage boot: updater image + main system]]).
- `boot.initrd.systemd.emergencyAccess = true`: console recovery for initrd failures (a failed `/nix` or `/persistent` mount, the zram unit). The archive marks it DEBUG; here it stays on. Physical access is trusted ([[decisions#D13 Threat model: network and supply-chain only]]). Recovery from a broken release ([[decisions#D9 Bad release recovery: operator re-runs the workflow on an older ref]]) needs no shell, only a reset.
- `boot.tmp.useTmpfs = false` stays (the root is already RAM-backed).

## Data and state

Preservation ([[decisions#D10 Per-host state: /persistent via preservation]]) from `/persistent`. The base preserves one file, `/etc/machine-id`, using the archive's three mechanisms together:

1. The preserved entry: `file = "/etc/machine-id"`, `inInitrd = true`, `how = "symlink"`, `configureParent = true`, `createLinkTarget = true` (D-bus breaks if the symlink points to nothing).
2. An initrd tmpfiles rule that creates `/sysroot/persistent/etc/machine-id` with content exactly `uninitialized\n`, so systemd keeps first-boot semantics.
3. The `systemd-machine-id-commit` override: `ConditionPathIsMountPoint` = `/persistent/etc/machine-id`, `ExecStart` = `systemd-machine-id-setup --commit --root /persistent`, which turns the first-boot transient id into a persisted one. [INFERENCE: without this override the persisted file stays `uninitialized`.]

SSH host keys are not preserved by the base. sshd and users are workload scope ([[decisions#D10 Per-host state: /persistent via preservation]]); the module that enables sshd preserves its host keys the same way as the archive does (`how = "symlink"`, `configureParent = true`).

Everything on the RAM root that is not preserved is lost on reboot, including `/home`, `/var`, `/tmp`. `/nix`, `/persistent` and the ESP are separate disk filesystems and survive reboots.

Store GC ([[decisions#D25 Store GC: weekly timer in the main system]]): a timer unit runs `nix-collect-garbage` (no `--delete-old`) with `OnUnitActiveSec=1w` and `OnBootSec=1w`. `OnUnitActiveSec=` alone never elapses (tested with systemd on the authoring host: with only `--on-unit-active=3s` the timer stayed at `NEXT -` and the service never started), so `OnBootSec=1w` provides the first trigger and `OnUnitActiveSec=1w` repeats it. The timer is monotonic because the volatile root loses timer state on every reboot. Consequence: a host that reboots more often than weekly never reaches the first trigger and never collects garbage (D25). The collector deletes everything not reachable from the `current` GC root described in [[02-updater]]; `current` is the release the host booted from.

## Dropped from the archive

Intentionally not in the base: sshd and users (`openssh`, `bert-proesmans`, authorized keys), hostname, locale, `sudo-rs`, oomd, resolved and dnssd, nix settings (so `nix-command` is not enabled on the main system), `hypervGuest`, `kvm-*` modules, `psi`/`lru_gen`/`vm.*` tuning, `boot.loader.efi.canTouchEfiVariables` (no bootloader), `nixpkgs` overlays and `system.stateVersion` (class configuration, set once there), the installer ISO.

## Failure modes and recovery

- `/nix` or `/persistent` fails to mount: with `neededForBoot` and no `nofail` the boot fails. [INFERENCE: untested; Open gaps in [[00-index]].] With `emergencyAccess` the console offers a shell.
- `/boot` fails to mount in the main system: `local-fs.target` fails; emergency prompt. [INFERENCE: untested.]
- Backing partition missing or the zram setup fails: the zram unit times out after 15 s and the initrd goes to the emergency target.
- Disk full: the next updater run fails to fetch and falls back to the installed system (D8). A manual GC run clears it.

## Acceptance criteria

Checks that run `nix` on the main system pass `--extra-experimental-features nix-command`, because the base does not enable it.

- Booted via the VM test, `findmnt /` shows `/dev/zram0` with fstype ext4, `dumpe2fs -h /dev/zram0` lists no `has_journal`, and the size is about 50% of RAM; `zramSwap` and `zram-generator` are absent; `/nix` and `/persistent` are btrfs subvolumes with the options above and no `nofail`.
- `/dev/disk/by-partlabel/ESP`, `/dev/disk/by-partlabel/data` and `/dev/disk/by-partlabel/zram-backing-device` exist after the disko script ran (the updater depends on the first two).
- `/nix` and `/persistent` have `neededForBoot` in the generated configuration, and no bootloader files exist on the ESP when no updater has run.
- `/proc/cmdline` contains `zswap.enabled=0`.
- A file written to `/root` is gone after reboot; a file written to `/home`, `/var` and `/tmp` too.
- `/etc/machine-id` after the first reboot equals the id reported before it, and is not `uninitialized`.
- The GC timer unit is loaded with `OnBootSec=1w` and `OnUnitActiveSec=1w`, and `systemctl list-timers` shows a next elapse (not `-`). With a `current` symlink created by hand at `/nix/var/nix/gcroots/volatile/current` pointing at a release path, running the timer's command keeps the paths reachable from it and deletes an unrooted dummy path.
- The btrfs scrub timer is active with a weekly schedule.
- The ESP, mounted with the disko-generated options, shows no executable bit on a file written to it, and `nix hash path` of that file equals the `nix hash path` of the same bytes at mode `0444` outside the ESP.
- `system.build.uki` of the class configuration contains exactly one `.efi` (shared with [[01-publisher]]).
- Not VM-verified: the mount-failure and emergency-shell outcomes (including `/boot`), the zram backing-partition-missing timeout, and the 15 s `TimeoutStartSec` / `OnFailure=emergency.target` wiring.
