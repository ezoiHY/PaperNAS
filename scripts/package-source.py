#!/usr/bin/env python3
"""Create an audited source release and the server's corresponding-source offer."""

import argparse
import hashlib
import json
import shutil
import tarfile
import tomllib
from pathlib import Path

from public_source import ROOT, audit, source_files

parser = argparse.ArgumentParser()
parser.add_argument("--from-checkout", action="store_true", help="Use the allowlist in an exported/Docker checkout")
args = parser.parse_args()
paths = source_files(from_checkout=args.from_checkout)
findings = audit(paths)
if not paths or findings:
    for path, reason in findings:
        print(f"FAIL {path}: {reason}")
    raise SystemExit("Source packaging stopped; audit the selected files first.")
version = tomllib.loads((ROOT / "backend/pyproject.toml").read_text())["project"]["version"]
destination = ROOT / "dist"
destination.mkdir(exist_ok=True)
archive = destination / f"PaperNAS-v{version}-source.tar.gz"
with tarfile.open(archive, "w:gz") as output:
    for path in paths:
        output.add(ROOT / path, arcname=f"PaperNAS-{version}/" + path.as_posix(), recursive=False)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(destination / (archive.name + ".sha256")).write_text(digest + "  " + archive.name + "\n")
(destination / "source-manifest.json").write_text(json.dumps({
    "version": version, "archive": archive.name, "sha256": digest,
    "files": [{"path": p.as_posix(), "sha256": hashlib.sha256((ROOT / p).read_bytes()).hexdigest()} for p in paths],
}, indent=2) + "\n")
offer = ROOT / "backend/papernas_v2/source"
offer.mkdir(exist_ok=True)
shutil.copy2(archive, offer / "paper-nas-source.tar.gz")
print(f"Packaged {len(paths)} public source files into {archive.name}")
