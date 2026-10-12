"""Allowlist, credential injection and access log of one guest's proxy, as a mitmproxy addon (see addon.py).

Environment:
  A_BOX_POLICY          JSON file {"instance": "1", "domains": {"<entry>": {"inject": {"<header>": "<credential>"}}}}
  CREDENTIALS_DIRECTORY systemd credentials; <credential> is a file in it holding the header value

Entry syntax: `host`, `*.host` (below it), `.host` (it and below), each optionally `:port`. Without a
port an entry covers 80 and 443. When several entries match, the most specific one decides:
exact over wildcard, longer suffix over shorter, with a port over without.

Everything not matched is answered 403 and logged. Any error in a hook blocks the flow.
"""

import json
import logging
import os
import re
import socket
import sys
from dataclasses import dataclass, field

from mitmproxy import http

DEFAULT_PORTS = frozenset({80, 443})

ENTRY = re.compile(r"(?P<wild>\*\.|\.)?(?P<host>[a-z0-9_]([a-z0-9._-]*[a-z0-9_])?)(:(?P<port>[0-9]{1,5}))?")
UNPRINTABLE = re.compile(r"[^\x21-\x7e]")

# Headers a client sends to the proxy itself; they must not travel on.
HOP_BY_HOP = ("Proxy-Authorization", "Proxy-Connection")

log = logging.getLogger("a_box_proxy")


@dataclass(frozen=True)
class Entry:
    key: str
    host: str
    wildcard: str  # "", "*." (below the host) or "." (the host and below)
    port: int | None
    inject: dict[str, str] = field(default_factory=dict, hash=False)

    def matches(self, host: str, port: int) -> bool:
        if port not in ({self.port} if self.port is not None else DEFAULT_PORTS):
            return False
        if host == self.host:
            return self.wildcard != "*."
        return self.wildcard != "" and host.endswith("." + self.host)

    @property
    def rank(self) -> tuple[bool, int, bool]:
        return (self.wildcard == "", len(self.host), self.port is not None)


def parse_entry(key: str, inject: dict[str, str]) -> Entry:
    m = ENTRY.fullmatch(key)
    if m is None:
        raise ValueError(f"invalid policy entry {key!r}")
    port = int(m["port"]) if m["port"] else None
    if port is not None and not 0 < port < 65536:
        raise ValueError(f"invalid port in policy entry {key!r}")
    return Entry(key, m["host"], m["wild"] or "", port, dict(inject))


def normalize_host(host: str) -> str:
    host = host.lower()
    return host[:-1] if host.endswith(".") else host


NUMERIC_LABEL = re.compile(r"[0-9]+|0x[0-9a-f]*")


def is_ip_literal(host: str) -> bool:
    """IP addresses, in any form the resolver accepts (`127.1`, `0x7f.1`, `2130706433`, IPv6).

    A real name never ends in a numeric label, which is what the resolver's own parser keys on.
    """
    if ":" in host or host.startswith("["):
        return True
    return NUMERIC_LABEL.fullmatch(host.rsplit(".", 1)[-1]) is not None


class Policy:
    def __init__(self, domains: dict[str, dict]):
        self.entries = [parse_entry(k, v.get("inject", {})) for k, v in domains.items()]

    def lookup(self, host: str, port: int) -> Entry | None:
        """The entry that allows host:port, or None. IP literals are never allowed."""
        host = normalize_host(host)
        if is_ip_literal(host):
            return None
        found = [e for e in self.entries if e.matches(host, port)]
        return max(found, key=lambda e: e.rank, default=None)


def read_secrets(policy: Policy, directory: str) -> dict[str, str]:
    """Credential name -> header value, for every credential the policy names."""
    secrets = {}
    for name in {c for e in policy.entries for c in e.inject.values()}:
        with open(os.path.join(directory, name), encoding="ascii") as f:
            value = f.read().rstrip("\r\n")
        # A header value is one printable ASCII line: anything else would be a bug or an injection.
        if not value or re.search(r"[^\x20-\x7e]", value):
            raise ValueError(f"credential {name}: empty or not printable ASCII")
        secrets[name] = value
    return secrets


