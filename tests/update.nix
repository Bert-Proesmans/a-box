{ lib, pkgs, ... }:
let
  publish = pkgs.callPackage ../publish { };
  layout = import ../layout.nix;
in
{
  name = "a-box-update";

  # An updater stuck in its emergency shell would otherwise hold the build for an hour.
  globalTimeout = 1500;

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
      extendModules,
      modulesPath,
      ...
    }:
    {
      imports = [
        ../modules/main.nix
        ../configuration.nix
        # Smaller closure: the build host keeps VM disks in RAM-backed temp space.
        (modulesPath + "/profiles/minimal.nix")
      ];

      options.a-box-test.generation = lib.mkOption {
        type = lib.types.int;
        default = 1;
      };

      config = {
        environment.etc."a-box-generation".text = toString config.a-box-test.generation;
        system.disableInstallerTools = true;

        system.build.a-box-test-generation =
          n:
          (extendModules {
            modules = [ { a-box-test.generation = n; } ];
          }).config.system.build.toplevel;

        # Boot the test disk through OVMF, nothing from the host store.
        virtualisation = {
          directBoot.enable = false;
          mountHostNixStore = false;
          useEFIBoot = true;
          memorySize = 1536;
          fileSystems = lib.mkForce {
            "/" = {
              device = "/dev/disk/by-partlabel/${layout.rootLabel}";
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
      cacheUrl = "http://${nodes.cache.networking.primaryIPAddress}";

      updater = pkgs.callPackage ../updater {
        pointerUrl = "${cacheUrl}/a-box/machine";
        substituters = [ "${cacheUrl}/nix-cache" ];
        trustedPublicKeys = [ (lib.fileContents ./cache-key.pub) ];
        inherit (layout) espLabel rootLabel;
        kernelParams = [
          "console=ttyS0,115200"
          "lapic=notscdeadline"
        ];
      };

      # What an admin does by hand: the updater on the ESP, an ext4 root partition next to it.
      disk =
        (import (pkgs.path + "/nixos/lib/eval-config.nix") {
          system = null;
          modules = [
            (pkgs.path + "/nixos/modules/image/repart.nix")
            {
              nixpkgs.pkgs = pkgs;
              system.stateVersion = lib.trivial.release;
              image.repart = {
                enable = true;
                name = "a-box-test";
                sectorSize = 512;
                partitions = {
                  "10-esp" = {
                    contents."/EFI/BOOT/BOOTX64.EFI".source = updater.uki;
                    repartConfig = {
                      Type = "esp";
                      Format = "vfat";
                      Label = layout.espLabel;
                      SizeMinBytes = "256M";
                      SizeMaxBytes = "256M";
                    };
                  };
                  "20-root".repartConfig = {
                    Type = "linux-generic";
                    Format = "ext4";
                    Label = layout.rootLabel;
                    SizeMinBytes = "4G";
                    SizeMaxBytes = "4G";
                  };
                };
              };
            }
          ];
        }).config.system.build.image;
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
          # Started by systemd-boot from the ESP the updater filled, not by the updater or firmware.
          t.assertIn(f"init={gens[n]}/init", machine.succeed("cat /proc/cmdline"))
          machine.succeed("ls /sys/firmware/efi/efivars | grep -q '^LoaderEntrySelected-'")

      def boot_order():
          return machine.succeed("cat /sys/firmware/efi/efivars/BootOrder-* 2>/dev/null | od -An -tx1").strip()

      cache.wait_for_unit("nginx.service")
      cache.wait_for_unit("dnsmasq.service")

      with subtest("updater installs generation 1 and starts it"):
          publish(1)

          # Writable overlay on the disk, so every subtest starts from the previous one's state.
          # QEMU reads NIX_DISK_IMAGE at start; set it only once cache is running.
          overlay = tempfile.NamedTemporaryFile()
          subprocess.run([
              "${nodes.machine.virtualisation.qemu.package}/bin/qemu-img", "create",
              "-f", "qcow2", "-b", "${disk}/a-box-test.raw", "-F", "raw", overlay.name,
          ], check=True)
          os.environ["NIX_DISK_IMAGE"] = overlay.name
          machine.start(allow_reboot=True)
          expect(1)
          order = boot_order()

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

      with subtest("firmware boot order is unchanged"):
          t.assertEqual(boot_order(), order)
    '';
}
