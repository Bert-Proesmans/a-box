"""Chunk B4: boot a real microVM and prove pid1-init reaches liveness.

Builds B1's kernel and B2/B3's device1-v0 image via `nix-build` against
agent-vm/nix (session-scoped, so repeat runs are instant once Nix has
cached them) rather than requiring out-of-band environment wiring - this
keeps `pytest agent-vm/host` runnable standalone from within the devshell.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

from agentvm.firecracker import FirecrackerVM

AGENT_VM_NIX_DIR = Path(__file__).resolve().parents[2] / "nix"

LIVENESS_MESSAGE = "pid1-init: alive"


def _nix_build(attr: str) -> Path:
    result = subprocess.run(
        ["nix-build", str(AGENT_VM_NIX_DIR), "-A", attr, "--no-out-link"],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(result.stdout.strip().splitlines()[-1])


@pytest.fixture(scope="session")
def guest_kernel_image() -> Path:
    return _nix_build("guest-kernel") / "vmlinux"


@pytest.fixture(scope="session")
def device1_v0_image() -> Path:
    return _nix_build("device1-v0")


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

        vm.start()
        try:
            vm.wait_for_console_string(LIVENESS_MESSAGE, timeout=15.0)
        finally:
            vm.stop()

        assert not vm.is_running()
