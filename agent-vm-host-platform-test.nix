# Boot-time verification for agent-vm-host-platform.nix's memory-posture
# guard (chunk 4, step 4.1 - see docs/agent-vm-host/02-host-platform-todo.md).
# Confirms the preflight check reports both swap and KSM healthy on a normal
# boot, and fails loudly with a distinct message when either condition is
# forced true. Scoped to the memory-posture checks only - KVM and cgroup v2
# are chunks 2/3's concern, not asserted on here, and the test VM has no
# nested KVM of its own to exercise that check meaningfully.
#
# useNixStoreImage/sharedDirectories/kernel_irqchip below work around sandbox
# issues seen developing this in a nested-KVM environment (see README.md's
# entry for this file) - none are required by the check itself.
#
# Run with: nix-build llm-host.nix -A platformMemoryPostureTest
{ lib, hostPkgs }:
lib.nixos.runTest {
  inherit hostPkgs;
  name = "agent-vm-host-platform-memory-posture";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ./agent-vm-host-platform.nix ];
      virtualisation.memorySize = 768;
      # Store as a disk image, not a virtiofs share of the host's /nix/store -
      # this sandbox's virtiofsd can't open file handles for the shared root
      # ("Operation not permitted"), which hangs the guest before it reaches
      # multi-user.target.
      virtualisation.useNixStoreImage = true;
      # The framework's remaining virtiofs shares (xchg/shared, used only by
      # copy_from_host/copy_to_host/screenshot helpers this test never calls)
      # are `neededForBoot`, so mounting them blocks stage-1 the same way the
      # store share did. Drop them - nothing here needs them.
      virtualisation.sharedDirectories = lib.mkForce { };
      # With virtiofs out of the way, boot still wedges right after ACPI GPE
      # setup (\_SB_.GSIE/GSIF). Confirmed cause: this host's kvm_intel has
      # enable_apicv=N (Hyper-V's nested-virt doesn't advertise the VMX
      # secondary controls APIC virtualization needs - verified this isn't a
      # policy tied to enlightened_vmcs, since forcing enable_apicv=1 as a
      # modprobe param still comes back N). kernel_irqchip=off would remove
      # the dependency entirely but this KVM instance refuses it outright
      # ("KVM does not support userspace APIC"); split is the closest
      # available option, though it still doesn't get past the same point.
      virtualisation.qemu.options = [ "-machine kernel_irqchip=split" ];
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("stock boot: both memory-posture conditions healthy"):
        status, out = machine.execute("agent-vm-host-preflight")
        assert "OK: no swap device active" in out, out
        assert "OK: KSM disabled" in out, out

    with subtest("forced swap device: distinct, loud failure"):
        machine.succeed(
            "dd if=/dev/zero of=/root/swapfile bs=1M count=64",
            "chmod 600 /root/swapfile",
            "mkswap /root/swapfile",
            "swapon /root/swapfile",
        )
        status, out = machine.execute("agent-vm-host-preflight")
        assert status != 0, out
        assert "FAIL: a swap device is active" in out, out
        machine.succeed("swapoff /root/swapfile")

    with subtest("forced KSM: distinct, loud failure"):
        machine.succeed("echo 1 > /sys/kernel/mm/ksm/run")
        status, out = machine.execute("agent-vm-host-preflight")
        assert status != 0, out
        assert "FAIL: KSM is running" in out, out
        machine.succeed("echo 0 > /sys/kernel/mm/ksm/run")
  '';
}
