#!/usr/bin/env python3
"""Run a v2 command using the isolated project-local development database."""

import json
import os
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
config = json.loads((root / ".runtime" / "connection.json").read_text())
os.environ["PAPERNAS_V2_DATABASE_URL"] = config["database_url"]
os.environ["PAPERNAS_V2_STATE"] = config["state_dir"]
os.execv(
    str(root / ".venv" / "bin" / "python"),
    [str(root / ".venv" / "bin" / "python"), "-m", "papernas_v2.cli", *sys.argv[1:]],
)
