{ pkgs }:

pkgs.python3Packages.buildPythonApplication {
  pname = "agentvm";
  version = "0.0.1";
  pyproject = true;

  src = ../host;

  build-system = [ pkgs.python3Packages.setuptools ];

  dependencies = [
    pkgs.python3Packages.click
    pkgs.python3Packages.requests
    pkgs.python3Packages.requests-unixsocket
  ];

  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];

  # `needs_kvm` tests shell out to `nix-build` and a real `firecracker`
  # binary + working KVM - none of which the package checkPhase's own
  # (possibly further-sandboxed) build environment can be relied on to
  # provide hermetically. They're meant to be run interactively instead
  # (`pytest agent-vm/host`, see conftest.py's runtime /dev/kvm skip).
  disabledTestMarks = [ "needs_kvm" ];

  meta.description = "agent-vm host orchestration CLI";
}
