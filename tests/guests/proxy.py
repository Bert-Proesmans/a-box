
# ---- proxy -------------------------------------------------------------------------------------

PROXY_CA_CN = "a-box test proxy CA"

SECRETS = {
    "guests/1/key-1": "k1-s3cret-value",
    "guests/1/token-1": "Bearer t0k-s3cret-value",
    "guests/2/key-2": "k2-s3cret-value",
}


def sock(n):
    return f"/run/a-box/guest-{n}/vsock_3128"


def port(n):
    return 3128 + n


def client(url, *headers, n=1, user=None, ca=TEST_CA, timeout=30, stream=False):
    """proxyclient as the guest's own user (or `user`): (exit status, output)."""
    argv = ["runuser", "-u", user or f"a-box-vm-{n}", "--", "proxyclient", sock(n), url, "--ca", ca, "--timeout", str(timeout)]
    argv += [f"--header={h}" for h in headers] + (["--stream"] if stream else [])
    return machine.execute(shlex.join(argv) + " 2>&1")


def fetch(url, *headers, **kwargs):
    """The JSON of one request made through proxy n."""
    status, out = client(url, *headers, **kwargs)
    t.assertEqual(status, 0, out)
    return json.loads(out)


def upstream_log():
    return machine.succeed("cat /tmp/upstream.log")


def journal(n=1):
    return machine.succeed(f"journalctl --no-pager -o cat -u a-box-proxy@{n}.service")


for key, value in SECRETS.items():
    _, n, name = key.split("/")
    machine.succeed(
        f"install -m 0600 /dev/null /persistent/a-box/secrets/guest-{n}/{name}"
        f" && printf %s {shlex.quote(value)} > /persistent/a-box/secrets/guest-{n}/{name}"
    )

# The proxy CA key; the certificate is the one in the guest image.
machine.succeed(f"install -m 0600 {TEST_CA_KEY} /persistent/a-box/secrets/proxy-ca.pem")

machine.succeed("systemctl start a-box-test-proxies.target")
machine.wait_for_unit("a-box-proxy@1.service")
machine.wait_for_unit("a-box-proxy@2.service")

with subtest("proxy and entry are up: sockets, owners, loopback listener"):
    for n in [1, 2]:
        machine.succeed(f"systemctl is-active --quiet a-box-proxy@{n}.service a-box-proxy-entry@{n}.socket")
        t.assertEqual(machine.succeed(f"stat -c '%U %a %F' {sock(n)}").strip(), f"a-box-vm-{n} 600 socket")
        machine.succeed(f"ss -ltnH src 127.0.0.1:{port(n)} | grep -q .")
        pid = machine.succeed(f"systemctl show -p MainPID --value a-box-proxy@{n}.service").strip()
        t.assertEqual(machine.succeed(f"ps -o user= -p {pid}").strip(), f"a-box-proxy-{n}")

with subtest("https through CONNECT is intercepted: certificate of the proxy CA, real body"):
    machine.succeed(": > /tmp/upstream.log")
    r = fetch("https://secure.test/x?q=1")
    t.assertEqual(r["connect"], 200)
    t.assertEqual(r["issuer"], PROXY_CA_CN)
    t.assertEqual(r["subject"], "secure.test")
    t.assertIn("secure.test", r["san"])
    t.assertEqual(r["status"], 200, r)
    t.assertIn("host=secure.test uri=/x?q=1 ", r["body"])
    t.assertRegex(upstream_log(), r"(?m)^443 secure\.test ")

    # The client trusts the CA of the real server only: the proxy's certificate is rejected.
    status, out = client("https://secure.test/", ca=UPSTREAM_CA)
    t.assertNotEqual(status, 0)
    t.assertIn("CERTIFICATE_VERIFY_FAILED", out)

with subtest("plain http in absolute form is forwarded with path and query"):
    r = fetch("http://ok.test/p?q=1")
    t.assertEqual(r["status"], 200, r)
    t.assertIn("host=ok.test uri=/p?q=1 ", r["body"])
    t.assertRegex(upstream_log(), r"(?m)^80 ok\.test ")

