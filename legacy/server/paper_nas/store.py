"""Durable native-device state; research files remain owned by the engine."""
from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class Store:
    def __init__(self, path: Path):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.db() as db:
            db.executescript("""
              CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,name TEXT NOT NULL,
                token_hash TEXT UNIQUE NOT NULL,created REAL NOT NULL,expires REAL NOT NULL);
              CREATE TABLE IF NOT EXISTS requests(device TEXT NOT NULL,key TEXT NOT NULL,
                fingerprint TEXT NOT NULL,status INTEGER,body TEXT,created REAL NOT NULL,
                PRIMARY KEY(device,key));
              CREATE TABLE IF NOT EXISTS reading(paper TEXT PRIMARY KEY,pdf_sha256 TEXT,
                page INTEGER NOT NULL,section TEXT NOT NULL,revision INTEGER NOT NULL,
                updated REAL NOT NULL,device TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,payload TEXT NOT NULL,created REAL NOT NULL);
            """)
            db.execute("INSERT OR IGNORE INTO settings VALUES('server_id',?)", (secrets.token_hex(16),))
        path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def server_id(self):
        with self.db() as db:
            return db.execute("SELECT value FROM settings WHERE key='server_id'").fetchone()[0]

    def register(self, name: str):
        token = secrets.token_urlsafe(48)
        now = time.time()
        value = dict(id=secrets.token_hex(16), name=name, created=now, expires=now + 90 * 86400)
        with self.db() as db:
            db.execute("DELETE FROM devices WHERE expires<?", (now,))
            db.execute("INSERT INTO devices VALUES(?,?,?,?,?)",
                       (value['id'], name, digest(token), now, value['expires']))
        return {**value, 'token': token}

    def authenticate(self, token: str):
        with self.db() as db:
            row = db.execute("SELECT id,name,expires FROM devices WHERE token_hash=? AND expires>?",
                             (digest(token), time.time())).fetchone()
            return dict(row) if row else None

    def devices(self):
        with self.db() as db:
            return [dict(row) for row in db.execute(
                "SELECT id,name,created,expires FROM devices WHERE expires>? ORDER BY created", (time.time(),))]

    def revoke(self, identifier):
        with self.db() as db:
            db.execute("DELETE FROM devices WHERE id=?", (identifier,))

    def event(self, kind, payload=None):
        with self.db() as db:
            cursor = db.execute("INSERT INTO events(kind,payload,created) VALUES(?,?,?)",
                                (kind, json.dumps(payload or {}), time.time()))
            identifier = cursor.lastrowid
            db.execute("DELETE FROM events WHERE id<?", (identifier - 10000,))
            return identifier

    def events(self, after):
        with self.db() as db:
            bounds = db.execute("SELECT MIN(id),MAX(id) FROM events").fetchone()
            if bounds[0] and after < bounds[0] - 1:
                return [dict(id=bounds[1], kind='reset', payload={})]
            return [dict(id=row['id'], kind=row['kind'], payload=json.loads(row['payload']))
                    for row in db.execute("SELECT * FROM events WHERE id>? ORDER BY id LIMIT 100", (after,))]

    def cursor(self):
        with self.db() as db:
            return db.execute("SELECT COALESCE(MAX(id),0) FROM events").fetchone()[0]

    def claim(self, device, key, fingerprint):
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM requests WHERE device=? AND key=?", (device, key)).fetchone()
            if row:
                if row['fingerprint'] != fingerprint:
                    return 'conflict', None
                if row['status'] is None:
                    return 'pending', None
                return 'replay', (row['status'], json.loads(row['body']))
            db.execute("INSERT INTO requests VALUES(?,?,?,NULL,NULL,?)", (device, key, fingerprint, time.time()))
            return 'new', None

    def finish(self, device, key, status, body):
        with self.db() as db:
            db.execute("UPDATE requests SET status=?,body=? WHERE device=? AND key=?",
                       (status, json.dumps(body, ensure_ascii=False), device, key))

    def reading(self, paper):
        with self.db() as db:
            row = db.execute("SELECT * FROM reading WHERE paper=?", (paper,)).fetchone()
            return dict(row) if row else dict(paper=paper, page=1, section='report',
                                              pdf_sha256=None, revision=0, updated=0, device='')

    def save_reading(self, paper, value, device):
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT revision FROM reading WHERE paper=?", (paper,)).fetchone()
            revision = row[0] if row else 0
            if value['revision'] != revision:
                return None
            db.execute("INSERT INTO reading VALUES(?,?,?,?,?,?,?) ON CONFLICT(paper) DO UPDATE SET "
                       "pdf_sha256=excluded.pdf_sha256,page=excluded.page,section=excluded.section,"
                       "revision=excluded.revision,updated=excluded.updated,device=excluded.device",
                       (paper, value.get('pdf_sha256'), value['page'], value['section'],
                        revision + 1, time.time(), device))
        return self.reading(paper)
