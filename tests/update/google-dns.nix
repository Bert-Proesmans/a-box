{ address }:
{
  config,
  lib,
  pkgs,
  ...
}:
{
  systemd.services.google-dns = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStartPre = "${pkgs.iproute2}/bin/ip addr replace ${address}/${
        if lib.hasInfix ":" address then "128" else "32"
      } dev lo";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null --pid-file="
        "--no-resolv --no-hosts --bind-interfaces --listen-address=${address} --local=/a-box.test/"
        "--host-record=cache.a-box.test,${config.networking.primaryIPAddress},${config.networking.primaryIPv6Address}"
      ];
    };
  };
}
