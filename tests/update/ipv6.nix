{ mkTest, radvd, googleDns }:
mkTest {
  name = "ipv6";

  # SLAAC only: no DHCP, no DNS server on the link. The updater falls back to Google Public DNS.
  cache.imports = [
    radvd
    (googleDns { address = "2001:4860:4860::8888"; })
  ];

  testScript = ''
    with subtest("no system: updater installs generation 1"):
        publish(1)
        start()
        machine.wait_for_console_text("a-box: name resolution failed; retrying with Google Public DNS")
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
