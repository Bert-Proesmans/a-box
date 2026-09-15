import os

import pytest


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
