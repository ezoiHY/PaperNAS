"""Shared allowlist and checks for public source packaging. Never prints secrets."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTORIES = {"backend", "frontend", "macOS", "legacy", "docs", "design-system", "scripts", "deploy", ".github"}
FILES = {
    "README.md", "LICENSE", "THIRD-PARTY-NOTICES.md", "CONTRIBUTING.md", "SECURITY.md",
    "CHANGELOG.md", "AGENTS.md", "compose.yaml", ".env.example", ".gitignore", ".gitattributes", ".dockerignore",
}
EXCLUDED_PARTS = {
    ".git", ".private", ".venv", ".runtime", ".build", ".swiftpm", "__pycache__", ".pytest_cache",
    ".ruff_cache", "node_modules", "dist", "build", "verification", "state", "backups",
}
GENERATED = {"backend/papernas_v2/web", "backend/papernas_v2/source"}
SECRET_PATTERNS = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "provider credential": re.compile(rb"\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}"),
    "GitHub credential": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})"),
    "AWS access key": re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "literal bearer credential": re.compile(rb"Bearer [A-Za-z0-9_-]{32,}"),
    "personal home path": re.compile(rb"/(?:Users|home)/[a-zA-Z][a-zA-Z0-9_-]*/"),
}


def excluded(path: Path) -> bool:
    value = path.as_posix()
    return (
        any(p in EXCLUDED_PARTS or p.endswith(".egg-info") for p in path.parts)
        or any(value == p or value.startswith(p + "/") for p in GENERATED)
        or path.name == ".DS_Store"
        or path.suffix in {".pyc", ".log"}
    )


def source_files(*, from_checkout=False):
    if not from_checkout:
        result = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True)
        return sorted(Path(p.decode()) for p in result.stdout.split(b"\0") if p)
    result = [Path(name) for name in FILES if (ROOT / name).is_file()]
    for directory in sorted(DIRECTORIES):
        base = ROOT / directory
        if not base.is_dir():
            continue
        # Prune private environments before descending into them.
        import os
        for current, dirs, names in os.walk(base, followlinks=False):
            relative = Path(current).relative_to(ROOT)
            dirs[:] = [d for d in dirs if not excluded(relative / d)]
            result.extend(relative / name for name in names if not excluded(relative / name))
    return sorted(result)


def audit(paths):
    findings = []
    for relative in paths:
        name = relative.as_posix()
        path = ROOT / relative
        if name not in FILES and relative.parts[0] not in DIRECTORIES:
            findings.append((name, "outside public-source allowlist"))
        if excluded(relative):
            findings.append((name, "runtime/generated path included"))
        if path.is_symlink() or not path.is_file():
            findings.append((name, "missing or symbolic-link source"))
            continue
        if path.suffix in {".sqlite", ".sqlite3", ".db", ".dump", ".pem", ".key", ".pdf", ".p12", ".mobileprovision"} or path.name in {"access-key", "model-key", "service.env", ".env"} or path.name.endswith("-connection.json"):
            findings.append((name, "private data/credential filename"))
        if path.stat().st_size > 5 * 1024 * 1024:
            findings.append((name, "source file exceeds 5 MiB; inspect before publishing"))
        content = path.read_bytes()
        if b"\0" in content[:8192]:
            continue
        for label, pattern in SECRET_PATTERNS.items():
            # Container paths use an intentionally generic service account.
            candidate = content.replace(b"/home/papernas/", b"/service-account/")
            if pattern.search(candidate):
                findings.append((name, label))
    return findings
