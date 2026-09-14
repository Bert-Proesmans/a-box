{ pkgs }:

pkgs.python3Packages.buildPythonApplication {
  pname = "agentvm";
  version = "0.0.1";
  pyproject = true;

  src = ../host;

  build-system = [ pkgs.python3Packages.setuptools ];

  dependencies = [ pkgs.python3Packages.click ];

  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];

  meta.description = "agent-vm host orchestration CLI";
}
