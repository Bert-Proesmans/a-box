let
  sources = import ./lon.nix;

  pkgs = import sources.nixpkgs {
    system = "x86_64-linux";
    config = { };
    overlays = [ ];
  };

  layout = import ./layout.nix;

  main = import (sources.nixpkgs + "/nixos/lib/eval-config.nix") {
    system = null;
    modules = [
      ./modules/main.nix
      ./configuration.nix
      { nixpkgs.pkgs = pkgs; }
    ];
  };

  updater = pkgs.callPackage ./updater {
    pointerUrl = "https://storage.proesmans.eu/nix-cache/a-box/main";
    inherit (layout) espLabel rootLabel;
    substituters = [
      "https://storage.proesmans.eu/nix-cache"
      "https://cache.nixos.org"
    ];
    trustedPublicKeys = [
      (pkgs.lib.fileContents ./keys/cache.pub)
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };
in
{
  inherit pkgs;

  inherit (main.config.system.build) toplevel;

  # Boot media: `nix-build -A updaterIso`, `-A installerIso`, `-A netboot`, `-A netboot.githubRelease`.
  updaterIso = updater.iso;
  inherit (updater) installerIso netboot;

  publish = pkgs.callPackage ./publish { };

  tests.update = import ./tests/update { inherit pkgs; };
}
