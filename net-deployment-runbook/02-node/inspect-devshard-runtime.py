#!/usr/bin/env python3
"""Retain the Host inspection CLI while sharing the deployed agent inspector."""
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "04-ops/agent/inspect-devshard-runtime.py"
exec(compile(SOURCE.read_bytes(), str(SOURCE), "exec"), globals())
