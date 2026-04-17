from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path

import typer
from rich import print

from devicetree import load_dts

app = typer.Typer(help="InkReader setup and config CLI.")
CONFIG_PATH = Path("config.json5")


@dataclass(slots=True)
class ReaderConfig:
    device_path: str
    device_name: str


def _load_config(path: Path = CONFIG_PATH) -> ReaderConfig | None:
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    return ReaderConfig(
        device_path=str(data["device_path"]),
        device_name=str(data["device_name"]),
    )


def _save_config(config: ReaderConfig, path: Path = CONFIG_PATH) -> None:
    path.write_text(
        json.dumps(asdict(config), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


@app.command()
def setup(
    device_path: str = typer.Option(
        ..., "--device-path", "-d", prompt="Enter device path", help="Example: /dev/sdc1"
    ),
    device_name: str = typer.Option(
        ..., "--device-name", "-n", prompt="Enter device name", help="Example: Johnny's iPod"
    ),
) -> None:
    config = ReaderConfig(device_path=device_path, device_name=device_name)
    _save_config(config)
    print(f"[green]Saved config to[/green] {CONFIG_PATH}")
    print(config)


@app.command("show-config")
def show_config() -> None:
    config = _load_config()
    if config is None:
        raise typer.BadParameter(f"{CONFIG_PATH} does not exist. Run `inkreader setup` first.")
    print(config)


@app.command()
def doctor() -> None:
    config = _load_config()
    if config is None:
        print(f"[yellow]Missing[/yellow] {CONFIG_PATH}")
        raise typer.Exit(code=1)
    print(f"[green]OK[/green] {CONFIG_PATH}")
    print(config)


@app.command("parse-dts")
def parse_dts_command(path: Path = typer.Argument(..., exists=True, dir_okay=False, readable=True)) -> None:
    """Parse a DeviceTree source file and print JSON."""

    data = load_dts(path)
    print(json.dumps(data, indent=2, sort_keys=True))


def main() -> None:
    app()


if __name__ == "__main__":
    main()
