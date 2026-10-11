# DHCPv4 on eth1 with the cache node as router. dns: the cache node as DNS server, resolving the
# cache name; without it the lease carries no DNS server (dnsmasq omits the option when port = 0,
# see rfc2131.c).
{
  dns ? true,
}:
{ config, ... }:
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
          host-record = "cache.a-box.test,${config.networking.primaryIPAddress}";
        }
      else
        { port = 0; }
    );
  };
}
