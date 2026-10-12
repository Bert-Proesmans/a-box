"""test-upstream [--certs DIR] [--log FILE] --http PORT... --https PORT...

Fake internet for the proxy test: answers every request with what it received, on all addresses of
the namespace it runs in. https picks the certificate by SNI: `rogue.test` gets one from an unknown
CA, every other name the one of `secure.test` (so `wrong.test` fails name verification). Every
request is appended to the log as "<local port> <Host> <remote address>".
"""

import argparse
import http.server
import ssl
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--certs")
parser.add_argument("--log", required=True)
parser.add_argument("--http", type=int, nargs="*", default=[])
parser.add_argument("--https", type=int, nargs="*", default=[])
args = parser.parse_args()

lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        h = self.headers
        with lock, open(args.log, "a") as log:
            log.write(f"{self.server.server_port} {h.get('Host')} {self.client_address[0]}\n")

        if self.path.startswith("/sse"):
            # Three events one second apart: a proxy that buffers delivers them all at the end.
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(3):
                data = f"data: {i}\n\n".encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                self.wfile.flush()
                time.sleep(1)
            self.wfile.write(b"0\r\n\r\n")
            return

        body = (
            f"host={h.get('Host')} uri={self.path} auth=[{h.get('Authorization', '')}] "
            f"key=[{h.get('X-Api-Key', '')}] proxy-auth=[{h.get('Proxy-Authorization', '')}] "
            f"port={self.server.server_port}\n"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def context(name):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(f"{args.certs}/{name}.crt", f"{args.certs}/{name}.key")
    return ctx


def serve(port, tls):
    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler)
    if tls:
        contexts = {"rogue.test": context("rogue.test")}
        default = context("secure.test")

        def pick(sock, name, _):
            sock.context = contexts.get(name, default)

        default.sni_callback = pick
        server.socket = default.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


for port in args.http:
    threading.Thread(target=serve, args=(port, False), daemon=True).start()
for port in args.https:
    threading.Thread(target=serve, args=(port, True), daemon=True).start()

threading.Event().wait()
