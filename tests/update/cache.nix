{ binaryCache }:
{
  networking.firewall.enable = false;

  systemd.tmpfiles.rules = [ "d /srv/www/a-box 0755 root root -" ];
  services.nginx = {
    enable = true;
    virtualHosts.cache = {
      default = true;
      root = "/srv/www";
      locations."/nix-cache/".alias = "${binaryCache}/nix-cache/";
      extraConfig = "access_log /var/log/nginx/cache.log;";
    };
  };
}
