"""Chunk B4: boot a real microVM and prove pid1-init reaches liveness.

Uses the `guest_kernel_image`/`device1_v0_image` fixtures from conftest.py
(built via `nix-build` against agent-vm/nix).
"""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

import pytest

from agentvm.firecracker import FirecrackerVM

LIVENESS_MESSAGE = "pid1-init: alive"


@pytest.mark.needs_kvm
def test_boots_and_reaches_liveness(
    tmp_path: Path, guest_kernel_image: Path, device1_v0_image: Path
) -> None:
    firecracker_binary = shutil.which("firecracker")
    assert firecracker_binary, "firecracker binary not found on PATH"

    # AF_UNIX socket paths are capped at ~108 bytes (SUN_LEN) - pytest's
    # tmp_path is nested deep enough to blow past that, so the api socket
    # (but not the console log, an ordinary file with no such limit) gets
    # a short-lived directory of its own directly under /tmp.
    with tempfile.TemporaryDirectory(prefix="agentvm-fc-") as sock_dir:
        vm = FirecrackerVM(
            firecracker_binary=firecracker_binary,
            kernel_image=guest_kernel_image,
            rootfs_image=device1_v0_image,
            api_socket=Path(sock_dir) / "firecracker.sock",
            console_log=tmp_path / "console.log",
        )

        try:
            vm.start()
            vm.wait_for_console_string(LIVENESS_MESSAGE, timeout=15.0)
        finally:
            vm.stop()

        assert not vm.is_running()
