# The updater as the test disk carries it: pointer and binary cache on the cache node.
{
  lib,
  pkgs,
  layout,
}:
let
  # Resolved through DHCP-provided DNS, or through the Google Public DNS fallback.
  cacheUrl = "http://cache.a-box.test";
in
pkgs.callPackage ../../updater {
  pointerUrl = "${cacheUrl}/a-box/machine";
  substituters = [ "${cacheUrl}/nix-cache" ];
  trustedPublicKeys = [ (lib.fileContents ../cache-key.pub) ];
  inherit (layout) espLabel rootLabel;
  kernelParams = [
    "console=ttyS0,115200"
    "lapic=notscdeadline"
  ];
}
