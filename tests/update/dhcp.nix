# DHCPv4 on eth1 with the cache node as router. dns: the cache node as DNS server, resolving the
# cache name; without it the lease carries no DNS server (dnsmasq omits the option when port = 0,
# see rfc2131.c). aaaa: the name resolves to the IPv6 address too.
{
  dns ? true,
  aaaa ? false,
}:
{ config, lib, ... }:
{
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      interface = "eth1";
      bind-dynamic = true;
      dhcp-range = "192.168.1.100,192.168.1.200,1h";
    }
    // (
      if dns then
        {
          no-resolv = true;
          # Authoritative: NODATA for missing records. musl ignores REFUSED and would time out.
          local = "/a-box.test/";
          host-record = lib.concatStringsSep "," (
            [
              "cache.a-box.test"
              config.networking.primaryIPAddress
            ]
            ++ lib.optional aaaa config.networking.primaryIPv6Address
          );
        }
      else
        { port = 0; }
    );
  };
}
