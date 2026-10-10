# Top-level entry point: imports nixpkgs (x86_64-linux) from lon.nix. Evaluates the one main system
# (configuration.nix with modules/main.nix) and builds its updater (updater/) separately. Every
# install is an instance of that one system. Exposes pkgs, pointerUrl, toplevel, updater,
# publish, and tests.update (NixOS VM test).

let
  sources = import ./lon.nix;

  pkgs = import sources.nixpkgs {
    system = "x86_64-linux";
    config = { };
    overlays = [ ];
  };

  storage = "https://storage.proesmans.eu";
  pointerUrl = "${storage}/a-box/main";

  layout = import ./layout.nix;

  main = import (sources.nixpkgs + "/nixos/lib/eval-config.nix") {
    system = null;
    modules = [
      ./modules/main.nix
      ./configuration.nix
      { nixpkgs.pkgs = pkgs; }
    ];
  };
in
{
  inherit pkgs pointerUrl;

  inherit (main.config.system.build) toplevel;

  updater = pkgs.callPackage ./updater {
    inherit pointerUrl;
    inherit (layout) espLabel rootLabel;
    substituters = [
      "${storage}/nix-cache"
      "https://cache.nixos.org"
    ];
    trustedPublicKeys = [
      (pkgs.lib.fileContents ./keys/cache.pub)
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  publish = pkgs.callPackage ./publish { };

  tests.update = pkgs.testers.runNixOSTest ./tests/update.nix;
}
