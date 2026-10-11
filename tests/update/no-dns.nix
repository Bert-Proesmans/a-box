{ mkTest, dhcp, googleDns }:
mkTest {
  name = "no-dns";

  cache.imports = [
    (dhcp { dns = false; })
    (googleDns { address = "8.8.8.8"; })
  ];

  testScript = ''
    with subtest("no system: updater installs generation 1"):
        publish(1)
        start()
        machine.wait_for_console_text("retrying with Google Public DNS")
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
