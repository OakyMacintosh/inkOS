#!/bin/bash

uv sync
uv run pyinstaller main.py -n ink --onefile
uv run pyinstaller Book2InkBook.py -n inkbook --onefile 
