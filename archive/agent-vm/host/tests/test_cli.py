from click.testing import CliRunner

from agentvm import __version__
from agentvm.cli import main


def test_version_flag_prints_version_and_exits_zero():
    runner = CliRunner()
    result = runner.invoke(main, ["--version"])

    assert result.exit_code == 0
    assert __version__ in result.output
