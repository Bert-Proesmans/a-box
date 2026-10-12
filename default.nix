let
  # Imported once, then threaded through as arguments: modules get `sources` and `layout` as
  # specialArgs, the updater and the tests get them as callPackage arguments.
  sources = import ./lon.nix;
  layout = import ./layout.nix;

  pkgs = import sources.nixpkgs {
    system = "x86_64-linux";
    config = { };
    overlays = [ ];
  };

  main = import (sources.nixpkgs + "/nixos/lib/eval-config.nix") {
    system = null;
    specialArgs = { inherit sources layout; };
    modules = [
      ./modules/main.nix
      ./configuration.nix
      { nixpkgs.pkgs = pkgs; }
    ];
  };

  # The installer formats the disk with the main system's disko script, referenced without its
  # dependencies: the script is a plain bash file and the installer brings the few tools it needs.
  # The disk device is a placeholder that a-box-install replaces.
  diskoFormat =
    (main.extendModules {
      modules = [ { disko.devices.disk.main.device = layout.diskPlaceholder; } ];
    }).config.system.build.formatScriptNoDeps;

  updater = pkgs.callPackage ./updater {
    pointerUrl = "https://storage.proesmans.eu/nix-cache/a-box/main";
    inherit (layout)
      espLabel
      dataLabel
      nixSubvolume
      diskPlaceholder
      ;
    inherit diskoFormat;
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

  tests.update = import ./tests/update {
    inherit
      pkgs
      sources
      layout
      diskoFormat
      ;
  };
}
