{ mkTest, dhcp }:
mkTest {
  name = "offline";

  cache.imports = [ (dhcp { }) ];

  # block() unplugs virtio-net-pci.1, the NIC on the test vlan; eth0 (virtio-net-pci.0) sits on an
  # empty hub. The link state belongs to the QEMU process and survives reboot().
  testScript = ''
    with subtest("no system: updater installs generation 1"):
        publish(1)
        start()
        machine.block()
        machine.wait_for_console_text("a-box: no system installed; retrying in 30s")
        machine.unblock()
        expect(1)

    with subtest("generation 2 published: updater installs it on reboot"):
        publish(2)
        machine.block()
        machine.reboot()
        machine.wait_for_console_text("a-box: no DHCP lease")
        expect(1)
        machine.unblock()
        machine.reboot()
        expect(2)
        machine.succeed(f"test -e {gens[1]}")

    with subtest("nothing new: updater keeps generation 2"):
        machine.block()
        machine.reboot()
        machine.wait_for_console_text("a-box: no DHCP lease")
        expect(2)
  '';
}
