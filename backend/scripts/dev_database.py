#!/usr/bin/env python3
"""Start/stop the disposable, loopback-only project PostgreSQL installation."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / ".runtime"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["start", "stop", "status"], nargs="?", default="start")
    parser.add_argument("--port", type=int, default=55438)
    args = parser.parse_args()
    binary, data = RUNTIME / "postgres/bin", RUNTIME / "pgdata"
    pg_ctl = binary / "pg_ctl"
    if not pg_ctl.exists():
        parser.error("Run scripts/bootstrap_postgres.py first")
    if args.action in {"stop", "status"}:
        raise SystemExit(subprocess.run([str(pg_ctl), "-D", str(data), args.action]).returncode)
    if not (data / "PG_VERSION").exists():
        subprocess.run(
            [
                str(binary / "initdb"),
                "-D",
                str(data),
                "-A",
                "trust",
                "-U",
                "papernas",
                "--no-locale",
                "--encoding=UTF8",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    active = (
        subprocess.run([str(pg_ctl), "-D", str(data), "status"], stdout=subprocess.DEVNULL).returncode == 0
    )
    if not active:
        subprocess.run(
            [
                str(pg_ctl),
                "-D",
                str(data),
                "-l",
                str(RUNTIME / "postgres.log"),
                "-o",
                f"-h 127.0.0.1 -p {args.port} -k {RUNTIME}",
                "-w",
                "start",
            ],
            check=True,
        )
    admin = f"postgresql://papernas@127.0.0.1:{args.port}/postgres"
    database = "papernas_v2_dev"
    with psycopg.connect(admin, autocommit=True) as conn:
        if not conn.execute("SELECT 1 FROM pg_database WHERE datname=%s", (database,)).fetchone():
            conn.execute(psycopg.sql.SQL("CREATE DATABASE {}").format(psycopg.sql.Identifier(database)))
    config = {
        "database_url": admin.rsplit("/", 1)[0] + "/" + database,
        "admin_url": admin,
        "state_dir": str(RUNTIME / "dev-data"),
    }
    (RUNTIME / "connection.json").write_text(json.dumps(config, indent=2) + "\n")
    (RUNTIME / "connection.json").chmod(0o600)
    print(f"Project database ready on 127.0.0.1:{args.port}; settings in .runtime/connection.json")


if __name__ == "__main__":
    main()
