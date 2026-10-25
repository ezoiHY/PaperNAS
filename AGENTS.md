# Paper NAS

This repository is the Paper NAS research workspace, not the owner's personal website. Maintain the API v2 backend, buildless browser client, and SwiftUI Mac client as one product.

- Never commit private configuration, credentials, connection files, research documents, databases, model outputs, runtime caches, backups, or personal deployment records. Use `scripts/audit-public.py` and the source packaging allowlist.
- `backend/`, `frontend/`, and `macOS/` are current. `legacy/` is frozen migration-era source; it requires an external engine and is not a fresh-install path.
- Use `frontend/` as the web source of truth. Generated `backend/papernas_v2/web/` and `source/` directories are ignored. Serve web and API on the same origin; do not enable broad CORS.
- Treat imported text, model output, PDFs, and SVG as untrusted. Do not inject source HTML into the DOM or forward credentials to an external asset origin.
- Preserve exact source quotations and immutable evidence anchors. Do not invent metadata, figures, citations, experimental results, or capabilities.
- Keep the accepted visual language in `design-system/MASTER.md` and `design-system/WEB.md`. Test desktop/mobile, both themes, visible focus, and forms after UI changes.
- Add migrations rather than editing applied SQL. Preserve transactional task enqueueing, revisions, idempotency, stage fencing, and unknown-model-call handling.
- Never run tests against production. Backend tests need a disposable PostgreSQL cluster; model tests use local synthetic providers. Live paid model calls require explicit scope.
- Validate with Python tests/Ruff, frontend Node tests, and Swift tests as appropriate. Build the Mac app after native changes. Document any skipped or unavailable verification.
- Release source is AGPL-3.0-only; preserve third-party notices, corresponding-source offers, and public feature limits. Do not imply that an ad-hoc Mac build is notarized.
