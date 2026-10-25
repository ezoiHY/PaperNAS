# Contributing

Start with the root README and [architecture](docs/ARCHITECTURE.md). Use a local checkout, disposable PostgreSQL database, and synthetic papers. Never attach personal research data or credentials to issues or pull requests.

Keep changes focused. Explain the user-visible behavior, relevant tradeoffs, and verification. Include screenshots for UI changes using synthetic data. Browser controls should remain keyboard accessible, work in light/dark appearance, and fit a narrow mobile viewport.

Run the tests appropriate to your change:

```sh
backend/.venv/bin/pytest -q backend/tests
backend/.venv/bin/ruff check backend/papernas_v2 backend/tests backend/scripts
node --test frontend/tests/*.test.js
bash scripts/test-mac.sh
python3 scripts/audit-public.py
```

Database tests need a disposable admin URL or the local development cluster. A run with skipped database tests does not verify the persistence workflow. Paid model services and production installations are not needed for normal contributions.

Use numbered migrations for schema changes. Preserve backward compatibility with the current Mac client or document the version transition. Write frontend source in `frontend/`, then regenerate packaged assets for a release.

By submitting a contribution, you agree to license it under the repository's AGPL-3.0-only license. Retain upstream notices when adding third-party code, and document the origin/version/license of vendored assets. Generated examples must be labeled synthetic; source figures are evidence, not decoration.
