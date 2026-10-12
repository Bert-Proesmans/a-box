{ lib, modulesPath, ... }:
{
  # qemu-vm imports this profile, whose virtio initrd drivers would hide missing ones in main.nix.
  disabledModules = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  virtualisation = {
    directBoot.enable = false;
    mountHostNixStore = false;
    useEFIBoot = true;
    # Target hardware floor: every scenario must pass with 1 GiB.
    memorySize = 1024;

    # eth0 on an empty hub. QEMU's user network would hand the updater a DHCP lease with its
    # own DNS server, and IPv6 router advertisements.
    qemu.networkingOptions = lib.mkForce [
      "-net nic,netdev=user.0,model=virtio"
      "-netdev hubport,id=user.0,hubid=0"
    ];
  };
}
