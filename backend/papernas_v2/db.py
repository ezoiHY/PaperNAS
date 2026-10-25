from __future__ import annotations

import hashlib
from contextlib import contextmanager
from importlib.resources import files
from pathlib import Path

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .core import Problem, canonical, fingerprint, new_id


class Database:
    def __init__(self, url: str):
        self.url = url

    @contextmanager
    def connect(self):
        with psycopg.connect(
            self.url, row_factory=dict_row, options="-c search_path=papernas,public"
        ) as conn:
            yield conn

    def migrate(self):
        with self.connect() as conn:
            conn.execute("SELECT pg_advisory_xact_lock(72024001)")
            conn.execute("CREATE SCHEMA IF NOT EXISTS papernas")
            conn.execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations(name text PRIMARY KEY, checksum text NOT NULL)"
            )
            root = Path(str(files("papernas_v2").joinpath("migrations")))
            for path in sorted(root.glob("*.sql")):
                body = path.read_text()
                sha = hashlib.sha256(body.encode()).hexdigest()
                old = conn.execute(
                    "SELECT checksum FROM schema_migrations WHERE name=%s", (path.name,)
                ).fetchone()
                if old:
                    if old["checksum"] != sha:
                        raise RuntimeError(f"Applied migration changed: {path.name}")
                    continue
                conn.execute(body)
                conn.execute("INSERT INTO schema_migrations VALUES(%s,%s)", (path.name, sha))
            conn.execute(
                "INSERT INTO settings(key,value) VALUES('server_id',%s) ON CONFLICT DO NOTHING",
                (Jsonb(new_id()),),
            )

    @staticmethod
    def setting(conn, key: str, default=None):
        row = conn.execute("SELECT value FROM settings WHERE key=%s", (key,)).fetchone()
        return row["value"] if row else default

    @staticmethod
    def set_setting(conn, key: str, value):
        conn.execute(
            """INSERT INTO settings(key,value) VALUES(%s,%s)
                     ON CONFLICT(key) DO UPDATE SET value=excluded.value,revision=settings.revision+1""",
            (key, Jsonb(value)),
        )

    @staticmethod
    def emit(conn, kind: str, entity_id: str, revision: int = 0, **payload):
        conn.execute(
            """INSERT INTO outbox(id,kind,entity_id,revision,payload) VALUES(%s,%s,%s,%s,%s)""",
            (
                new_id(),
                kind,
                entity_id,
                revision,
                Jsonb({"id": entity_id, "key": entity_id, "revision": revision, **payload}),
            ),
        )

    def dispatch_events(self, limit: int = 200) -> int:
        # This lock is acquired after the originating business transaction has committed.
        # A sequence allocated in that transaction would skip late commits on reconnect.
        with self.connect() as conn:
            cursor = conn.execute(
                "SELECT cursor FROM event_counter WHERE singleton=true FOR UPDATE"
            ).fetchone()["cursor"]
            rows = conn.execute(
                "SELECT * FROM outbox WHERE NOT delivered ORDER BY created_at,id LIMIT %s FOR UPDATE",
                (limit,),
            ).fetchall()
            for row in rows:
                cursor += 1
                conn.execute(
                    "INSERT INTO events VALUES(%s,%s,%s,%s,%s,%s,now())",
                    (
                        cursor,
                        row["id"],
                        row["kind"],
                        row["entity_id"],
                        row["revision"],
                        Jsonb(row["payload"]),
                    ),
                )
                conn.execute("UPDATE outbox SET delivered=true WHERE id=%s", (row["id"],))
            conn.execute("UPDATE event_counter SET cursor=%s WHERE singleton=true", (cursor,))
            return cursor

    @staticmethod
    def idempotent(conn, scope: str, key: str, body, action):
        if not 16 <= len(key) <= 128 or not all(c.isalnum() or c in "_-" for c in key):
            raise Problem("idempotency_key_required", "请提供有效的 Idempotency-Key")
        digest = fingerprint(body)
        created = conn.execute(
            """INSERT INTO requests(scope,key,fingerprint) VALUES(%s,%s,%s)
                               ON CONFLICT DO NOTHING RETURNING key""",
            (scope, key, digest),
        ).fetchone()
        if not created:
            existing = conn.execute(
                "SELECT * FROM requests WHERE scope=%s AND key=%s", (scope, key)
            ).fetchone()
            if existing["fingerprint"] != digest:
                raise Problem("idempotency_conflict", "此请求标识已用于不同内容", 409)
            return existing["status_code"], existing["response"], True
        status, response = action(conn)
        # Round-trip canonical JSON to reject nonserializable values before commit.
        import json

        response = json.loads(canonical(response))
        conn.execute(
            "UPDATE requests SET response=%s,status_code=%s WHERE scope=%s AND key=%s",
            (Jsonb(response), status, scope, key),
        )
        return status, response, False
