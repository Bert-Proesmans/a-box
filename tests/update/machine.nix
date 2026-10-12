# The main system the updater installs. Generations differ only in /etc/a-box-generation.
{ vm }:
{
  config,
  lib,
  extendModules,
  modulesPath,
  ...
}:
{
  imports = [
    ../../modules/main.nix
    ../../configuration.nix
    # Smaller closure: the build host keeps VM disks in RAM-backed temp space.
    (modulesPath + "/profiles/minimal.nix")
    vm
  ];

  options.a-box-test.generation = lib.mkOption {
    type = lib.types.int;
    default = 1;
  };

  config = {
    # qemu-vm replaces the system's fileSystems with `virtualisation.fileSystems`, unless that is
    # empty: the generations keep the main system's mounts (zram root, /nix, /persistent, /boot).
    virtualisation.fileSystems = lib.mkForce { };

    environment.etc."a-box-generation".text = toString config.a-box-test.generation;
    system.disableInstallerTools = true;

    system.build.a-box-test-generation =
      n:
      (extendModules {
        modules = [ { a-box-test.generation = n; } ];
      }).config.system.build.toplevel;
  };
}
