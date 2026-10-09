# Top-level entry point: imports nixpkgs (x86_64-linux) from lon.nix and evaluates each machine
# (currently `example`) with modules/main.nix. Exposes pkgs, machineNames,
# machines.<name>.{toplevel,image,updater,pointerUrl}, publish, and tests.update (NixOS VM test).

let
  sources = import ./lon.nix;

  pkgs = import sources.nixpkgs {
    system = "x86_64-linux";
    config = { };
    overlays = [ ];
  };

  evalMachine =
    configuration:
    import (sources.nixpkgs + "/nixos/lib/eval-config.nix") {
      system = null;
      modules = [
        ./modules/main.nix
        configuration
        { nixpkgs.pkgs = pkgs; }
      ];
    };

  machines = {
    example = evalMachine ./machines/example/configuration.nix;
  };
in
{
  inherit pkgs;

  machineNames = builtins.attrNames machines;

  machines = builtins.mapAttrs (_: machine: {
    inherit (machine.config.system.build) toplevel;
    image = machine.config.system.build.a-box-image;
    updater = machine.config.system.build.a-box-updater;
    inherit (machine.config.a-box) pointerUrl;
  }) machines;

  publish = pkgs.callPackage ./publish { };

  tests.update = pkgs.testers.runNixOSTest ./tests/update.nix;
}
