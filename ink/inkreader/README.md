# InkReader

InkReader is a Python 3 rebuild of the original setup flow.

## What it does

- stores a small local `config.json5`
- captures a device path and device name
- parses DeviceTree source from Python and Lua

## Run

```bash
python3 main.py setup
python3 main.py show-config
python3 main.py doctor
python3 main.py parse-dts path/to/file.dts
```

## DeviceTree parser

Python:

```python
from devicetree import load_dts

tree = load_dts("board.dts")
```

Lua:

```lua
local DeviceTree = require("DeviceTree")
local tree = DeviceTree.load("board.dts")
```
