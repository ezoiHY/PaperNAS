#!/usr/bin/env python3
"""Build a project-local PostgreSQL for integration tests; never installs system-wide."""

from __future__ import annotations

import hashlib
import os
import subprocess
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("PAPERNAS_POSTGRES_BUILD_ROOT", str(ROOT / ".runtime")))
VERSION = "18.6"
PREFIX = RUNTIME / "postgres"


def main():
    RUNTIME.mkdir(parents=True, exist_ok=True)
    if (PREFIX / "bin" / "postgres").exists():
        print(PREFIX, flush=True)
        return
    archive = RUNTIME / f"postgresql-{VERSION}.tar.bz2"
    base = f"https://ftp.postgresql.org/pub/source/v{VERSION}/{archive.name}"
    print(f"Downloading PostgreSQL {VERSION} source", flush=True)
    expected = urllib.request.urlopen(base + ".sha256", timeout=60).read().decode().split()[0]
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        with urllib.request.urlopen(base, timeout=120) as response, archive.open("wb") as output:
            while part := response.read(1024 * 1024):
                output.write(part)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError("PostgreSQL source checksum mismatch")
    source = RUNTIME / f"postgresql-{VERSION}"
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(RUNTIME, filter="data")
    log = RUNTIME / "postgres-build.log"
    commands = [
        ["./configure", f"--prefix={PREFIX}", "--without-icu", "--without-readline", "--disable-nls"],
        ["make", f"-j{min(os.cpu_count() or 2, 8)}"],
        ["make", "install"],
    ]
    with log.open("w") as stream:
        for command in commands:
            print("Running " + " ".join(command), flush=True)
            result = subprocess.run(command, cwd=source, stdout=stream, stderr=subprocess.STDOUT)
            if result.returncode:
                stream.flush()
                print("\n".join(log.read_text().splitlines()[-35:]), flush=True)
                raise SystemExit(result.returncode)
    print(f"PostgreSQL ready: {PREFIX}", flush=True)


if __name__ == "__main__":
    main()
