{ ... }:
{
  networking.hostName = "a-box";

  networking.useNetworkd = true;
  networking.useDHCP = true;

  system.stateVersion = "26.11";
}