def printable(text: str, limit: int = 200) -> str:
    return UNPRINTABLE.sub("?", text)[:limit]


def sd_notify(state: str) -> None:
    path = os.environ.get("NOTIFY_SOCKET")
    if not path:
        return
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
        s.connect("\0" + path[1:] if path.startswith("@") else path)
        s.send(state.encode())


class Guard:
    def __init__(self, instance: str, policy: Policy, secrets: dict[str, str]):
        self.instance = instance
        self.policy = policy
        self.secrets = secrets

    # Hooks ----------------------------------------------------------------------------------

    def running(self):
        # The listening sockets exist: the unit counts as started.
        sd_notify("READY=1")

    def http_connect(self, flow: http.HTTPFlow):
        self.guarded(flow, self.check_connect)

    def request(self, flow: http.HTTPFlow):
        self.guarded(flow, self.check_request)

    def responseheaders(self, flow: http.HTTPFlow):
        # Event streams (LLM APIs) are swallowed until the end unless streamed through.
        if flow.response.headers.get("content-type", "").startswith("text/event-stream"):
            flow.response.stream = True

    def response(self, flow: http.HTTPFlow):
        self.access(flow, flow.response.status_code if flow.response else 0)

    def error(self, flow: http.HTTPFlow):
        self.access(flow, 502)

    # Checks ---------------------------------------------------------------------------------

    def guarded(self, flow, check):
        try:
            reason = check(flow)
        except Exception as e:  # fail closed
            log.error("guest=%s check failed: %s", self.instance, e)
            reason = "internal error"
        if reason:
            flow.response = http.Response.make(
                403,
                f"a-box: {printable(flow.request.host)}:{flow.request.port} is blocked: {reason}\n",
                {"Content-Type": "text/plain", "Connection": "close"},
            )
            flow.metadata["a_box_blocked"] = reason
            self.access(flow, 403)

    def check_connect(self, flow) -> str | None:
        if self.policy.lookup(flow.request.host, flow.request.port) is None:
            return "not on this guest's allowlist"
        return None

    def check_request(self, flow) -> str | None:
        req = flow.request
        entry = self.policy.lookup(req.host, req.port)
        if entry is None:
            return "not on this guest's allowlist"

        # The proxy connects to req.host; a Host header that names something else would let a
        # server route the request elsewhere (domain fronting).
        if normalize_host(req.pretty_host) != normalize_host(req.host):
            return "Host header differs from the destination"

        for header in HOP_BY_HOP:
            req.headers.pop(header, None)

        # The guest's own copy of an injected header is replaced, never forwarded.
        for header, credential in entry.inject.items():
            req.headers[header] = self.secrets[credential]
        if entry.inject:
            flow.metadata["credential_injected"] = True
        return None

    # Log ------------------------------------------------------------------------------------

    def access(self, flow: http.HTTPFlow, status: int):
        """One line per flow; no query string, no header values."""
        if flow.metadata.get("a_box_logged"):
            return
        flow.metadata["a_box_logged"] = True

        req = flow.request
        path = "-" if req.method == "CONNECT" else printable(req.path.split("?", 1)[0])
        log.info(
            "guest=%s method=%s host=%s port=%d path=%s status=%d decision=%s credential_injected=%s",
            self.instance,
            printable(req.method, 16),
            printable(req.host),
            req.port,
            path,
            status,
            "blocked" if "a_box_blocked" in flow.metadata else "allowed",
            "true" if flow.metadata.get("credential_injected") else "false",
        )


def from_environment() -> Guard:
    with open(os.environ["A_BOX_POLICY"], encoding="utf-8") as f:
        config = json.load(f)
    policy = Policy(config["domains"])
    secrets = read_secrets(policy, os.environ["CREDENTIALS_DIRECTORY"]) if any(
        e.inject for e in policy.entries
    ) else {}
    return Guard(config["instance"], policy, secrets)


def setup_logging() -> None:
    # Own handler: mitmproxy's terminal log is kept at warnings and above.
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(message)s"))
    log.addHandler(handler)
    log.setLevel(logging.INFO)
    log.propagate = False