with subtest("hosts off the allowlist are blocked, with a clear answer and a log line"):
    machine.succeed(": > /tmp/upstream.log")

    r = fetch("https://other.test/")
    t.assertEqual(r["connect"], 403)

    r = fetch("http://other.test/secret/path?token=hunter2")
    t.assertEqual(r["status"], 403)
    t.assertIn("other.test:80 is blocked: not on this guest's allowlist", r["body"])

    t.assertEqual(upstream_log(), "")
    log = journal()
    t.assertRegex(log, r"guest=1 method=CONNECT host=other\.test port=443 path=- status=403 decision=blocked credential_injected=false")
    t.assertRegex(log, r"guest=1 method=GET host=other\.test port=80 path=/secret/path status=403 decision=blocked credential_injected=false")
    t.assertNotIn("hunter2", log)

with subtest("ports: an entry without one covers 80 and 443, an entry with one only that"):
    r = fetch("https://port.test:8443/")
    t.assertEqual((r["connect"], r["status"]), (200, 200), r)
    t.assertIn("port=8443", r["body"])
    t.assertEqual(fetch("https://port.test/")["connect"], 403)

    t.assertEqual(fetch("http://ok.test:8080/")["status"], 200)
    t.assertEqual(fetch("http://ok.test:9999/")["status"], 403)
    t.assertEqual(fetch("https://ok.test:8080/")["connect"], 200)

with subtest("wildcard: below the name, not the name itself"):
    t.assertEqual(fetch("http://sub.wild.test/")["status"], 200)
    t.assertEqual(fetch("http://wild.test/")["status"], 403)

with subtest("IP addresses are blocked, in every spelling"):
    machine.succeed(": > /tmp/upstream.log")
    for host in ["203.0.113.10", "127.1", "0x7f.1", "2130706433", "[::1]"]:
        t.assertEqual(fetch(f"http://{host}/")["status"], 403, host)
        t.assertEqual(fetch(f"https://{host}/")["connect"], 403, host)
    t.assertEqual(upstream_log(), "")

with subtest("the Host header cannot name another destination"):
    machine.succeed(": > /tmp/upstream.log")
    r = fetch("http://ok.test/", "Host: other.test")
    t.assertEqual(r["status"], 403)
    t.assertIn("Host header differs", r["body"])
    r = fetch("https://secure.test/", "Host: other.test")
    t.assertEqual(r["status"], 403)
    t.assertEqual(upstream_log(), "")

with subtest("credentials: the guest's copy is replaced, only for the entry that injects"):
    forged = ["X-Api-Key: forged", "authorization: forged", "Proxy-Authorization: forged"]

    r = fetch("http://ok.test/", *forged)
    t.assertIn(f"auth=[forged] key=[{SECRETS['guests/1/key-1']}] proxy-auth=[]", r["body"])

    r = fetch("https://secure.test/", *forged)
    t.assertIn(f"auth=[{SECRETS['guests/1/token-1']}] key=[forged] proxy-auth=[]", r["body"])

    r = fetch("http://sub.wild.test/", *forged)
    t.assertIn("auth=[forged] key=[forged] proxy-auth=[]", r["body"])

    t.assertIn(f"key=[{SECRETS['guests/2/key-2']}]", fetch("http://ok.test/", n=2)["body"])

    log = journal()
    t.assertRegex(log, r"host=ok\.test port=80 path=/ status=200 decision=allowed credential_injected=true")
    t.assertRegex(log, r"host=sub\.wild\.test port=80 path=/ status=200 decision=allowed credential_injected=false")

with subtest("servers are verified: wrong name and unknown CA fail with 502"):
    machine.succeed(": > /tmp/upstream.log")
    for name in ["wrong.test", "rogue.test"]:
        r = fetch(f"https://{name}/")
        t.assertEqual((r["connect"], r["status"]), (200, 502), (name, r))
    t.assertEqual(upstream_log(), "")
    t.assertRegex(journal(), r"host=rogue\.test port=443 path=/ status=502 decision=allowed")

