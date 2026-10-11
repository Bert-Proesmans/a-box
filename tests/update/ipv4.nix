{ mkTest, dhcp }:
mkTest {
  name = "ipv4";

  cache.imports = [ (dhcp { }) ];

  testScript = ''
    with subtest("no system: updater installs generation 1"):
        publish(1)
        start()
        expect(1)

    with subtest("generation 2 published: updater installs it on reboot"):
        publish(2)
        machine.reboot()
        expect(2)
        machine.succeed(f"test -e {gens[1]}")

    with subtest("nothing new: updater keeps generation 2"):
        machine.reboot()
        machine.wait_for_console_text("a-box: up to date")
        expect(2)
  '';
}
