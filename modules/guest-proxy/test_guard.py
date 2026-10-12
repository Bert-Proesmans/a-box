"""Unit tests of guard.py, run at build time (see default.nix) against the mitmproxy it runs in."""

import json
import os
import tempfile
import unittest

from mitmproxy import http
from mitmproxy.test import tflow, tutils

import guard

DOMAINS = {
    "api.example.com": {"inject": {"X-Api-Key": "key"}},
    "*.wild.test": {},
    ".dot.test": {},
    "plain.test": {},
    "port.test:8443": {},
    "mixed.test": {"inject": {"Authorization": "outer"}},
    "*.mixed.test": {"inject": {"Authorization": "inner"}},
}

SECRETS = {"key": "s3cret-value", "outer": "outer-secret", "inner": "inner-secret"}


def make_flow(host, port, headers=(), path="/p?q=1", method="GET", host_header=None):
    request = tutils.treq(
        host=host,
        port=port,
        method=method.encode(),
        path=path.encode(),
        headers=http.Headers(
            [(b"host", (host_header or host).encode())] + [(k.encode(), v.encode()) for k, v in headers]
        ),
        content=b"",
    )
    return tflow.tflow(req=request)


class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.policy = guard.Policy(DOMAINS)

    def key(self, host, port=443):
        entry = self.policy.lookup(host, port)
        return entry.key if entry else None

    def test_exact_and_default_ports(self):
        self.assertEqual(self.key("plain.test"), "plain.test")
        self.assertEqual(self.key("plain.test", 80), "plain.test")
        self.assertIsNone(self.key("plain.test", 8443))
        self.assertIsNone(self.key("other.test"))

    def test_case_and_trailing_dot(self):
        self.assertEqual(self.key("PLAIN.test."), "plain.test")

    def test_wildcards(self):
        self.assertEqual(self.key("a.wild.test"), "*.wild.test")
        self.assertEqual(self.key("a.b.wild.test"), "*.wild.test")
        self.assertIsNone(self.key("wild.test"))
        self.assertIsNone(self.key("notwild.test"))
        self.assertEqual(self.key("dot.test"), ".dot.test")
        self.assertEqual(self.key("a.dot.test"), ".dot.test")

    def test_port_entry_covers_only_its_port(self):
        self.assertEqual(self.key("port.test", 8443), "port.test:8443")
        self.assertIsNone(self.key("port.test", 443))

    def test_most_specific_entry_wins(self):
        self.assertEqual(self.key("mixed.test"), "mixed.test")
        self.assertEqual(self.key("a.mixed.test"), "*.mixed.test")

    def test_ip_literals_are_never_allowed(self):
        policy = guard.Policy({"*.1.1": {}, ".1": {}})
        for host in ["1.1.1.1", "[::1]", "::1", "127.0.0.1", "0x7f.1"]:
            self.assertIsNone(policy.lookup(host, 80), host)

    def test_bad_entries(self):
        for key in ["", "UPPER.test", "a b.test", "a.test:99999", "a.test:0", "https://a.test", "a.test/x"]:
            with self.assertRaises(ValueError, msg=key):
                guard.Policy({key: {}})


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.guard = guard.Guard("1", guard.Policy(DOMAINS), SECRETS)

    def request(self, flow):
        self.guard.request(flow)
        return flow

    def test_allowed_request_is_untouched(self):
        flow = self.request(make_flow("plain.test", 80, [("X-Api-Key", "mine")]))
        self.assertIsNone(flow.response)
        self.assertEqual(flow.request.headers["X-Api-Key"], "mine")
        self.assertNotIn("credential_injected", flow.metadata)

    def test_injection_replaces_every_guest_copy(self):
        flow = self.request(
            make_flow("api.example.com", 443, [("x-api-key", "forged"), ("X-API-KEY", "forged2")])
        )
        self.assertIsNone(flow.response)
        self.assertEqual(flow.request.headers.get_all("X-Api-Key"), ["s3cret-value"])
        self.assertTrue(flow.metadata["credential_injected"])

    def test_injection_is_per_destination(self):
        flow = self.request(make_flow("a.mixed.test", 443))
        self.assertEqual(flow.request.headers["Authorization"], "inner-secret")
        flow = self.request(make_flow("mixed.test", 443))
        self.assertEqual(flow.request.headers["Authorization"], "outer-secret")

    def test_blocked_request(self):
        flow = self.request(make_flow("other.test", 443, [("X-Api-Key", "x")]))
        self.assertEqual(flow.response.status_code, 403)
        self.assertIn(b"other.test:443", flow.response.content)
        self.assertEqual(flow.metadata["a_box_blocked"], "not on this guest's allowlist")
        self.assertNotIn("credential_injected", flow.metadata)

    def test_host_header_must_match_the_destination(self):
        flow = self.request(make_flow("api.example.com", 443, host_header="plain.test"))
        self.assertEqual(flow.response.status_code, 403)
        self.assertNotIn("X-Api-Key", flow.request.headers)

        flow = self.request(make_flow("api.example.com", 443, host_header="API.example.com"))
        self.assertIsNone(flow.response)

    def test_proxy_headers_are_dropped(self):
        flow = self.request(
            make_flow("plain.test", 80, [("Proxy-Authorization", "x"), ("Proxy-Connection", "keep-alive")])
        )
        self.assertNotIn("Proxy-Authorization", flow.request.headers)
        self.assertNotIn("Proxy-Connection", flow.request.headers)

    def test_event_streams_are_streamed(self):
        for content_type, streamed in [("text/event-stream; charset=utf-8", True), ("application/json", False)]:
            flow = make_flow("plain.test", 80)
            flow.response = http.Response.make(200, b"", {"Content-Type": content_type})
            self.guard.responseheaders(flow)
            self.assertEqual(flow.response.stream, streamed, content_type)

    def test_connect(self):
        flow = make_flow("plain.test", 443, method="CONNECT")
        self.guard.http_connect(flow)
        self.assertIsNone(flow.response)

        for host, port in [("other.test", 443), ("plain.test", 22), ("127.0.0.1", 443)]:
            flow = make_flow(host, port, method="CONNECT")
            self.guard.http_connect(flow)
            self.assertEqual(flow.response.status_code, 403, (host, port))

    def test_a_failing_check_blocks(self):
        def boom(flow):
            raise RuntimeError("boom")

        flow = make_flow("plain.test", 80)
        with self.assertLogs("a_box_proxy", "ERROR"):
            self.guard.guarded(flow, boom)
        self.assertEqual(flow.response.status_code, 403)

    def test_access_log_has_no_query_and_no_secret(self):
        flow = make_flow("api.example.com", 443, path="/v1/x?token=hunter2")
        self.request(flow)
        flow.response = http.Response.make(200)
        with self.assertLogs("a_box_proxy", "INFO") as logs:
            self.guard.response(flow)
            self.guard.response(flow)  # logged once
        self.assertEqual(
            logs.output,
            [
                "INFO:a_box_proxy:guest=1 method=GET host=api.example.com port=443 path=/v1/x "
                "status=200 decision=allowed credential_injected=true"
            ],
        )

        blocked = make_flow("other.test", 443, path="/a\x01b?x=1")
        with self.assertLogs("a_box_proxy", "INFO") as logs:
            self.request(blocked)
        self.assertEqual(len(logs.output), 1)
        self.assertIn("path=/a?b status=403 decision=blocked credential_injected=false", logs.output[0])
        for line in logs.output:
            self.assertNotIn("s3cret", line)


