# Preparing a release

The source repository and release artifacts must contain only public software. Production data, service configuration, credentials, original migration logs, screenshots of private research, and runtime environments are excluded.

Use the project’s Python 3.12+ environment for packaging; the macOS system `python3` may be older.

1. Update the backend package version, API health/version, frontend package version, and Mac Info.plist version/build together. Keep the changelog truthful about implemented capabilities.
2. Run backend tests with PostgreSQL, frontend tests, Swift tests, and a Mac release build. Check both web themes, desktop/mobile, login, reader, research editing, tasks, and settings. Document skipped/unavailable verification.
3. Review `git status` and stage only intended source. Run `python3 scripts/audit-public.py`. This detects common credentials, private paths, runtime files, and oversized artifacts; it is not a substitute for reviewing new binary assets and changes.
4. Confirm the license choice and retain third-party notices. PyMuPDF is used under its AGPL option. Do not claim that research materials or downloaded models are covered by the software license.
5. Run `backend/.venv/bin/python scripts/package-source.py` and `backend/.venv/bin/python backend/scripts/build_web.py`. The archive includes only audited source and is copied into the package for `/source`.
6. Build a wheel with `backend/.venv/bin/python -m pip wheel --no-deps ./backend --wheel-dir dist`. Inspect its file list for migrations, browser assets, notices, and corresponding source.
7. Build the Mac app. Distribute the matching source archive beside a binary release. Developer ID signing, notarization, and clean-machine verification are required before describing a build as notarized. The local ad-hoc build is for development.
8. Create the GitHub repository with an explicit owner/name and intended visibility. Enable private vulnerability reporting, review CI permissions, and push the reviewed commit. Tag only a commit that passed the intended release checks.

The workflow does not automatically publish a repository, tag, release, container, or package. GitHub CI is defined but only a completed remote run can verify GitHub runner behavior.

Source packaging writes an archive, SHA-256 file, and per-file manifest to ignored `dist/`. It also refreshes the ignored corresponding-source copy in the backend package. Regenerate after any code changes so deployed source matches the running software.

For an exported checkout without `.git`, `--from-checkout` uses the same strict source-directory allowlist. Docker builds use that mode because Git metadata is excluded from their build context.
