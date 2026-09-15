"""Minimal Firecracker microVM launcher (chunk B4).

Talks to a `firecracker` process over its REST API, exposed as a Unix
domain socket, to assemble a machine config, boot it, and capture the
guest's serial console (UART) output to a file.
"""

from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

import requests
import requests_unixsocket


class FirecrackerBootTimeout(Exception):
    """The expected string never showed up in the console log in time."""


class FirecrackerApiError(Exception):
    """A Firecracker REST API call returned a non-2xx response."""


@dataclass
class FirecrackerVM:
    firecracker_binary: str
    kernel_image: Path
    rootfs_image: Path
    api_socket: Path
    console_log: Path
    vcpu_count: int = 1
    mem_size_mib: int = 128
    # rootfstype is spelled out explicitly rather than relying on the
    # kernel's fs-autoprobe fallback, since we know exactly what device1's
    # root device is.
    kernel_args: str = "console=ttyS0 root=/dev/vda ro rootfstype=squashfs init=/init"

    _process: subprocess.Popen | None = field(default=None, init=False, repr=False)
    _console_fh: object | None = field(default=None, init=False, repr=False)
    _session: requests_unixsocket.Session | None = field(default=None, init=False, repr=False)

    def _api_url(self, path: str) -> str:
        encoded_socket = str(self.api_socket).replace("/", "%2F")
        return f"http+unix://{encoded_socket}{path}"

    def _put(self, path: str, body: dict) -> requests.Response:
        assert self._session is not None
        response = self._session.put(self._api_url(path), json=body, timeout=5.0)
        if not response.ok:
            raise FirecrackerApiError(
                f"PUT {path} failed: {response.status_code} {response.text}"
            )
        return response

    def _wait_for_api_socket(self, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.api_socket.exists():
                return
            time.sleep(0.05)
        raise TimeoutError(f"firecracker API socket never appeared at {self.api_socket}")

    def start(self) -> None:
        """Start the firecracker process and boot the configured VM."""
        if self.api_socket.exists():
            self.api_socket.unlink()

        self.console_log.parent.mkdir(parents=True, exist_ok=True)
        self._console_fh = self.console_log.open("wb")

        self._process = subprocess.Popen(
            [self.firecracker_binary, "--api-sock", str(self.api_socket)],
            stdout=self._console_fh,
            stderr=subprocess.STDOUT,
        )
        self._wait_for_api_socket()

        self._session = requests_unixsocket.Session()

        self._put(
            "/boot-source",
            {
                "kernel_image_path": str(self.kernel_image),
                "boot_args": self.kernel_args,
            },
        )
        self._put(
            "/drives/rootfs",
            {
                "drive_id": "rootfs",
                "path_on_host": str(self.rootfs_image),
                "is_root_device": True,
                "is_read_only": True,
            },
        )
        self._put(
            "/machine-config",
            {
                "vcpu_count": self.vcpu_count,
                "mem_size_mib": self.mem_size_mib,
            },
        )
        self._put("/actions", {"action_type": "InstanceStart"})

    def wait_for_console_string(self, expected: str, timeout: float = 15.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.console_log.exists():
                text = self.console_log.read_text(errors="replace")
                if expected in text:
                    return
            time.sleep(0.1)
        raise FirecrackerBootTimeout(
            f"never saw {expected!r} in {self.console_log} within {timeout}s"
        )

    def is_running(self) -> bool:
        return self._process is not None and self._process.poll() is None

    def stop(self, timeout: float = 5.0) -> None:
        """Stop the VM: try a guest reset first, fall back to killing the
        firecracker process outright, then wait for it to actually exit."""
        if self._process is None:
            return

        if self.is_running():
            try:
                self._put("/actions", {"action_type": "SendCtrlAltDel"})
            except Exception:
                pass

            try:
                self._process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self._process.terminate()
                try:
                    self._process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait()

        if self._console_fh is not None:
            self._console_fh.close()
