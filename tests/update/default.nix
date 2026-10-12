{
  pkgs,
  sources,
  layout,
  diskoFormat,
}:
let
  # Shared pieces, each built once. Scenarios take what they need as arguments.
  scope = pkgs.lib.makeScope pkgs.newScope (self: {
    inherit sources layout diskoFormat;

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
    vm = import ./vm.nix;
    machine = import ./machine.nix { inherit (self) vm; };
    cacheBase = import ./cache.nix { inherit (self) binaryCache; };
    dhcp = import ./dhcp.nix;
    radvd = import ./radvd.nix;
    googleDns = import ./google-dns.nix;
  });
in
pkgs.lib.genAttrs [
  "ipv4"
  "volatile"
  "ipv6"
  "no-dns"
  "offline"
  "corrupt"
] (scenario: scope.callPackage ./${scenario}.nix { })
