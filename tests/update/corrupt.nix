{
  lib,
  mkTest,
  dhcp,
  binaryCache,
}:
mkTest {
  name = "corrupt";

  # The NARs writable for corrupt() and restore(): an overlay on the prepared cache, served instead.
  cache = {
    imports = [ (dhcp { }) ];

    virtualisation.fileSystems."/srv/www/nix-cache".overlay = {
      lowerdir = [ "${binaryCache}/nix-cache" ];
      upperdir = "/srv/nix-cache-rw/upper";
      workdir = "/srv/nix-cache-rw/work";
    };
    services.nginx.virtualHosts.cache.locations."/nix-cache/".alias = lib.mkForce "/srv/www/nix-cache/";
  };

  testScript = ''
    # The NAR of gen n's toplevel on the cache, as named by its narinfo.
    def nar(n):
        info = f"/srv/www/nix-cache/{gens[n][11:43]}.narinfo"
        return "/srv/www/nix-cache/" + cache.succeed(f"sed -n 's/^URL: //p' {info}").strip()

    # Another path's NAR in its place: it decompresses, then fails nix's hash check.
    def corrupt(n):
        target = nar(n)
        other = cache.succeed(f"ls -S /srv/www/nix-cache/nar/* | grep -vxF {target} | tail -n 1").strip()
        cache.succeed(f"cp {target} /tmp/nar && cp {other} {target}")

    def restore(n):
        cache.succeed(f"mv /tmp/nar {nar(n)}")

    with subtest("no system: updater installs generation 1"):
        publish(1)
        corrupt(1)
        start()
        # Nix colours the path.
        machine.wait_for_console_text(f"hash mismatch importing path '.*{gens[1]}")
        machine.wait_for_console_text("a-box: update failed; keeping current system")
        machine.wait_for_console_text("a-box: no system installed; retrying in 30s")

        # The next attempt fetches the intact NAR.
        restore(1)
        expect(1)

    with subtest("generation 2 published: updater installs it on reboot"):
        publish(2)
        corrupt(2)
        machine.reboot()
        machine.wait_for_console_text(f"hash mismatch importing path '.*{gens[2]}")
        machine.wait_for_console_text("a-box: update failed; keeping current system")
        expect(1)

        # A half-written, unregistered toplevel, as after a power cut, in place of whatever the
        # failed import left. Nix replaces it.
        restore(2)
        machine.succeed(
            "mount -o remount,rw,bind /nix/store",
            f"rm -rf {gens[2]}",
            f"mkdir {gens[2]}",
            f"echo garbage > {gens[2]}/garbage",
            "sync",
        )
        machine.reboot()
        expect(2)
        machine.succeed(f"test -e {gens[1]}")

    with subtest("nothing new: updater keeps generation 2"):
        machine.reboot()
        machine.wait_for_console_text("a-box: up to date")
        expect(2)
  '';
}
