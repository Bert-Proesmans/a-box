{
  # A router: with forwarding off, the node's neighbour advertisements clear the router flag, and
  # the updater drops the default route it learned from the advertisement (RFC 4861 7.2.5).
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = true;

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
