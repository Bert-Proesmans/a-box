{
  self ? (import ./llm-host.nix { }),
  # Version-pinned dependencies, managed through the "lon" CLI.
  # REF; https://github.com/nikstur/lon
  sources ? (import ./lon.nix),
}:
let

  # Collection of helper methods.
  # SEEALSO; https://noogle.dev
  lib = (import (sources.nixpkgs + "/lib")).extend (
    final: _prev: {
      # WARN; Extend by namespacing additional functionality to not clobber symbols used by upstream/downstream code!s

      # Includes runTest and evalModules helpers.
      nixos = import (sources.nixpkgs + "/nixos/lib") { lib = final; };
    }
  );

  _nixosSystemFunc = import (sources.nixpkgs + "/nixos/lib/eval-config.nix");
  # Function that wraps system configuration into something to be eval'ed and built.
  nixosSystem =
    newArgs:
    _nixosSystemFunc (
      {
        inherit lib;
        system = null; # Deprecated
        pkgs = null; # Deprecated
      }
      // newArgs
    );
in
{
  # Setting outPath makes (toString self) work eg, "${self}/functionality.nix"
  outPath = ./.;

  system = nixosSystem {
    specialArgs = { inherit self sources; };
    modules = [
      (
        {
          modulesPath,
          sources,
          lib,
          utils,
          pkgs,
          config,
          ...
        }:
        {
          system.stateVersion = "26.05";
          nixpkgs.hostPlatform = "x86_64-linux";
          nixpkgs.config.allowUnfreePredicate =
            pkg:
            builtins.elem (lib.getName pkg) [
              "claude-code"
            ];

          imports = [
            (sources.disko + "/module.nix")
            (sources.preservation + "/module.nix")
            # TODO; Remove on completion of hardware config
            (modulesPath + "/installer/scan/not-detected.nix")
            ./systemd-dnssd.nix
          ];

          system.requiredKernelConfig = [
            (config.lib.kernelConfig.isEnabled "ZRAM")
          ];
          boot.initrd = {
            enable = true;
            kernelModules = [
              "zram"
              "zstd"
            ];
            supportedFilesystems = [
              "btrfs"
              "ext4"
            ];
            systemd = {
              enable = true;
              # DEBUG; Remove after succesful boot
              emergencyAccess = true;
              services.init-zram-root = {
                enable = true;
                description = "Initialize ZRAM Root Device";
                wantedBy = [ "initrd-root-device.target" ];
                before = [
                  "sysroot.mount"
                  "shutdown.target"
                ];
                after = [ "systemd-modules-load.service" ];
                conflicts = [
                  "initrd-switch-root.target"
                  "shutdown.target"
                ];

                unitConfig.FailureAction = "none";
                unitConfig.OnFailure = [ "emergency.target" ];
                unitConfig.DefaultDependencies = false;

                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  TimeoutStartSec = "15";
                  UMask = "0077";
                };

                script = ''
                  #!/bin/bash
                  set -euo pipefail

                  BACKING_DEV="/dev/disk/by-partlabel/zram-backing-device"
                  ZRAM_DEV="/dev/zram0"
                  SYS_BLOCK="/sys/block/$(basename "$ZRAM_DEV")"

                  while [ ! -b "$BACKING_DEV" ]; do
                    sleep 0.5
                  done

                  while [ ! -d "$SYS_BLOCK" ]; do
                    sleep 0.5
                  done

                  echo 'zstd' > "$SYS_BLOCK/comp_algorithm"
                  echo "$BACKING_DEV" > "$SYS_BLOCK/backing_dev"

                  # Set memory size (50% of RAM)
                  read _ total_kb _ < /proc/meminfo
                  echo $(( total_kb * 512 )) > "$SYS_BLOCK/disksize"

                  # Format partition
                  ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L root -O ^has_journal "$ZRAM_DEV"
                '';
              };
            };
          };
          # DO NOT setup another ZRAM device!
          zramSwap.enable = lib.mkForce false;
          services.zram-generator.enable = lib.mkForce false;
          virtualisation.hypervGuest.enable = true;

          fileSystems."/" = {
            device = "/dev/zram0";
            fsType = "ext4";
            # fsType = "tmpfs";
            neededForBoot = false;
            noCheck = true;
          };
          fileSystems."/nix".neededForBoot = true;
          fileSystems."/persistent".neededForBoot = true; # sometimes needed too

          # disko.devices.nodev = {
          #   "/" = {
          #     fsType = "tmpfs";
          #     mountOptions = [
          #       "size=25%"
          #       "mode=755"
          #     ];
          #   };
          # };

          disko.devices.disk.main = {
            device = "/dev/sda";
            type = "disk";

            content.type = "gpt";

            content.partitions.boot = {
              name = "boot";
              size = "1M";
              type = "EF02";
            };

            content.partitions.esp = {
              name = "ESP";
              size = "1G";
              type = "EF00";

              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };

            content.partitions.swap = {
              size = "4G";
              label = "zram-backing-device";
            };

            content.partitions.data = {
              name = "data";
              size = "100%";

              content = {
                type = "btrfs";
                extraArgs = [ "-f" ]; # Override existing partition

                # mountpoint = "/btrfs_pool";
                # # btrfs's top-level subvolume, internally has an id 5
                # # we can access all other subvolumes from this subvolume.
                # mountOptions = [ "subvolid=5" ];

                subvolumes = {
                  "@persistent" = {
                    mountpoint = "/persistent";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                      "nodiratime"
                      "discard"
                      "nofail"
                    ];
                  };

                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                      "nodiratime"
                      "discard"
                      "nofail"
                    ];
                  };
                };
              };
            };
          };

          preservation = {
            enable = true;

            preserveAt."/persistent" = {
              directories = [ ];

              files = [
                {
                  file = "/etc/machine-id";
                  inInitrd = true;
                  how = "symlink";
                  configureParent = true;
                }
                {
                  file = "/etc/ssh/ssh_host_rsa_key";
                  how = "symlink";
                  configureParent = true;
                }
                {
                  file = "/etc/ssh/ssh_host_ed25519_key";
                  how = "symlink";
                  configureParent = true;
                }
              ];

              users.bert-proesmans = {
                directories = [
                  # { directory = ".ssh"; mode = "0700"; }
                  ".claude"
                ];
                files = [ ];
              };
            };
          };

          boot.kernelModules = [
            # Enables (nested) virtualization through hardware acceleration.
            # There is no harm in having both modules loaded at the same time, also no real overhead.
            "kvm-amd"
            "kvm-intel"
          ];
          boot.loader.systemd-boot.enable = true;
          boot.loader.efi.canTouchEfiVariables = false;

          networking.hostName = "llm-host";

          security.sudo-rs = {
            enable = true;
            execWheelOnly = true;
            wheelNeedsPassword = true;
          };

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
          nix.settings.connect-timeout = 5;
          nix.settings.log-lines = 25;

          users.mutableUsers = false;
          users.users.bert-proesmans = {
            isNormalUser = true;
            description = "Bert Proesmans";
            password = "testing123"; # DEBUG
            extraGroups = [
              "wheel" # Enable 'sudo' for the user
              "systemd-journal" # Read the systemd service journal without sudo
            ];
            openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOs8kDMMm/QFeELt79EG9akdfX7dlfRuTezwVEqbPsM bert@B-PC"
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILEeQ/KEIWbUKBc4bhZBUHsBB0yJVZmBuln8oSVrtcA5 bert@B-PC"
            ];
            packages = [ ];
          };

          # Force be-latin keymap (= BE-AZERTY-ISO)
          services.xserver.xkb.layout = "be";
          services.xserver.xkb.variant = ""; # Explicitly empty!
          # NOTE; Make CAPSLOCK behave like on Windows, print numbers instead of uppercased special characters.
          services.xserver.xkb.options = "caps:digits_row";
          console.useXkbConfig = true;

          time.timeZone = "Europe/Brussels";
          i18n = {
            defaultLocale = lib.mkDefault "en_GB.UTF-8";
            extraLocales = [
              "en_GB.UTF-8/UTF-8"
              "nl_BE.UTF-8/UTF-8"
            ];
            # REF; https://man.archlinux.org/man/locale.7
            extraLocaleSettings = {
              LC_NUMERIC = lib.mkDefault "nl_BE.UTF-8";
              LC_TIME = lib.mkDefault "nl_BE.UTF-8";
              LC_MONETARY = lib.mkDefault "nl_BE.UTF-8";
              LC_PAPER = lib.mkDefault "nl_BE.UTF-8";
              LC_NAME = lib.mkDefault "nl_BE.UTF-8";
              LC_ADDRESS = lib.mkDefault "nl_BE.UTF-8";
              LC_TELEPHONE = lib.mkDefault "nl_BE.UTF-8";
              LC_MEASUREMENT = lib.mkDefault "nl_BE.UTF-8";
              LC_IDENTIFICATION = lib.mkDefault "nl_BE.UTF-8";
            };
          };

          environment.systemPackages = [
            pkgs.git
            pkgs.claude-code
          ];

          services.btrfs.autoScrub = {
            enable = true;
            interval = "weekly";
          };

          services.resolved = {
            enable = true;
            settings.Resolve = {
              # Disabled in favour of mDNS
              LLMNR = false;
              # mDNS responder and resolver
              MulticastDNS = true;
              Domains = [ "~." ];
            };
          };

          systemd.dnssd.services = {
            ssh = {
              hostname = "%H";
              type = "_ssh._tcp";
              port = 22;
            };
          };

          services.openssh = {
            enable = true;
            allowSFTP = false;
            settings.PasswordAuthentication = false;
            settings.KbdInteractiveAuthentication = false;
            extraConfig = ''
              AllowTcpForwarding no
              X11Forwarding no
              AllowAgentForwarding no
              AllowStreamLocalForwarding no
              AuthenticationMethods publickey
            '';
          };

          systemd.services.systemd-machine-id-commit = {
            unitConfig.ConditionPathIsMountPoint = [
              ""
              "/persistent/etc/machine-id"
            ];
            serviceConfig.ExecStart = [
              ""
              "systemd-machine-id-setup --commit --root /persistent"
            ];
          };
        }
      )
    ];
  };

  installer =
    (nixosSystem {
      specialArgs = { inherit self sources; };
      modules = [
        (
          {
            modulesPath,
            lib,
            pkgs,
            config,
            ...
          }:
          {
            imports = [
              "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
              ./systemd-dnssd.nix
            ];

            boot.initrd.systemd.emergencyAccess = true;
            # Enables (nested) virtualization through hardware acceleration.
            # There is no harm in having both modules loaded at the same time, also no real overhead.
            boot.kernelModules = [
              "kvm-amd"
              "kvm-intel"
            ];
            # enable zswap to help with low memory systems
            boot.kernelParams = [
              "zswap.enabled=1"
              "zswap.max_pool_percent=50"
              "zswap.compressor=zstd"
              # recommended for systems with little memory
              "zswap.zpool=zsmalloc"
            ];
            boot.zfs.forceImportRoot = false; # Silence warning about unsafe default

            # Minimal-installer (useful for mDNS)
            networking.hostName = lib.mkForce "minstaller";
            nixpkgs.hostPlatform = lib.mkForce "x86_64-linux";
            system.stateVersion = lib.mkForce config.system.nixos.release;

            # Ensure sshd works
            systemd.services.sshd.wantedBy = [ "multi-user.target" ];
            users.users.nixos.openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOs8kDMMm/QFeELt79EG9akdfX7dlfRuTezwVEqbPsM bert@B-PC"
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILEeQ/KEIWbUKBc4bhZBUHsBB0yJVZmBuln8oSVrtcA5 bert@B-PC"
            ];

            # Force be-latin keymap (= BE-AZERTY-ISO)
            services.xserver.xkb.layout = "be";
            services.xserver.xkb.variant = ""; # Explicitly empty!
            # NOTE; Make CAPSLOCK behave like on Windows, print numbers instead of uppercased special characters.
            services.xserver.xkb.options = "caps:digits_row";
            console.useXkbConfig = true;

            time.timeZone = "Europe/Brussels";
            i18n = {
              defaultLocale = lib.mkDefault "en_GB.UTF-8";
              extraLocales = [
                "en_GB.UTF-8/UTF-8"
                "nl_BE.UTF-8/UTF-8"
              ];
              # REF; https://man.archlinux.org/man/locale.7
              extraLocaleSettings = {
                LC_NUMERIC = lib.mkDefault "nl_BE.UTF-8";
                LC_TIME = lib.mkDefault "nl_BE.UTF-8";
                LC_MONETARY = lib.mkDefault "nl_BE.UTF-8";
                LC_PAPER = lib.mkDefault "nl_BE.UTF-8";
                LC_NAME = lib.mkDefault "nl_BE.UTF-8";
                LC_ADDRESS = lib.mkDefault "nl_BE.UTF-8";
                LC_TELEPHONE = lib.mkDefault "nl_BE.UTF-8";
                LC_MEASUREMENT = lib.mkDefault "nl_BE.UTF-8";
                LC_IDENTIFICATION = lib.mkDefault "nl_BE.UTF-8";
              };
            };

            services.resolved = {
              enable = true;
              settings.Resolve = {
                # Disabled in favour of mDNS
                LLMNR = false;
                # mDNS responder and resolver
                MulticastDNS = true;
                Domains = [ "~." ];
              };
            };

            systemd.dnssd.services = {
              ssh = {
                hostname = "%H";
                type = "_ssh._tcp";
                port = 22;
              };
            };

            environment.systemPackages = [
              (pkgs.writeShellApplication {
                name = "quick-install";
                runtimeInputs = [ pkgs.nixos-install-tools ];
                text = ''
                  echo "===================================================="
                  echo "            NixOS Off-line Installation             "
                  echo "===================================================="
                  echo "This script will execute the following steps:"
                  echo "  1. Partition and format the target storage drive."
                  echo "  2. Mount the target partitions to /mnt."
                  echo "  3. Copy the pre-built system closure from /nix/store."
                  echo "  4. Install the bootloader and finalize configuration."
                  echo ""
                  echo "WARNING: All data on the target drive will be wiped."
                  echo "===================================================="
                  echo ""

                  read -r -p "Press [Enter] to begin installation (or Ctrl+C to abort)..."

                  echo "Starting.."
                  ${self.system.config.system.build.diskoScript}
                  echo "Filesystems prepared.."


                  nixos-install --system ${self.system.config.system.build.toplevel} --no-root-passwd --no-channel-copy
                  echo "System closure installed.."

                  echo "DONE. Please reboot the computer"
                '';
              })
            ];

            # Make the image as small as possible #
            isoImage.storeContents = [ self.system.config.system.build.toplevel ];
            # Faster and (almost) equally as good compression
            isoImage.squashfsCompression = lib.mkForce "zstd -Xcompression-level 15";

            networking.wireless.enable = lib.mkForce false;
            documentation.enable = lib.mkForce false;
            documentation.nixos.enable = lib.mkForce false;
            documentation.man.man-db.enable = lib.mkForce false;

            # Drop ~400MB firmware blobs from nix/store, but this will make the host not boot on bare-metal!
            hardware.enableRedistributableFirmware = lib.mkForce false;

            # ERROR; The mkForce is required to _reset_ the lists to empty! While the default
            # behaviour is to make a union of all list components!
            # No GCC toolchain
            system.extraDependencies = lib.mkForce [ ];
            # Remove default packages not required for a bootable system
            environment.defaultPackages = lib.mkForce [ ];
            # prevents shipping nixpkgs, unnecessary if system is evaluated externally
            nix.registry = lib.mkForce { };

            # Remove references to Filesystem Hierarchy Standard (FHS) compatibility shims, this makes FHS at runtime impossible
            environment.ldso = lib.mkForce null;
            environment.ldso32 = lib.mkForce null;
          }
        )
      ];
    }).config.system.build.isoImage;
}
