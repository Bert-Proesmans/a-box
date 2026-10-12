{ sources, ... }:
{
  imports = [ (sources.preservation + "/module.nix") ];

  preservation = {
    enable = true;

    preserveAt."/persistent".files = [
      {
        file = "/etc/machine-id";
        inInitrd = true;
        how = "symlink";
        configureParent = true;
        # D-Bus breaks on a dangling symlink.
        createLinkTarget = true;
      }
      {
        file = "/etc/ssh/ssh_host_ed25519_key";
        how = "symlink";
        configureParent = true;
      }
      {
        file = "/etc/ssh/ssh_host_rsa_key";
        how = "symlink";
        configureParent = true;
      }
    ];
  };

  # systemd treats exactly "uninitialized\n" as first boot; an empty or missing file would not.
  boot.initrd.systemd.tmpfiles.settings.preservation."/sysroot/persistent/etc/machine-id".f.argument =
    "uninitialized\n";

  # /etc/machine-id is a symlink into /persistent: commit there instead of bind-mounting over /etc.
  systemd.services.systemd-machine-id-commit = {
    unitConfig.ConditionPathIsMountPoint = [
      ""
      "/persistent/etc/machine-id"
    ];
    serviceConfig.ExecStart = [
      ""
      "systemd-machine-id-setup --commit --root /persistent"
    ];
  };
}
