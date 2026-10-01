"""Unit tests for the tee/multiplex logic in session_manager.py, using
`socket.socketpair()` local sockets to stand in for the vsock stdio
connection and attach clients - no real vsock or KVM needed (see
test_session_manager_kvm.py for the end-to-end version).
"""

from __future__ import annotations

import base64
import json
import socket
from pathlib import Path

from agentvm.session_manager import AttachHub, TerminalRecorder


def test_terminal_recorder_appends_one_json_line_per_chunk(tmp_path: Path) -> None:
    log_path = tmp_path / "terminal.jsonl"
    recorder = TerminalRecorder(log_path, session_id="sess-1")

    recorder.record("guest_to_host", b"hello")
    recorder.record("host_to_guest", b"world")

    lines = log_path.read_text().splitlines()
    assert len(lines) == 2

    first = json.loads(lines[0])
    assert first["session_id"] == "sess-1"
    assert first["stream"] == "terminal"
    assert first["direction"] == "guest_to_host"
    assert base64.b64decode(first["payload"]) == b"hello"

    second = json.loads(lines[1])
    assert second["direction"] == "host_to_guest"
    assert base64.b64decode(second["payload"]) == b"world"


def test_terminal_recorder_touches_file_on_construction(tmp_path: Path) -> None:
    log_path = tmp_path / "terminal.jsonl"
    assert not log_path.exists()

    TerminalRecorder(log_path, session_id="sess-1")

    assert log_path.exists()
    assert log_path.read_text() == ""


def test_attach_hub_fans_out_guest_bytes_to_all_clients_and_logs(tmp_path: Path) -> None:
    stdio_local, _stdio_remote = socket.socketpair()
    recorder = TerminalRecorder(tmp_path / "terminal.jsonl", session_id="sess-1")
    hub = AttachHub(stdio_local, recorder)

    client_a_local, client_a_remote = socket.socketpair()
    client_b_local, client_b_remote = socket.socketpair()
    hub.add_client(client_a_local)
    hub.add_client(client_b_local)

    hub.broadcast_from_guest(b"echo: hi\n")

    assert client_a_remote.recv(100) == b"echo: hi\n"
    assert client_b_remote.recv(100) == b"echo: hi\n"

    lines = (tmp_path / "terminal.jsonl").read_text().splitlines()
    assert len(lines) == 1
    assert json.loads(lines[0])["direction"] == "guest_to_host"


def test_attach_hub_forwards_host_to_guest_bytes_and_logs(tmp_path: Path) -> None:
    stdio_local, stdio_remote = socket.socketpair()
    recorder = TerminalRecorder(tmp_path / "terminal.jsonl", session_id="sess-1")
    hub = AttachHub(stdio_local, recorder)

    hub.forward_to_guest(b"hello\n")

    assert stdio_remote.recv(100) == b"hello\n"
    lines = (tmp_path / "terminal.jsonl").read_text().splitlines()
    assert len(lines) == 1
    assert json.loads(lines[0])["direction"] == "host_to_guest"


def test_disconnecting_one_attach_client_does_not_close_stdio_sock_or_others(
    tmp_path: Path,
) -> None:
    stdio_local, stdio_remote = socket.socketpair()
    recorder = TerminalRecorder(tmp_path / "terminal.jsonl", session_id="sess-1")
    hub = AttachHub(stdio_local, recorder)

    client_a_local, client_a_remote = socket.socketpair()
    client_b_local, client_b_remote = socket.socketpair()
    hub.add_client(client_a_local)
    hub.add_client(client_b_local)

    hub.remove_client(client_a_local)

    # client_a's remote end sees EOF (its local peer was closed)...
    assert client_a_remote.recv(10) == b""

    # ...but stdio_sock and the other attach client are untouched.
    stdio_local.sendall(b"still alive")
    assert stdio_remote.recv(20) == b"still alive"

    hub.broadcast_from_guest(b"still working\n")
    assert client_b_remote.recv(100) == b"still working\n"
