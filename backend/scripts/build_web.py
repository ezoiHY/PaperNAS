#!/usr/bin/env python3
"""Package the first-party web client without Node, a bundler, or CDN assets."""

import shutil
from pathlib import Path

root = Path(__file__).resolve().parents[2]
destination = root / "backend/papernas_v2/web"
destination.mkdir(parents=True, exist_ok=True)
for name in ("index.html", "about.html", "style.css", "icon.svg"):
    shutil.copy2(root / "frontend" / name, destination / name)
shutil.copytree(root / "frontend/src", destination / "src", dirs_exist_ok=True)
shutil.copytree(root / "frontend/licenses", destination / "licenses", dirs_exist_ok=True)
print("Web client copied into the Python package.")
