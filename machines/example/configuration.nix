# NixOS configuration for the "example" machine. Sets the hostname, enables systemd-networkd with
# DHCP, and sets system.stateVersion to "26.11". States that boot loader, root filesystem and
# cache settings come from modules/main.nix.

{ ... }:
{
  networking.hostName = "example";

  networking.useNetworkd = true;
  networking.useDHCP = true;

  system.stateVersion = "26.11";
}
