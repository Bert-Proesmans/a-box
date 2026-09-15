"""Unit-level tests for FirecrackerVM that don't need KVM or a real
firecracker binary - see test_firecracker_boot.py for the real boot.

These use tiny shell scripts standing in for `firecracker_binary` to
exercise start()'s failure-cleanup path and the poll loops' fast-fail on
process death, without any of the real machinery.
"""

from __future__ import annotations

import stat
import time
import urllib.parse
from pathlib import Path

import pytest

from agentvm.firecracker import FirecrackerProcessExited, FirecrackerVM


def _write_fake_binary(path: Path, script: str) -> str:
    path.write_text(f"#!/bin/sh\n{script}\n")
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return str(path)


def _make_vm(tmp_path: Path, firecracker_binary: str) -> FirecrackerVM:
    return FirecrackerVM(
        firecracker_binary=firecracker_binary,
        kernel_image=tmp_path / "vmlinux",
        rootfs_image=tmp_path / "rootfs.squashfs",
        api_socket=tmp_path / "firecracker.sock",
        console_log=tmp_path / "console.log",
    )


def test_api_url_percent_encodes_special_characters_round_trip(tmp_path: Path) -> None:
    # A path with characters beyond plain "/" (space, "%") that a naive
    # `.replace("/", "%2F")` would mishandle.
    socket_path = tmp_path / "weird dir" / "100%.sock"
    vm = _make_vm(tmp_path, firecracker_binary="/bin/true")

    url = vm._api_url("/actions")

    netloc = urllib.parse.urlparse(url).netloc
    # This mirrors exactly what requests_unixsocket's adapter does to
    # recover the real socket path from the URL it's given.
    recovered = urllib.parse.unquote(netloc)
    assert recovered == str(vm.api_socket)
    assert url.endswith("/actions")


def test_start_cleans_up_process_and_console_log_on_put_failure(tmp_path: Path) -> None:
    # Creates a plain file at the api-sock path (satisfies the
    # exists()-based wait) then sleeps - connecting to it as a unix
    # socket fails immediately, standing in for a rejected PUT without
    # needing a real firecracker or a fake HTTP server.
    fake_binary = _write_fake_binary(
        tmp_path / "fake-firecracker",
        script='touch "$2"\nsleep 60\n',
    )
    vm = _make_vm(tmp_path, firecracker_binary=fake_binary)

    with pytest.raises(Exception):
        vm.start()

    assert not vm.is_running()
    assert vm._console_fh is None


def test_wait_for_api_socket_fails_fast_when_process_exits(tmp_path: Path) -> None:
    fake_binary = _write_fake_binary(
        tmp_path / "fake-firecracker",
        script="exit 1\n",
    )
    vm = _make_vm(tmp_path, firecracker_binary=fake_binary)

    started = time.monotonic()
    with pytest.raises(FirecrackerProcessExited):
        vm.start()
    elapsed = time.monotonic() - started

    # _wait_for_api_socket's own timeout is 5s; a prompt process-death
    # check should raise almost immediately rather than waiting it out.
    assert elapsed < 2.0
    assert not vm.is_running()
