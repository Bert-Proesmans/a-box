# NixOS VM test "a-box-update": node `cache` serves a signed binary cache and update pointer over
# nginx and DHCP via dnsmasq; node `machine` boots the a-box install image through OVMF.
# Subtests: gen 1 install and root growth, gen 2 update, gen 3 update with gen 1 GC, failed update,
# partial download resumed into gen 4, offline boot.
{ lib, pkgs, ... }:
let
  publish = pkgs.callPackage ../publish { };
in
{
  name = "a-box-update";

  defaults = {
    # Nested virtualisation: TSC-deadline timers never fire.
    virtualisation.qemu.options = [ "-cpu max,-kvmclock" ];
    boot.kernelParams = [ "lapic=notscdeadline" ];
  };

  nodes.cache =
    { nodes, ... }:
    {
      networking.firewall.enable = false;

      # Holds the publish staging directory and the served cache.
      virtualisation.diskSize = 8192;

      virtualisation.additionalPaths = map nodes.machine.system.build.a-box-test-generation [
        1
        2
        3
        4
      ];
      environment.systemPackages = [ publish ];

      systemd.tmpfiles.rules = [ "d /srv/www 0755 root root -" ];
      services.nginx = {
        enable = true;
        virtualHosts.cache = {
          default = true;
          root = "/srv/www";
          # Counts NAR downloads in the partial-download subtest.
          extraConfig = "access_log /var/log/nginx/cache.log;";
        };
      };

      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          port = 0;
          interface = "eth1";
          bind-dynamic = true;
          dhcp-range = "192.168.1.100,192.168.1.200,1h";
        };
      };
    };

  nodes.machine =
    {
      config,
      lib,
      nodes,
      extendModules,
      modulesPath,
      ...
    }:
    let
      cacheUrl = "http://${nodes.cache.networking.primaryIPAddress}";
    in
    {
      imports = [
        ../modules/main.nix
        ../machines/example/configuration.nix
        # Smaller closure: the build host keeps VM disks in RAM-backed temp space.
        (modulesPath + "/profiles/minimal.nix")
      ];

      options.a-box-test.generation = lib.mkOption {
        type = lib.types.int;
        default = 1;
      };

      config = {
        a-box = {
          pointerUrl = "${cacheUrl}/a-box/machine";
          substituters = [ "${cacheUrl}/nix-cache" ];
          trustedPublicKeys = [ (lib.fileContents ./cache-key.pub) ];
          updaterModules = [
            {
              boot.kernelParams = [
                "lapic=notscdeadline"
                "systemd.show_status=true"
                "console=ttyS0,115200"
              ];
            }
            # A distinct updater per generation, so the ESP check proves refresh_updater ran.
            {
              boot.initrd.systemd.contents."/etc/a-box-generation".text =
                toString config.a-box-test.generation;
            }
          ];
        };

        environment.etc."a-box-generation".text = toString config.a-box-test.generation;
        system.disableInstallerTools = true;

        system.build.a-box-test-generation =
          n:
          (extendModules {
            modules = [ { a-box-test.generation = n; } ];
          }).config.system.build.toplevel;

        # Boot the install image through OVMF, nothing from the host store.
        virtualisation = {
          directBoot.enable = false;
          mountHostNixStore = false;
          useEFIBoot = true;
          memorySize = 1024;
          fileSystems = lib.mkForce {
            "/" = {
              device = "/dev/disk/by-partlabel/${config.a-box.layout.rootLabel}";
              fsType = "ext4";
            };
          };
        };
      };
    };

  testScript =
    { nodes, ... }:
    let
      gen = nodes.machine.system.build.a-box-test-generation;
    in
    ''
      import os
      import subprocess
      import tempfile

      gens = {1: "${gen 1}", 2: "${gen 2}", 3: "${gen 3}", 4: "${gen 4}"}

      def publish(n):
          cache.succeed(
              "A_BOX_SIGNING_KEY=${./cache-key.sec}"
              " A_BOX_CACHE_DEST=/srv/www/nix-cache"
              " A_BOX_POINTER_DEST=/srv/www/a-box/machine"
              " A_BOX_UPSTREAM="
              f" a-box-publish {gens[n]}"
          )

      def expect(n):
          machine.wait_for_unit("multi-user.target")
          t.assertEqual(machine.succeed("cat /etc/a-box-generation").strip(), str(n))
          t.assertEqual(machine.succeed("readlink -f /run/current-system").strip(), gens[n])

      cache.wait_for_unit("nginx.service")
      cache.wait_for_unit("dnsmasq.service")

      with subtest("install image boots generation 1 and grows root"):
          publish(1)

          # Writable overlay on the image, larger than the image so the root partition must grow.
          # QEMU reads NIX_DISK_IMAGE at start; set it only once cache is running.
          disk = tempfile.NamedTemporaryFile()
          subprocess.run([
              "${nodes.machine.virtualisation.qemu.package}/bin/qemu-img", "create",
              "-f", "qcow2", "-b", "${nodes.machine.system.build.a-box-image}/a-box.raw", "-F", "raw",
              disk.name, "8G",
          ], check=True)
          os.environ["NIX_DISK_IMAGE"] = disk.name
          machine.start(allow_reboot=True)
          expect(1)
          size = int(machine.succeed("df --output=size -B1 / | tail -n1"))
          t.assertGreater(size, 6 * 1024**3)

      with subtest("generation 2 installs, generation 1 kept"):
          publish(2)
          machine.reboot()
          expect(2)
          machine.succeed(f"test -e {gens[1]}")

      with subtest("generation 3 installs, generation 1 collected"):
          publish(3)
          machine.reboot()
          expect(3)
          machine.fail(f"test -e {gens[1]}")
          machine.succeed(f"test -e {gens[2]}")

          # gpt-auto mounts the ESP at /boot.
          t.assertEqual(machine.succeed("ls /boot/loader/entries").split(), ["a-box-2.conf", "a-box-3.conf"])
          machine.succeed("cmp /boot/EFI/Linux/a-box-updater.efi /run/current-system/a-box-updater.efi")

      with subtest("failed update keeps generation 3"):
          # Valid store path, absent from the cache.
          cache.succeed("echo /nix/store/00000000000000000000000000000000-missing > /srv/www/a-box/machine")
          machine.reboot()
          expect(3)

      with subtest("partial download keeps generation 3, next attempt resumes"):
          publish(4)

          # Withhold the toplevel's NAR: its references download, then the update fails.
          info = f"/srv/www/nix-cache/{gens[4][11:43]}.narinfo"
          nar = cache.succeed(f"sed -n 's/^URL: //p' {info}").strip()
          cache.succeed(f"mv /srv/www/nix-cache/{nar} /srv/www/held")

          fetched = cache.succeed(
              f"nix-store -qR {gens[4]} | sort > /tmp/4 && nix-store -qR {gens[3]} | sort > /tmp/3"
              f" && comm -23 /tmp/4 /tmp/3 | grep -vxF {gens[4]}"
          ).split()
          t.assertGreater(len(fetched), 0)

          machine.reboot()
          expect(3)
          for p in fetched:
              machine.succeed(f"test -e {p}")

          # Second attempt fetches only the withheld NAR.
          cache.succeed(f"mv /srv/www/held /srv/www/nix-cache/{nar}")
          machine.reboot()
          expect(4)
          for p in fetched:
              p_nar = cache.succeed(f"sed -n 's/^URL: //p' /srv/www/nix-cache/{p[11:43]}.narinfo").strip()
              t.assertEqual(cache.succeed(f"grep -c ' /nix-cache/{p_nar} ' /var/log/nginx/cache.log").strip(), "1")

      with subtest("offline boot keeps generation 4"):
          cache.succeed("systemctl stop nginx")
          machine.reboot()
          expect(4)
    '';
}
