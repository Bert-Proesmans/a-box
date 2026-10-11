{ mkTest, dhcp, radvd }:
mkTest {
  name = "dualstack";

  # Known failure: step 2 sees no request over IPv6. Same cause as ipv6.nix: no router
  # advertisement reaches the updater within its network wait, so it runs IPv4 only.

  cache.imports = [
    (dhcp { aaaa = true; })
    radvd
  ];

  testScript = ''
    # nginx saw this step's updater requests come from the machine's SLAAC address.
    def served_over_ipv6():
        log = cache.succeed(
            "cut -d ' ' -f 1,4,6,7 /var/log/nginx/cache.log && truncate -s 0 /var/log/nginx/cache.log"
        )
        print(log)
        clients = [line.split()[0] for line in log.splitlines()]
        t.assertTrue(
            any(c.startswith("2001:db8:1:") for c in clients), "no request reached nginx over IPv6"
        )

    with subtest("no system: updater installs generation 1"):
        publish(1)
        start()
        expect(1)
        served_over_ipv6()

    with subtest("generation 2 published: updater installs it on reboot"):
        publish(2)
        machine.reboot()
        expect(2)
        machine.succeed(f"test -e {gens[1]}")
        served_over_ipv6()

    with subtest("nothing new: updater keeps generation 2"):
        machine.reboot()
        machine.wait_for_console_text("a-box: up to date")
        expect(2)
        served_over_ipv6()
  '';
}
