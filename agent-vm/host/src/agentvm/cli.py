import click

from agentvm import __version__


@click.command()
@click.version_option(version=__version__, prog_name="agentvm")
def main() -> None:
    pass


if __name__ == "__main__":
    main()
