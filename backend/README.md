# Paper NAS backend

FastAPI + PostgreSQL + Procrastinate, with immutable content-addressed files. API and workers share one codebase and database. The current service does not require the legacy processing engine.

See the [quick start](../README.md#quick-start) and [deployment guide](../docs/DEPLOYMENT.md).

## Existing PostgreSQL

Create a dedicated database and account. The application needs schema, table, function, and trigger creation within its database, but not cluster superuser access. PostgreSQL 18 is the tested major version.

From `backend/`:

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -e '.[test]'
export PAPERNAS_V2_DATABASE_URL='postgresql://papernas:CHANGE_ME@127.0.0.1:5432/papernas'
export PAPERNAS_V2_STATE='/absolute/private/path/papernas-state'
.venv/bin/papernas-v2 init
.venv/bin/papernas-v2 show-access-key
.venv/bin/papernas-v2 api
```

Run a worker in another process with the same environment:

```sh
.venv/bin/papernas-v2 worker --queues io,parse,model --concurrency 2
```

The API defaults to `127.0.0.1:8788`. `/health` reports API version and worker count. `/app/` serves the browser client from the same origin, without CORS. The API alone does not execute jobs.

For a small CPU-only server, use one `io,model` worker with concurrency 2 and one `parse` worker with concurrency 1. Workers run maintenance; database locks protect scheduling.

## Configuration

| Variable | Default / purpose |
| --- | --- |
| `PAPERNAS_V2_DATABASE_URL` | Required PostgreSQL URI |
| `PAPERNAS_V2_STATE` | `~/.local/share/papernas-v2`; private objects and keys |
| `PAPERNAS_V2_HOST` / `PAPERNAS_V2_PORT` | `127.0.0.1` / `8788` |
| `PAPERNAS_V2_MAX_DOWNLOAD_BYTES` | 80 MiB |
| `PAPERNAS_V2_NETWORK_TIMEOUT` | 45 seconds |
| `PAPERNAS_V2_PARSE_TIMEOUT` | 240 seconds |
| `PAPERNAS_V2_MODEL_TIMEOUT` | 120 seconds |
| `PAPERNAS_V2_DOCLING` | `1`; `0` selects embedded-text fallback |
| `PAPERNAS_V2_ALLOW_PRIVATE_HOSTS` | Empty; explicit comma-separated private source hosts |
| `PAPERNAS_V2_WORKER_STALE_SECONDS` | 90 seconds |
| `PAPERNAS_V2_WEB_ROOT` | Optional frontend directory; source checkout or packaged assets by default |

`constraints-macos-arm64.txt` and `constraints-linux-x86_64.txt` preserve tested 0.4 runtime dependencies. They are not universal locks. The Linux layout snapshot uses CPU PyTorch: install the pinned torch/torchvision from the PyTorch CPU index before installing the layout extra with that constraint file. The lightweight container default omits Docling.

## Models and recovery

Configure a provider base URL, model name, output limit, and API key through either client. Providers must implement Chat Completions with JSON output. Keys are private files and never returned by configuration reads.

Model calls reserve tokens before sending. Persisted responses are reused during validation retry. Interrupted calls with unknown outcomes require reconciliation against provider usage; they are not blindly sent again. Truncated responses are preserved. Adjust output limits and explicitly start a new analysis if needed.

Discovery is bounded per source and retains provenance. It collects candidates without automatic analysis and does not promise complete source coverage.

Optional Docling weights are downloaded separately under upstream terms. Prewarm the model cache for offline deployments. Failure or timeout falls back to embedded text. OCR is disabled.

## Tests and packaging

```sh
.venv/bin/pytest -q
.venv/bin/ruff check papernas_v2 tests scripts
```

Set `PAPERNAS_V2_TEST_ADMIN_URL` to a disposable cluster with database creation permission. Otherwise tests use the project-local cluster. Each test creates and drops `papernas_test_<uuid>` and uses synthetic data and local model responses.

Before a wheel build, run `python3 scripts/package-source.py` and `python3 backend/scripts/build_web.py` from the repository root. Wheels include migrations, web files, notices, and audited corresponding source. Source checkouts serve `frontend/` directly.

## Migration and backups

Applied migration files are protected by SHA-256. Add a numbered migration instead of editing an applied one.

`python -m papernas_v2.legacy --help` imports frozen v1 output and native SQLite into an empty v2 database. `scripts/verify_legacy.py` verifies records and asset hashes without rerunning paid analyses. Missing legacy PDF page anchors remain unknown. Trial-import and restore backups independently before changing a running service.

Back up the database **and the entire state directory** with writers stopped. Restore both and verify asset hashes. See [backup and restore](../docs/DEPLOYMENT.md#backup-and-restore). `scripts/backup_nas.sh` supports an older custom directory layout; it is not a generic installer.
