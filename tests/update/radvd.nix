# Router advertisements on eth1 without DNS servers: SLAAC leaves the updater without a resolver.
{
  services.radvd = {
    enable = true;
    config = ''
      interface eth1 {
        AdvSendAdvert on;
        prefix 2001:db8:1::/64 { };
      };
    '';
  };
}
