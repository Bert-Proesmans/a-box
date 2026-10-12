
# ---- guest -------------------------------------------------------------------------------------

LOG1 = "/persistent/a-box/logs/guest-1/current"

machine.succeed("test -w /dev/kvm")

with subtest("guest boots; its console is recorded"):
    machine.succeed("systemctl start a-box-guest@1.service")
    machine.wait_until_succeeds(f"grep -q 'a-box guest: echo server ready' {LOG1}", )

    # The guest unit pulled in its proxy and logger.
    machine.succeed("systemctl is-active --quiet a-box-proxy@1.service a-box-log@1.service")
    t.assertEqual(machine.succeed("ps -o user= -C firecracker").strip(), "a-box-vm-1")
    machine.succeed("test -S /run/a-box/guest-1/vsock_3128 -a -S /run/a-box/guest-1/vsock")

with subtest("the guest reaches the proxy over vsock"):
    machine.wait_until_succeeds(f"grep -q 'guest requests done' {LOG1}")
    t.assertIn(
        "proxy-stub saw: GET http://ok.test/via-guest HTTP/1.1", machine.succeed(f"cat {LOG1}")
    )

with subtest("stopping the guest tears down proxy, logger and sockets"):
    machine.succeed("systemctl stop a-box-guest@1.service")
    for unit in ["a-box-guest@1", "a-box-proxy@1", "a-box-log@1"]:
        machine.fail(f"systemctl is-active --quiet {unit}.service")
    t.assertEqual(machine.succeed("ls -A /run/a-box/guest-1").split(), [])
    machine.fail("pgrep firecracker")
    # The recorded console outlives the guest.
    machine.succeed(f"grep -q 'guest requests done' {LOG1}")
