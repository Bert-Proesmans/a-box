import os
import subprocess
from pathlib import Path

import pytest

AGENT_VM_NIX_DIR = Path(__file__).resolve().parents[2] / "nix"


def _nix_build(attr: str) -> Path:
    """Builds `agent-vm/nix -A <attr>` (session-scoped, so repeat runs
    are instant once Nix has cached them) rather than requiring
    out-of-band environment wiring - keeps `pytest agent-vm/host` runnable
    standalone from within the devshell."""
    result = subprocess.run(
        ["nix-build", str(AGENT_VM_NIX_DIR), "-A", attr, "--no-out-link"],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(result.stdout.strip().splitlines()[-1])


@pytest.fixture(scope="session")
def guest_kernel_image() -> Path:
    # vmlinux (not the default bzImage) is copied out alongside it - see
    # the comment in guest-kernel.nix for why.
    return _nix_build("guest-kernel") / "vmlinux"


@pytest.fixture(scope="session")
def device1_v0_image() -> Path:
    return _nix_build("device1-v0")


def _kvm_usable() -> bool:
    try:
        return os.access("/dev/kvm", os.R_OK | os.W_OK)
    except OSError:
        return False


def pytest_configure(config: pytest.Config) -> None:
    for marker, description in (
        ("needs_kvm", "requires a usable /dev/kvm"),
        ("needs_root", "requires elevated privileges (e.g. loop-mounts/BPF load)"),
        ("needs_bpf", "requires BPF load capability"),
    ):
        config.addinivalue_line("markers", f"{marker}: {description}")


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    if _kvm_usable():
        return
    skip_needs_kvm = pytest.mark.skip(reason="/dev/kvm not present or not accessible")
    for item in items:
        if "needs_kvm" in item.keywords:
            item.add_marker(skip_needs_kvm)
