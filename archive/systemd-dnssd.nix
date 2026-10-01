# Module ripped from https://github.com/arianvp/nixos-stuff/blob/04a1527e058843fc8a1a5e2f472cefe522ea38d0/modules/dnssd.nix
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.systemd.dnssd;
  serviceModule =
    {
      name,
      config,
      ...
    }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
        };
        hostname = lib.mkOption {
          type = lib.types.str;
          # Example; See https://www.freedesktop.org/software/systemd/man/latest/systemd.dnssd.html#Name=
        };
        type = lib.mkOption {
          type = lib.types.str;
        };
        subType = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        port = lib.mkOption {
          type = lib.types.int;
        };
        text = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
        };
        path = lib.mkOption {
          type = lib.types.str;
          internal = true;
          readOnly = true;
        };
      };
      config = {
        path = "systemd/dnssd/${name}.dnssd";
        text = ''
          [Service]
          Name=${config.hostname}
          Type=${config.type}
          ${lib.optionalString (config.subType != null) "SubType=${config.subType}"}
          Port=${toString config.port}
        '';
      };
    };
in
{
  options.systemd.dnssd = {
    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule serviceModule);
      default = { };
    };
  };

  config = {
    environment.etc = lib.mapAttrs' (_: v: lib.nameValuePair v.path { inherit (v) text; }) cfg.services;

    services.resolved.enable = lib.mkDefault true;
    systemd.services.systemd-resolved = {
      stopIfChanged = false;
      reloadTriggers = lib.mapAttrsToList (_: v: config.environment.etc.${v.path}.source) cfg.services;
    };
    networking.firewall.allowedUDPPorts = [
      5353 # mDNS
    ];
  };
}
