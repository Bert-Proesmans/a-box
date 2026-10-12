"""proxyclient SOCKET URL [--ca FILE] [--header 'Name: value']... [--timeout S]

What a guest's HTTP client does through the proxy, over the proxy's unix socket. An http:// URL is
sent as an absolute-URI request; an https:// URL as `CONNECT host:port`, then TLS inside the
tunnel, verified against the --ca file only. Prints one JSON object: the CONNECT status (https),
the issuer and subject CNs the TLS peer showed, the response status and body.
"""

import argparse
import http.client
import json
import socket
import ssl
import sys
import time
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument("socket")
parser.add_argument("url")
parser.add_argument("--ca")
parser.add_argument("--header", action="append", default=[])
parser.add_argument("--timeout", type=float, default=30)
parser.add_argument("--stream", action="store_true", help="also report when each body chunk arrived")
args = parser.parse_args()

url = urllib.parse.urlsplit(args.url)
headers = dict(h.split(": ", 1) for h in args.header)
result = {}

sock = socket.socket(socket.AF_UNIX)
sock.settimeout(args.timeout)
sock.connect(args.socket)

if url.scheme == "https":
    port = url.port or 443
    authority = f"[{url.hostname}]:{port}" if ":" in url.hostname else f"{url.hostname}:{port}"
    sock.sendall(f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode())
    head = b""
    while not head.endswith(b"\r\n\r\n"):
        chunk = sock.recv(1)
        if not chunk:
            break
        head += chunk
    result["connect"] = int(head.split()[1])
    if result["connect"] != 200:
        result["body"] = ""
        print(json.dumps(result))
        sys.exit(0)

    ctx = ssl.create_default_context(cafile=args.ca)
    sock = ctx.wrap_socket(sock, server_hostname=url.hostname)
    cert = sock.getpeercert()
    flat = lambda rdns: {k: v for rdn in rdns for k, v in rdn}  # noqa: E731
    result["issuer"] = flat(cert["issuer"]).get("commonName")
    result["subject"] = flat(cert["subject"]).get("commonName")
    result["san"] = [v for k, v in cert.get("subjectAltName", ()) if k == "DNS"]
    target = (url.path or "/") + (f"?{url.query}" if url.query else "")
else:
    target = args.url

conn = http.client.HTTPConnection(url.hostname)
conn.sock = sock
headers.setdefault("Host", url.netloc)
headers.setdefault("Connection", "close")
conn.request("GET", target, headers=headers)
response = conn.getresponse()
result["status"] = response.status

if args.stream:
    start = time.monotonic()
    chunks = []
    while chunk := response.read1(65536):
        chunks.append([round(time.monotonic() - start, 1), chunk.decode()])
    result["chunks"] = chunks
    result["body"] = "".join(c for _, c in chunks)
else:
    result["body"] = response.read().decode(errors="replace")
print(json.dumps(result))
