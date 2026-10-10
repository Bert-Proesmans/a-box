# NixOS configuration of the main system, identical for every install: hostname, systemd-networkd
# with DHCP, stateVersion. The root filesystem comes from modules/main.nix.

{ ... }:
{
  networking.hostName = "a-box";

  networking.useNetworkd = true;
  networking.useDHCP = true;

  system.stateVersion = "26.11";
}
