"""Chunks C2/C3: real vsock connection through a booted guest.

Exercised entirely via SessionManager's attach-client API rather than raw
`stdio_sock` reads/writes: once `start()` has run, the background reader
thread is the only thing allowed to read `stdio_sock` (see
session_manager.py) - a test reading it directly would race that thread.
Sending through one attach client and reading the echo back through it
(or another) proves the same end-to-end vsock round trip chunk C2's
narrower test would have.
"""

from __future__ import annotations

import json
import shutil
import socket
import tempfile
import time
from pathlib import Path

import pytest

from agentvm.firecracker import FirecrackerVM
from agentvm.session_manager import SessionManager


def _boot_vm(
    tmp_path: Path, sock_dir: str, guest_kernel_image: Path, device1_v0_image: Path
) -> FirecrackerVM:
    firecracker_binary = shutil.which("firecracker")
    assert firecracker_binary, "firecracker binary not found on PATH"

    vm = FirecrackerVM(
        firecracker_binary=firecracker_binary,
        kernel_image=guest_kernel_image,
        rootfs_image=device1_v0_image,
        api_socket=Path(sock_dir) / "firecracker.sock",
        console_log=tmp_path / "console.log",
        vsock_uds_path=Path(sock_dir) / "vsock.sock",
    )
    vm.start()
    return vm


def _recv_exactly(sock: socket.socket, expected_len: int, timeout: float = 5.0) -> bytes:
    sock.settimeout(timeout)
    buf = b""
    while len(buf) < expected_len:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf


@pytest.mark.needs_kvm
def test_attach_client_round_trips_through_guest(
    tmp_path: Path, guest_kernel_image: Path, device1_v0_image: Path
) -> None:
    with tempfile.TemporaryDirectory(prefix="agentvm-fc-") as sock_dir:
        vm = _boot_vm(tmp_path, sock_dir, guest_kernel_image, device1_v0_image)
        try:
            manager = SessionManager(
                session_id="c2-roundtrip",
                session_dir=tmp_path,
                vm=vm,
                vsock_uds_path=vm.vsock_uds_path,
                connect_timeout=15.0,
            )
            try:
                attach_sock_path = Path(sock_dir) / "attach.sock"
                manager.start(attach_sock_path)

                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.connect(str(attach_sock_path))
                try:
                    client.sendall(b"hello\n")
                    expected = b"echo: hello\n"
                    assert _recv_exactly(client, len(expected)) == expected
                finally:
                    client.close()
            finally:
                manager.close()
        finally:
            vm.stop()


@pytest.mark.needs_kvm
def test_two_attach_clients_fan_out_and_disconnect_isolation(
    tmp_path: Path, guest_kernel_image: Path, device1_v0_image: Path
) -> None:
    with tempfile.TemporaryDirectory(prefix="agentvm-fc-") as sock_dir:
        vm = _boot_vm(tmp_path, sock_dir, guest_kernel_image, device1_v0_image)
        try:
            manager = SessionManager(
                session_id="c3-fanout",
                session_dir=tmp_path,
                vm=vm,
                vsock_uds_path=vm.vsock_uds_path,
                connect_timeout=15.0,
            )
            try:
                attach_sock_path = Path(sock_dir) / "attach.sock"
                manager.start(attach_sock_path)

                client_a = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client_a.connect(str(attach_sock_path))
                client_b = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client_b.connect(str(attach_sock_path))
                # Let the accept thread register both clients before the
                # guest's echo could possibly arrive.
                time.sleep(0.2)

                client_a.sendall(b"hello\n")
                expected = b"echo: hello\n"
                assert _recv_exactly(client_a, len(expected)) == expected
                assert _recv_exactly(client_b, len(expected)) == expected

                client_a.close()
                time.sleep(0.2)

                client_b.sendall(b"again\n")
                expected2 = b"echo: again\n"
                assert _recv_exactly(client_b, len(expected2)) == expected2
                client_b.close()
            finally:
                manager.close()
        finally:
            vm.stop()

        records = [
            json.loads(line) for line in (tmp_path / "terminal.jsonl").read_text().splitlines()
        ]
        directions = [record["direction"] for record in records]
        assert directions.count("host_to_guest") == 2
        assert directions.count("guest_to_host") == 2
