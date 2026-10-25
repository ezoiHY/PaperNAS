# Browser client

The working API v2 frontend is served at `/app/` by FastAPI. There is no development proxy, separate frontend server, CDN, package installation, or bundler.

Start the API and worker using the root README and open `http://127.0.0.1:8788/app/`. Enter the access key to register a device. Credentials are held in memory and `sessionStorage` for that tab; access keys and provider keys are not stored. Signing out revokes that device. Browser storage is not equivalent to Keychain; use a trusted browser profile and HTTPS for network access.

- `src/app.js`: navigation, library, reader, imports, figures, notes, tasks, settings.
- `src/research.js`: questions, evidence, judgments, plans, results, snapshots, comparisons, exports.
- `src/api.js`: authenticated same-origin requests, error handling, safe paths, mutation identities.
- `src/ui.js`: semantic DOM helpers, safe text rendering, forms and dialogs.
- `style.css`: responsive light/dark layout based on the accepted Focus library design.

Paper/model text is inserted as text; imported HTML is never executed. The server sets CSP and disables application framing. Resource URLs must stay inside the API namespace; credentials are not sent to external links or redirects.

Original PDF pages are rendered on the server for consistent browser support. Page controls navigate and explicitly save shared reading positions; original PDFs remain downloadable. Notes use an explicit page and optional pasted quotation. The native app provides selection rectangles and more complete math rendering. Markdown is rendered conservatively as text and headings in the browser; export retains the original Markdown.

## Checks

```sh
node --test frontend/tests/*.test.js
node --check frontend/src/app.js
node --check frontend/src/research.js
```

Node 22+ is for tests only. Browser QA covers both themes, mobile and desktop layouts, login/logout, filters, PDFs/figures, notes, research editing, tasks, and settings against a disposable database.

`backend/scripts/build_web.py` copies production files into the Python package. That generated copy is ignored by Git; this directory is the source of truth.
