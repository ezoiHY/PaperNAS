from __future__ import annotations

import hashlib
import json
import secrets
from datetime import date, datetime


def new_id() -> str:
    return secrets.token_hex(10)


def json_default(value):
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    raise TypeError(f"Cannot serialize {type(value).__name__}")


def canonical(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=json_default)


def fingerprint(value) -> str:
    return hashlib.sha256(canonical(value).encode()).hexdigest()


class Problem(Exception):
    def __init__(self, code: str, message: str, status: int = 400, **context):
        super().__init__(message)
        self.code, self.message, self.status, self.context = code, message, status, context


class Retryable(Exception):
    def __init__(self, message: str, *, delay: float = 10, code: str = "temporary_failure"):
        super().__init__(message)
        self.delay, self.code = delay, code


class NeedsInput(Exception):
    def __init__(self, message: str, *, code: str = "needs_input"):
        super().__init__(message)
        self.code = code


class Superseded(Exception):
    """This attempt no longer has permission to publish its output."""
