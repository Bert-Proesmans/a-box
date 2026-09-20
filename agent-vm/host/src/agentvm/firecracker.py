"""Minimal Firecracker microVM launcher (chunk B4).

Talks to a `firecracker` process over its REST API, exposed as a Unix
domain socket, to assemble a machine config, boot it, and capture the
guest's serial console (UART) output to a file.
"""

from __future__ import annotations

import subprocess
import time
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

import requests
import requests_unixsocket


class FirecrackerBootTimeout(Exception):
    """The expected string never showed up in the console log in time."""


class FirecrackerApiError(Exception):
    """A Firecracker REST API call returned a non-2xx response."""


class FirecrackerProcessExited(Exception):
    """The firecracker process exited while we were waiting on it for
    something else (e.g. the API socket or a console log string)."""


# Firecracker's own /vsock schema requires guest_cid >= 3 (2 is reserved
# for the host). The value is otherwise inert here: the host side of a
# vsock device is a UDS proxy with no peer-CID concept at all (spec
# §11.1), and the guest binds its listeners with VMADDR_CID_ANY, so
# nothing ever reads this number back.
_VSOCK_GUEST_CID = 3


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
    # None means no vsock device at all (chunk B4's boot test doesn't need
    # one). When set, Firecracker exposes it to the host as a UDS at this
    # path - see vsock_bridge.py for the host-initiated connection
    # handshake against it (chunk C2).
    vsock_uds_path: Path | None = None

    _process: subprocess.Popen | None = field(default=None, init=False, repr=False)
    _console_fh: object | None = field(default=None, init=False, repr=False)
    _session: requests_unixsocket.Session | None = field(default=None, init=False, repr=False)

    def _api_url(self, path: str) -> str:
        # Fully quoted (not just "/" -> "%2F"): requests_unixsocket
        # recovers the real path with a matching unquote() on its side
        # (see its UnixAdapter.get_connection), so this round-trips any
        # character the socket path might contain.
        encoded_socket = urllib.parse.quote(str(self.api_socket), safe="")
        return f"http+unix://{encoded_socket}{path}"

    def _put(self, path: str, body: dict) -> requests.Response:
        assert self._session is not None
        response = self._session.put(self._api_url(path), json=body, timeout=5.0)
        if not response.ok:
            raise FirecrackerApiError(
                f"PUT {path} failed: {response.status_code} {response.text}"
            )
        return response

    def _console_log_text(self) -> str:
        if self.console_log.exists():
            return self.console_log.read_text(errors="replace")
        return ""

    def _poll_until(
        self,
        condition: Callable[[], bool],
        timeout: float,
        interval: float,
        make_timeout_error: Callable[[], Exception],
    ) -> None:
        """Poll `condition` until it's true, raising promptly (rather than
        waiting out the full timeout) if the firecracker process exits
        first - a crashed boot should fail fast with its exit code and
        console output, not silently spin."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._process is not None:
                exit_code = self._process.poll()
                if exit_code is not None:
                    raise FirecrackerProcessExited(
                        f"firecracker process exited (code {exit_code}) while "
                        f"waiting; console log:\n{self._console_log_text()}"
                    )
            if condition():
                return
            time.sleep(interval)
        raise make_timeout_error()

    def _force_cleanup(self) -> None:
        """Best-effort teardown: kill the process if it's still running and
        close the console log handle. Used both when start() fails
        partway through and by stop()'s own force-kill path."""
        if self._process is not None and self._process.poll() is None:
            self._process.kill()
            self._process.wait()
        if self._console_fh is not None:
            self._console_fh.close()
            self._console_fh = None

    def start(self) -> None:
        """Start the firecracker process and boot the configured VM."""
        if self.api_socket.exists():
            self.api_socket.unlink()
        if self.vsock_uds_path is not None and self.vsock_uds_path.exists():
            self.vsock_uds_path.unlink()

        self.console_log.parent.mkdir(parents=True, exist_ok=True)
        self._console_fh = self.console_log.open("wb")

        self._process = subprocess.Popen(
            [self.firecracker_binary, "--api-sock", str(self.api_socket)],
            stdout=self._console_fh,
            stderr=subprocess.STDOUT,
        )
        try:
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
            if self.vsock_uds_path is not None:
                self._put(
                    "/vsock",
                    {
                        "guest_cid": _VSOCK_GUEST_CID,
                        "uds_path": str(self.vsock_uds_path),
                    },
                )
            self._put("/actions", {"action_type": "InstanceStart"})
        except Exception:
            self._force_cleanup()
            raise

    def _wait_for_api_socket(self, timeout: float = 5.0) -> None:
        self._poll_until(
            condition=self.api_socket.exists,
            timeout=timeout,
            interval=0.05,
            make_timeout_error=lambda: TimeoutError(
                f"firecracker API socket never appeared at {self.api_socket}"
            ),
        )

    def wait_for_console_string(self, expected: str, timeout: float = 15.0) -> None:
        self._poll_until(
            condition=lambda: expected in self._console_log_text(),
            timeout=timeout,
            interval=0.1,
            make_timeout_error=lambda: FirecrackerBootTimeout(
                f"never saw {expected!r} in {self.console_log} within {timeout}s"
            ),
        )

    def is_running(self) -> bool:
        return self._process is not None and self._process.poll() is None

    def stop(self, timeout: float = 5.0) -> None:
        """Stop the VM by killing the firecracker process.

        There's no working graceful-shutdown path to attempt first:
        Firecracker's SendCtrlAltDel action relies on the guest noticing
        an emulated i8042 reset, and this minimal kernel has no
        keyboard/input driver support to notice it with (see
        guest-kernel.nix) - so it would only add a guaranteed-to-expire
        wait. This microVM model is meant to be reaped outright, not
        gracefully powered off.
        """
        if self._process is None:
            return

        if self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait()

        if self._console_fh is not None:
            self._console_fh.close()
            self._console_fh = None
