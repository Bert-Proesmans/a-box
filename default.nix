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
