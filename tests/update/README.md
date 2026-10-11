# tests/update

| File | Description |
| --- | --- |
| `default.nix` | Assembles the shared pieces (`updater`, test disk, generations, binary cache, VM/network modules) once and exposes one update test per network scenario: `ipv4`, `ipv6`, `dualstack`, `no-dns`, `offline`, `corrupt` |
| `mk-test.nix` | Builds one NixOS VM test for an updater scenario: a `cache` node serving the binary cache plus a `machine` node booted from a writable overlay of the test disk, with shared Python helpers (`publish`, `start`, `expect`) that check the machine boots the expected generation via systemd-boot/BootNext without altering firmware boot order, followed by the scenario's `testScript` |
| `ipv4.nix` | VM test that the updater, fetching over IPv4 via DHCP from a cache, installs a published generation on first boot, upgrades to a newer one on reboot while keeping the old generation, and stays put when nothing new is published |
| `ipv6.nix` | Checks that the updater installs and keeps system generations on an IPv6 SLAAC-only link (radvd, no DHCP or DNS), falling back to Google Public DNS |
| `dualstack.nix` | VM test that the updater fetches and installs new generations on boot, and stays put when current, with the cache reached over both IPv4 and IPv6 (`dhcp` with AAAA, `radvd` SLAAC); asserts nginx saw requests from the machine's SLAAC address at each step |
| `no-dns.nix` | Update test: when DHCP supplies no DNS, the updater falls back to Google Public DNS (`8.8.8.8`), installs the first generation, picks up a newly published one on reboot, and stays put when nothing is new |
| `offline.nix` | VM test that the updater tolerates a missing network: with no system installed it retries until the link returns and installs generation 1; with the link down it boots the existing generation, then installs the newly published generation 2 on a later online reboot; and when nothing new exists it keeps generation 2 |
| `corrupt.nix` | Checks that the updater survives a corrupted cache NAR (hash mismatch): it keeps the current system or retries when none is installed, then installs the intact NAR or replaces a half-written store path on a later boot, and stays up to date once current |
| `cache.nix` | Test-VM module that serves the prebuilt `binaryCache` at `/nix-cache/` and the update pointer under `/srv/www/a-box` over HTTP via nginx |
| `dhcp.nix` | Test-node module that runs `dnsmasq` as a DHCPv4 server on `eth1` with the cache node as router, optionally (`dns`) also serving as DNS resolving `cache.a-box.test` (plus its IPv6 address with `aaaa`), or handing out leases with no DNS server when `dns` is off |
| `radvd.nix` | Test fixture enabling `services.radvd` to advertise the `2001:db8:1::/64` prefix on `eth1` with no DNS options, so SLAAC gives the updater an IPv6 address but no resolver |
| `google-dns.nix` | NixOS test module that fakes Google Public DNS at `address` (added to `lo`), answering `cache.a-box.test` with the node's primary IPv4/IPv6 so update tests resolve the cache without real DNS |
| `binary-cache.nix` | Test fixture: builds a signed, zstd-compressed binary cache holding update-test generations 1 and 2 by running the real `a-box-publish`, plus a `pointer-N` file per generation showing what publishing it writes |
| `generations.nix` | Builds the generation 1 and 2 system toplevels once, from a `machine` node beside an empty `cache` node, so every update test scenario reuses them |
| `machine.nix` | Test NixOS system the updater installs: the real a-box config on a minimal profile, with `a-box-test.generation` written to `/etc/a-box-generation` so `system.build.a-box-test-generation` can build generations that differ only by that number |
| `vm.nix` | NixOS test-VM module that boots the update test's own disk image via OVMF/EFI with no host store mounted, a 1 GiB memory floor, and `eth0` on an isolated hub (no DHCP/DNS/IPv6 RA from QEMU user networking) |
| `updater.nix` | Builds the `updater` package configured for the test disk, so it fetches the pointer and substitutes from the test cache node (`cache.a-box.test`), trusts the test cache key, and boots with the serial-console kernel params |
| `disk.nix` | Builds the test disk image a manual install would produce: an ESP carrying the updater UKI as `BOOTX64.EFI` plus an empty ext4 root partition, labelled per `layout`, for the update tests to boot |
