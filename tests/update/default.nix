{ pkgs }:
let
  # Shared pieces, each built once. Scenarios take what they need as arguments.
  scope = pkgs.lib.makeScope pkgs.newScope (self: {
    layout = import ../../layout.nix;

    # Both nodes and the generations.
    testDefaults = {
      # Nested virtualisation: TSC-deadline timers never fire.
      virtualisation.qemu.options = [ "-cpu max,-kvmclock" ];
      boot.kernelParams = [ "lapic=notscdeadline" ];

      # Multithreaded zstd.
      virtualisation.cores = 2;
    };

    updater = self.callPackage ./updater.nix { };
    testDisk = self.callPackage ./disk.nix { };
    generations = self.callPackage ./generations.nix { };
    binaryCache = self.callPackage ./binary-cache.nix { };
    mkTest = self.callPackage ./mk-test.nix { };

    # NixOS modules.
    vm = import ./vm.nix { inherit (self) layout; };
    machine = import ./machine.nix { inherit (self) vm; };
    cacheBase = import ./cache.nix { inherit (self) binaryCache; };
    dhcp = import ./dhcp.nix;
    radvd = import ./radvd.nix;
    googleDns = import ./google-dns.nix;
  });
in
pkgs.lib.genAttrs [
  "ipv4"
  "ipv6"
  "dualstack"
  "no-dns"
  "offline"
  "corrupt"
] (scenario: scope.callPackage ./${scenario}.nix { })
