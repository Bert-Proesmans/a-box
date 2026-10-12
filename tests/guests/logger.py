
# ---- logger ------------------------------------------------------------------------------------

LOGDIR = "/persistent/a-box/logs/guest-2"

def feed(text):
    machine.succeed(
        "printf %s {} > /proc/$(systemctl show -p MainPID --value test-console-feed)/fd/1".format(
            shlex.quote(text)
        )
    )

def current():
    return machine.succeed(f"cat {LOGDIR}/current")

machine.succeed("systemctl start a-box-test-logger.target")
machine.wait_for_unit("a-box-log@2.service")
machine.succeed("systemctl start test-console-feed.service")

with subtest("console lines are timestamped (UTC) and sanitised"):
    feed("first line\n" "carriage\r\n" "esc \x1b[31mred\x1b[0m\n")
    machine.wait_until_succeeds(f"grep -q 'esc' {LOGDIR}/current")
    lines = current().splitlines()
    stamp = r"^\d{4}-\d\d-\d\d_\d\d:\d\d:\d\d\.\d+ "
    t.assertEqual(len(lines), 3, lines)
    t.assertRegex(lines[0], stamp + "first line$")
    t.assertRegex(lines[1], stamp + "carriage_$")
    t.assertRegex(lines[2], stamp + r"esc _\[31mred_\[0m$")
    t.assertEqual(
        machine.succeed("date -u +%F").strip(),
        lines[0].split("_")[0],
    )

with subtest("files belong to the logger; the guest's users cannot touch them"):
    # svlogd creates its files 0644; the 0700 directory keeps everyone else out.
    t.assertEqual(
        machine.succeed(f"stat -c '%U %a' {LOGDIR} {LOGDIR}/current").split("\n")[:2],
        ["a-box-log-2 700", "a-box-log-2 644"],
    )
    for user in ["a-box-vm-2", "a-box-proxy-2", "a-box-log-1", "nobody"]:
        machine.fail(f"runuser -u {user} -- sh -c 'echo x >> {LOGDIR}/current'")
        machine.fail(f"runuser -u {user} -- cat {LOGDIR}/current")
        machine.fail(f"runuser -u {user} -- rm -f {LOGDIR}/current")
    machine.succeed("cat /persistent/a-box/logs/guest-2/config | grep -x s4096")

with subtest("rotation at the configured size, oldest files dropped"):
    # 100-byte lines: about 30 per 4096-byte file, 300 lines is about 10 files.
    for batch in range(10):
        feed("".join(f"{batch:02}{i:03} " + "x" * 90 + "\n" for i in range(30)))
    machine.wait_until_succeeds(f"grep -q '^[^ ]* 09029 ' {LOGDIR}/current")

    files = machine.succeed(f"ls {LOGDIR}").split()
    old = sorted(f for f in files if f.startswith("@"))
    t.assertEqual(len(old), 2, files)
    for f in old:
        size = int(machine.succeed(f"stat -c %s {LOGDIR}/{f}"))
        # svlogd closes a file once the next line could pass the limit: a bit below it.
        t.assertTrue(2048 < size <= 4096, (f, size))
    t.assertLessEqual(int(machine.succeed(f"stat -c %s {LOGDIR}/current")), 4096)

    # Every file holds whole, timestamped lines.
    machine.fail(f"cat {LOGDIR}/@* {LOGDIR}/current | grep -v -E '^[0-9-]+_[0-9:.]+ '")

with subtest("end of the console flushes the last line and ends the logger"):
    feed("last words\n")
    machine.succeed("systemctl stop test-console-feed.service")
    machine.wait_until_fails("systemctl is-active --quiet a-box-log@2.service")
    t.assertIn("last words", current())
    machine.fail("systemctl is-failed --quiet a-box-log@2.service")
    machine.succeed("systemctl stop a-box-test-logger.target")