with subtest("event streams are passed on as they come"):
    r = fetch("https://secure.test/sse", stream=True)
    t.assertEqual(r["status"], 200, r)
    times = [at for at, _ in r["chunks"]]
    t.assertLess(times[0], 1.5, r["chunks"])
    t.assertGreaterEqual(times[-1], 1.8, r["chunks"])
    t.assertIn("data: 0", r["body"])
    t.assertIn("data: 2", r["body"])

with subtest("SSRF: allowed names that resolve to this host or to private ranges fail at once"):
    # Control: every one of them answers when asked from outside the proxy.
    for name in ["loop.test", "lan.test", "meta.test", "priv.test"]:
        t.assertIn(f"host={name} ", machine.succeed(f"curl -sf --max-time 10 http://{name}/"))
    machine.succeed(": > /tmp/upstream.log; : > /tmp/local.log")

    for name in ["loop.test", "lan.test", "meta.test", "priv.test"]:
        r = fetch(f"http://{name}/", timeout=10)
        t.assertEqual(r["status"], 502, (name, r))
        r = fetch(f"https://{name}/", timeout=10)
        t.assertEqual((r["connect"], r["status"]), (200, 502), (name, r))

    t.assertEqual(upstream_log(), "")
    t.assertEqual(machine.succeed("cat /tmp/local.log"), "")

with subtest("instances are separate: sockets, policy, secrets"):
    t.assertEqual(fetch("https://secure.test/", n=2)["connect"], 403)

    for user in ["a-box-vm-1", "a-box-proxy-1", "a-box-entry-1", "a-box-log-1", "nobody"]:
        status, out = client("http://ok.test/", n=2, user=user)
        t.assertNotEqual(status, 0, f"{user} reached instance 2: {out}")
        t.assertIn("Permission denied", out)
    status, out = client("http://ok.test/", n=1, user="a-box-vm-2")
    t.assertNotEqual(status, 0, out)
    t.assertIn("Permission denied", out)

    # The loopback ports are for the entry unit of the instance only, whoever else asks.
    for n in [1, 2]:
        other = 3 - n
        for user in [f"a-box-vm-{n}", f"a-box-proxy-{n}", f"a-box-entry-{other}", "nobody", "root"]:
            machine.fail(f"runuser -u {user} -- curl -sf --max-time 5 -x http://127.0.0.1:{port(n)} http://ok.test/")
        machine.succeed(f"runuser -u a-box-entry-{n} -- curl -sf --max-time 10 -x http://127.0.0.1:{port(n)} http://ok.test/")

with subtest("secrets stay out of the journal; the credential files stay private"):
    for value in SECRETS.values():
        machine.fail(f"journalctl --no-pager -a | grep -F {shlex.quote(value)}")
    # No query string in any access log line.
    machine.fail("journalctl --no-pager -u a-box-proxy@1.service | grep -F 'q=1'")
    t.assertEqual(
        machine.succeed("stat -c '%U %a' /persistent/a-box/secrets/guest-1/key-1 /persistent/a-box/secrets/proxy-ca.pem").split("\n")[:2],
        ["root 600", "root 600"],
    )
    machine.fail("runuser -u a-box-proxy-1 -- cat /persistent/a-box/secrets/guest-1/key-1")

with subtest("start refuses a CA key that is not the image's, and a bad credential"):
    good_key = machine.succeed("cat /persistent/a-box/secrets/proxy-ca.pem")
    machine.succeed("openssl genpkey -algorithm RSA -out /persistent/a-box/secrets/proxy-ca.pem")
    machine.fail("systemctl restart a-box-proxy@2.service")
    t.assertIn("is not the key of the CA certificate", journal(2))
    machine.succeed(f"printf %s {shlex.quote(good_key)} > /persistent/a-box/secrets/proxy-ca.pem")

    machine.succeed("printf 'a\\nb' > /persistent/a-box/secrets/guest-2/key-2")
    machine.fail("systemctl restart a-box-proxy@2.service")
    t.assertIn("credential key-2", journal(2))
    machine.succeed("rm /persistent/a-box/secrets/guest-2/key-2")
    machine.fail("systemctl restart a-box-proxy@2.service")

    machine.succeed(f"printf %s {shlex.quote(SECRETS['guests/2/key-2'])} > /persistent/a-box/secrets/guest-2/key-2")
    machine.succeed("systemctl reset-failed; systemctl start a-box-test-proxies.target")
    machine.wait_for_unit("a-box-proxy@2.service")
    t.assertIn(f"key=[{SECRETS['guests/2/key-2']}]", fetch("http://ok.test/", n=2)["body"])

