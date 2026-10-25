from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    database_url: str
    state_dir: Path
    host: str = "127.0.0.1"
    port: int = 8788
    max_download_bytes: int = 80 * 1024 * 1024
    network_timeout: float = 45
    parse_timeout: float = 240
    model_timeout: float = 120
    allow_private_hosts: tuple[str, ...] = ()
    use_docling: bool = True
    worker_stale_seconds: int = 90

    @property
    def access_key_file(self) -> Path:
        return self.state_dir / "access-key"

    @classmethod
    def environment(cls) -> "Settings":
        database_url = os.environ.get("PAPERNAS_V2_DATABASE_URL", "")
        if not database_url:
            raise RuntimeError("Set PAPERNAS_V2_DATABASE_URL before starting Paper NAS v2")
        return cls(
            database_url=database_url,
            state_dir=Path(os.environ.get("PAPERNAS_V2_STATE", "~/.local/share/papernas-v2")).expanduser(),
            host=os.environ.get("PAPERNAS_V2_HOST", "127.0.0.1"),
            port=int(os.environ.get("PAPERNAS_V2_PORT", "8788")),
            max_download_bytes=int(os.environ.get("PAPERNAS_V2_MAX_DOWNLOAD_BYTES", str(80 * 1024 * 1024))),
            network_timeout=float(os.environ.get("PAPERNAS_V2_NETWORK_TIMEOUT", "45")),
            parse_timeout=float(os.environ.get("PAPERNAS_V2_PARSE_TIMEOUT", "240")),
            model_timeout=float(os.environ.get("PAPERNAS_V2_MODEL_TIMEOUT", "120")),
            allow_private_hosts=tuple(
                filter(None, os.environ.get("PAPERNAS_V2_ALLOW_PRIVATE_HOSTS", "").split(","))
            ),
            use_docling=os.environ.get("PAPERNAS_V2_DOCLING", "1") != "0",
            worker_stale_seconds=int(os.environ.get("PAPERNAS_V2_WORKER_STALE_SECONDS", "90")),
        )