class ConfigTest(unittest.TestCase):
    def test_secrets_are_read_and_checked(self):
        policy = guard.Policy(DOMAINS)
        with tempfile.TemporaryDirectory() as d:
            for name in SECRETS:
                with open(os.path.join(d, name), "w") as f:
                    f.write(SECRETS[name] + "\n")
            self.assertEqual(guard.read_secrets(policy, d), SECRETS)

            for bad in ["", "\n", "a\x00b", "a\nb", "tab\there", "ünï"]:
                with open(os.path.join(d, "key"), "w", encoding="utf-8") as f:
                    f.write(bad)
                with self.assertRaises(ValueError, msg=repr(bad)):
                    guard.read_secrets(policy, d)

    def test_missing_credential_fails(self):
        with tempfile.TemporaryDirectory() as d, self.assertRaises(FileNotFoundError):
            guard.read_secrets(guard.Policy(DOMAINS), d)

    def test_from_environment(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "policy.json"), "w") as f:
                json.dump({"instance": "2", "domains": {"plain.test": {}}}, f)
            os.environ["A_BOX_POLICY"] = os.path.join(d, "policy.json")
            os.environ["CREDENTIALS_DIRECTORY"] = d
            g = guard.from_environment()
        self.assertEqual(g.instance, "2")
        self.assertIsNotNone(g.policy.lookup("plain.test", 80))


if __name__ == "__main__":
    unittest.main()
