{
  lib,
  pkgs,
  layout,
  diskoFormat,
}:
let
  # Resolved through DHCP-provided DNS, or through the Google Public DNS fallback.
  cacheUrl = "http://cache.a-box.test";
in
pkgs.callPackage ../../updater {
  pointerUrl = "${cacheUrl}/a-box/machine";
  substituters = [ "${cacheUrl}/nix-cache" ];
  trustedPublicKeys = [ (lib.fileContents ../cache-key.pub) ];
  inherit (layout)
    espLabel
    dataLabel
    nixSubvolume
    diskPlaceholder
    ;
  inherit diskoFormat;
  # The installer shares them: its own UKI needs the console and the timer workaround too.
  kernelParams = [
    "console=ttyS0,115200"
    "lapic=notscdeadline"
  ];
}
