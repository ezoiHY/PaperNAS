# Legacy v1 adapter

The v1 native API adapter and maintenance scripts are retained as historical source. Do not use them for a fresh installation.

`server/` requires a separately available `research-digest` engine and HTTP API. That old engine and its web UI are not part of this repository. Current `backend/`, `frontend/`, and `macOS/` run independently of it.

`scripts/install-server.sh`, `verify-live.py`, and `repair-svg-figures.py` describe the old service layout. Current migration starts with `python -m papernas_v2.legacy --help`.

Legacy tests use synthetic data. Tests requiring the external engine are opt-in with `PAPER_NAS_ENGINE_SOURCE`. Private deployment logs and research data are excluded.
