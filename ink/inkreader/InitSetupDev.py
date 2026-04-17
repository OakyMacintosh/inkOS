from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path

from rich import print

CONFIG_PATH = Path("config.json5")


@dataclass(slots=True)
class SetupConfig:
    device_path: str
    device_name: str


class Setup:
    def __init__(self, config_path: Path = CONFIG_PATH):
        self.config_path = config_path

    def write_config(self, device_path: str, device_name: str) -> SetupConfig:
        config = SetupConfig(device_path=device_path, device_name=device_name)
        self.config_path.write_text(
            json.dumps(asdict(config), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return config

    def read_config(self) -> SetupConfig | None:
        if not self.config_path.exists():
            return None
        data = json.loads(self.config_path.read_text(encoding="utf-8"))
        return SetupConfig(
            device_path=str(data["device_path"]),
            device_name=str(data["device_name"]),
        )

    def show(self) -> None:
        config = self.read_config()
        if config is None:
            print(f"[yellow]Missing[/yellow] {self.config_path}")
            return
        print(config)
