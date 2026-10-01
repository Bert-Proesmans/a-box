"""Unit tests for the CONNECT/OK handshake in vsock_bridge.py, against a
fake Unix-socket server standing in for Firecracker's vsock UDS proxy -
no real vsock or KVM needed (see test_session_manager_kvm.py for that).
"""

from __future__ import annotations

import socket
import threading
from pathlib import Path

import pytest

from agentvm.vsock_bridge import VsockHandshakeError, connect_guest_port


def _serve_uds(path: Path, behaviors: list[bytes | None]) -> None:
    """Accepts len(behaviors) connections in sequence. `None` closes the
    connection immediately with no reply (simulating "no guest listener
    yet", per firecracker/docs/vsock.md); otherwise sends that reply."""
    server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server_sock.bind(str(path))
    server_sock.listen(len(behaviors))

    def run() -> None:
        for behavior in behaviors:
            conn, _ = server_sock.accept()
            conn.recv(4096)
            if behavior is not None:
                conn.sendall(behavior)
            conn.close()
        server_sock.close()

    threading.Thread(target=run, daemon=True).start()


def test_connect_guest_port_happy_path(tmp_path: Path) -> None:
    sock_path = tmp_path / "v.sock"
    _serve_uds(sock_path, [b"OK 10000\n"])

    result = connect_guest_port(str(sock_path), 10000, timeout=2.0)
    try:
        assert isinstance(result, socket.socket)
    finally:
        result.close()


def test_connect_guest_port_raises_on_malformed_reply(tmp_path: Path) -> None:
    sock_path = tmp_path / "v.sock"
    _serve_uds(sock_path, [b"NOPE\n"])

    with pytest.raises(VsockHandshakeError):
        connect_guest_port(str(sock_path), 10000, timeout=2.0)


def test_connect_guest_port_retries_until_listener_appears(tmp_path: Path) -> None:
    sock_path = tmp_path / "v.sock"
    _serve_uds(sock_path, [None, None, b"OK 10000\n"])

    result = connect_guest_port(str(sock_path), 10000, timeout=5.0)
    try:
        assert isinstance(result, socket.socket)
    finally:
        result.close()


def test_connect_guest_port_gives_up_after_timeout(tmp_path: Path) -> None:
    sock_path = tmp_path / "v.sock"
    _serve_uds(sock_path, [None, None, None, None, None, None, None, None, None, None])

    with pytest.raises(VsockHandshakeError):
        connect_guest_port(str(sock_path), 10000, timeout=0.2)
