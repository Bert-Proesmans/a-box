"""Host-initiated vsock connections through Firecracker's UDS proxy
(chunk C2).

Firecracker exposes vsock to the host as a Unix domain socket at a
configured `uds_path`. To open a host-initiated connection: connect to
`uds_path`, write `CONNECT <port>\\n`, and read back `OK <assigned_port>\\n`
- after that the same socket carries raw bytes to/from whatever the guest
has AF_VSOCK-bound on that port.

(This is the opposite direction from guest-initiated connections, which
surface at `<uds_path>_<port>` - chunks F/G use that direction.)
"""

from __future__ import annotations

import socket
import time


class VsockHandshakeError(Exception):
    """The CONNECT/OK handshake with Firecracker's vsock UDS failed."""


def _recv_handshake_line(sock: socket.socket, max_bytes: int = 256) -> bytes:
    """Reads up to a trailing `\\n` (or EOF), one byte at a time.

    Deliberately avoids `socket.makefile()`: its internal read-ahead
    buffering could silently swallow guest bytes sent immediately after
    the handshake line, since this same raw `sock` is handed back to the
    caller and reused for all subsequent traffic.
    """
    buf = bytearray()
    while len(buf) < max_bytes:
        byte = sock.recv(1)
        if not byte:
            break
        buf += byte
        if byte == b"\n":
            break
    return bytes(buf)


def connect_guest_port(uds_path: str, port: int, timeout: float) -> socket.socket:
    """Performs the CONNECT/OK handshake against `uds_path` for `port`,
    returning the connected socket.

    Per firecracker/docs/vsock.md, if no guest listener exists yet for
    `port`, Firecracker just closes the connection with no reply (rather
    than replying with an error) - this is indistinguishable from a
    boot-timing race, so that case is retried with a fresh connection
    until `timeout` elapses. A reply that doesn't match `OK <n>\\n` is a
    genuine protocol error, not a timing issue, and raises immediately.
    """
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise VsockHandshakeError(
                f"no guest listener on vsock port {port} within {timeout}s"
            ) from last_error

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(remaining)
        try:
            sock.connect(uds_path)
            sock.sendall(f"CONNECT {port}\n".encode("ascii"))
            reply = _recv_handshake_line(sock)
        except OSError as exc:
            sock.close()
            last_error = exc
            time.sleep(0.05)
            continue

        if not reply:
            sock.close()
            last_error = VsockHandshakeError(
                "connection closed before a handshake reply "
                f"(no guest listener on vsock port {port} yet)"
            )
            time.sleep(0.05)
            continue

        parts = reply.split()
        if len(parts) != 2 or parts[0] != b"OK" or not parts[1].isdigit():
            sock.close()
            raise VsockHandshakeError(f"malformed vsock handshake reply: {reply!r}")

        sock.settimeout(None)
        return sock