with subtest("stopping the proxy takes the entry socket and its forwarder with it"):
    machine.succeed("systemctl stop a-box-test-proxies.target a-box-proxy@1.service")
    for unit in ["a-box-proxy@1.service", "a-box-proxy-entry@1.socket", "a-box-proxy-entry@1.service"]:
        machine.fail(f"systemctl is-active --quiet {unit}")
    machine.fail(f"test -e {sock(1)}")
    machine.fail(f"ss -ltnH src 127.0.0.1:{port(1)} | grep -q .")
    machine.succeed("systemctl start a-box-test-proxies.target")
    machine.wait_for_unit("a-box-proxy@1.service")

with subtest("a guest does not boot without a working proxy; with one it reaches it over vsock"):
    LOG1 = "/persistent/a-box/logs/guest-1/current"
    machine.succeed("test -w /dev/kvm")
    machine.succeed("systemctl stop a-box-test-proxies.target a-box-proxy@1.service a-box-proxy@2.service")

    # A CA key that does not fit the image: the proxy fails, the guest never starts.
    good_key = machine.succeed("cat /persistent/a-box/secrets/proxy-ca.pem")
    machine.succeed("openssl genpkey -algorithm RSA -out /persistent/a-box/secrets/proxy-ca.pem")
    machine.fail("systemctl start a-box-guest@1.service")
    machine.fail("pgrep firecracker")
    machine.succeed(f"printf %s {shlex.quote(good_key)} > /persistent/a-box/secrets/proxy-ca.pem")
    machine.succeed("systemctl reset-failed")

    machine.succeed("systemctl start a-box-guest@1.service")
    machine.succeed("systemctl is-active --quiet a-box-proxy@1.service a-box-proxy-entry@1.socket a-box-log@1.service")
    machine.wait_until_succeeds("pgrep firecracker")
    t.assertEqual(machine.succeed("ps -o user= -C firecracker").strip(), "a-box-vm-1")

    # The guest's wget goes loopback -> socat -> vsock -> Firecracker -> entry socket -> mitmproxy.
    machine.succeed(": > /tmp/upstream.log")
    machine.wait_until_succeeds(f"grep -q 'guest requests done' {LOG1}")
    console = machine.succeed(f"cat {LOG1}")
    t.assertIn(f"host=ok.test uri=/via-guest auth=[] key=[{SECRETS['guests/1/key-1']}]", console)
    t.assertRegex(journal(), r"host=ok\.test port=80 path=/via-guest status=200 decision=allowed credential_injected=true")

    machine.succeed("systemctl stop a-box-guest@1.service")
    # The socket is stopped as unneeded once the proxy has gone: a step later.
    for unit in ["a-box-guest@1.service", "a-box-proxy@1.service", "a-box-proxy-entry@1.socket", "a-box-log@1.service"]:
        machine.wait_until_fails(f"systemctl is-active --quiet {unit}")
    machine.wait_until_fails(f"test -e {sock(1)}")
    machine.succeed("systemctl start a-box-test-proxies.target")
    machine.wait_for_unit("a-box-proxy@1.service")

with subtest("instances beyond a-box.guests.max do not start"):
    for unit in ["a-box-proxy@3.service", "a-box-proxy-entry@3.socket", "a-box-guest@3.service"]:
        machine.fail(f"systemctl start {unit}")
        machine.fail(f"systemctl is-active --quiet {unit}")
    machine.fail("test -e /run/a-box/guest-3")

with subtest("IPAddressDeny alone keeps the proxy off private ranges (nftables removed)"):
    # The backstop: without the table the connect is dropped silently instead of refused.
    machine.succeed("nft delete table inet a-box-proxy")
    machine.succeed(": > /tmp/upstream.log")
    status, out = client("http://priv.test/", timeout=15)
    t.assertTrue(status != 0 or '"status": 200' not in out, out)
    t.assertEqual(upstream_log(), "")
