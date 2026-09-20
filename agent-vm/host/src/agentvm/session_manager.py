"""SessionManager (chunks C2/C3): holds one persistent host-initiated
vsock connection to a session's guest for the session's whole lifetime,
tees every byte into terminal.jsonl, and fans it out to zero or more
`attach` clients connected on a local Unix socket.

Threaded, not a shared event loop: this class is the entire process
chunk I's per-session `agentvm-session-<id>-stdio.service` unit runs, for
that one session's whole lifetime - spec §10.2 struck the shared-daemon/
event-loop model, so there's no cross-session state to coordinate. A
handful of blocking-socket threads per session is simpler to reason about
and to unit-test with fake sockets than an event loop.
"""

from __future__ import annotations

import base64
import json
import socket
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from agentvm import ports
from agentvm.firecracker import FirecrackerVM
from agentvm.vsock_bridge import connect_guest_port

READ_CHUNK_SIZE = 4096


class TerminalRecorder:
    """Appends one JSON line per chunk to a session's terminal.jsonl.

    Guarded by a lock: the guest->host and host->guest directions record
    from different threads (see AttachHub).
    """

    def __init__(self, path: Path, session_id: str) -> None:
        self._path = path
        self._session_id = session_id
        self._lock = threading.Lock()
        # Touched immediately, not on first byte: a future idle watchdog
        # (K5.3) reads this file's mtime as the "last activity" signal, so
        # "nothing yet" must not read as "already idle".
        path.touch(exist_ok=True)

    def record(self, direction: str, payload: bytes) -> None:
        line = json.dumps(
            {
                "timestamp": time.time(),
                "session_id": self._session_id,
                "stream": "terminal",
                "direction": direction,
                # base64: chunk boundaries don't align with UTF-8 code
                # points and terminal traffic isn't guaranteed valid
                # UTF-8 - encoding-agnostic by construction. Chunk J
                # unifies this into the shared transcript schema.
                "payload": base64.b64encode(payload).decode("ascii"),
            }
        )
        with self._lock:
            with self._path.open("a") as f:
                f.write(line + "\n")


class AttachHub:
    """Fan-out of guest->host bytes to every currently-connected attach
    client, and routing of host->guest bytes back to the guest.

    Disconnecting one client never touches `stdio_sock` or any other
    client - each is tracked/closed independently.
    """

    def __init__(self, stdio_sock: socket.socket, recorder: TerminalRecorder) -> None:
        self._stdio_sock = stdio_sock
        self._recorder = recorder
        self._clients: list[socket.socket] = []
        self._lock = threading.Lock()

    def add_client(self, client_sock: socket.socket) -> None:
        with self._lock:
            self._clients.append(client_sock)

    def remove_client(self, client_sock: socket.socket) -> None:
        with self._lock:
            if client_sock in self._clients:
                self._clients.remove(client_sock)
        try:
            client_sock.close()
        except OSError:
            pass

    def broadcast_from_guest(self, chunk: bytes) -> None:
        self._recorder.record("guest_to_host", chunk)
        with self._lock:
            clients = list(self._clients)
        for client in clients:
            try:
                client.sendall(chunk)
            except OSError:
                self.remove_client(client)

    def forward_to_guest(self, chunk: bytes) -> None:
        self._recorder.record("host_to_guest", chunk)
        self._stdio_sock.sendall(chunk)


def _pump_guest_to_attach_clients(
    stdio_sock: socket.socket, hub: AttachHub, stop_event: threading.Event
) -> None:
    while not stop_event.is_set():
        try:
            chunk = stdio_sock.recv(READ_CHUNK_SIZE)
        except OSError:
            return
        if not chunk:
            return
        hub.broadcast_from_guest(chunk)


def _pump_attach_client_to_guest(client_sock: socket.socket, hub: AttachHub) -> None:
    try:
        while True:
            try:
                chunk = client_sock.recv(READ_CHUNK_SIZE)
            except OSError:
                return
            if not chunk:
                return
            hub.forward_to_guest(chunk)
    finally:
        hub.remove_client(client_sock)


@dataclass
class SessionManager:
    """Connects to the guest's interactive stdio port (chunk C2) as soon
    as constructed, and holds that connection open regardless of whether
    or when `start()` is called - recording/attach only begin once
    `start()` runs (chunk C3).
    """

    session_id: str
    session_dir: Path
    vm: FirecrackerVM
    vsock_uds_path: Path
    connect_timeout: float = 10.0

    stdio_sock: socket.socket = field(init=False, repr=False)
    recorder: TerminalRecorder = field(init=False, repr=False)
    hub: AttachHub = field(init=False, repr=False)

    def __post_init__(self) -> None:
        self.stdio_sock = connect_guest_port(
            str(self.vsock_uds_path), ports.STDIO_PORT, self.connect_timeout
        )
        self.recorder = TerminalRecorder(self.session_dir / "terminal.jsonl", self.session_id)
        self.hub = AttachHub(self.stdio_sock, self.recorder)
        self._stop_event = threading.Event()
        self._attach_listener: socket.socket | None = None
        self._threads: list[threading.Thread] = []

    def start(self, attach_sock_path: Path) -> None:
        """Starts the background guest-reader pump and the attach.sock
        accept loop as daemon threads, then returns immediately."""
        reader_thread = threading.Thread(
            target=_pump_guest_to_attach_clients,
            args=(self.stdio_sock, self.hub, self._stop_event),
            daemon=True,
        )
        reader_thread.start()
        self._threads.append(reader_thread)

        if attach_sock_path.exists():
            attach_sock_path.unlink()
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(attach_sock_path))
        listener.listen()
        self._attach_listener = listener

        accept_thread = threading.Thread(target=self._accept_attach_clients, daemon=True)
        accept_thread.start()
        self._threads.append(accept_thread)

    def _accept_attach_clients(self) -> None:
        assert self._attach_listener is not None
        while True:
            try:
                client_sock, _ = self._attach_listener.accept()
            except OSError:
                return
            self.hub.add_client(client_sock)
            threading.Thread(
                target=_pump_attach_client_to_guest,
                args=(client_sock, self.hub),
                daemon=True,
            ).start()

    def close(self) -> None:
        self._stop_event.set()
        self.stdio_sock.close()
        if self._attach_listener is not None:
            self._attach_listener.close()
