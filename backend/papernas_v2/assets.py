from __future__ import annotations

import hashlib
import os
import re
import tempfile
from pathlib import Path

from .core import Problem, canonical


class AssetStore:
    def __init__(self, root: Path):
        self.root = root
        self.temp = root / "tmp"
        self.temp.mkdir(parents=True, exist_ok=True, mode=0o700)

    def path(self, sha: str) -> Path:
        if not re.fullmatch(r"[a-f0-9]{64}", sha):
            raise Problem("invalid_asset", "文件标识无效", 404)
        return self.root / "objects" / sha[:2] / sha

    def put(self, content: bytes, media_type: str) -> dict:
        sha = hashlib.sha256(content).hexdigest()
        target = self.path(sha)
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, name = tempfile.mkstemp(dir=self.temp)
            try:
                with os.fdopen(fd, "wb") as stream:
                    stream.write(content)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(name, target)
                directory = os.open(target.parent, os.O_RDONLY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                if os.path.exists(name):
                    os.unlink(name)
        return {"sha256": sha, "media_type": media_type, "byte_size": len(content)}

    def put_json(self, data) -> dict:
        return self.put(canonical(data).encode(), "application/json")

    @staticmethod
    def register(conn, asset: dict):
        conn.execute(
            """INSERT INTO assets(sha256,media_type,byte_size) VALUES(%s,%s,%s)
                     ON CONFLICT(sha256) DO NOTHING""",
            (asset["sha256"], asset["media_type"], asset["byte_size"]),
        )

    def read_json(self, sha):
        import json

        return json.loads(self.path(sha).read_bytes())
