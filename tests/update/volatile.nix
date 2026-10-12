{ mkTest, dhcp }:
mkTest {
  name = "volatile";

  cache.imports = [ (dhcp { }) ];

  testScript = ''
    # What must outlive a reboot: the machine id and the ssh host key, kept in /persistent.
    def identity():
        return machine.succeed(
            "cat /etc/machine-id; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key"
        )

    with subtest("first boot: state written to / and to /persistent"):
        publish(1)
        start()
        expect(1)
        machine.succeed(
            "echo root > /root/marker",
            "echo persistent > /persistent/marker",
            "sync",
        )
        before = identity()

    with subtest("reboot: / is rebuilt, /persistent and the store stay"):
        machine.reboot()
        # The store still holds the generation: nothing is fetched.
        machine.wait_for_console_text("a-box: up to date")
        expect(1)
        machine.fail("test -e /root/marker")
        t.assertEqual(machine.succeed("cat /persistent/marker").strip(), "persistent")
        t.assertEqual(identity(), before)
        machine.succeed(f"test -e {gens[1]}")
  '';
}
