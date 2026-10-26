# Verification for 0.5.0

Local checks were completed on 2026-10-25 with synthetic data. Publication screenshots were captured on 2026-10-26 from a separate disposable workspace. This records the checks actually performed; it does not imply production certification.

| Area | Result |
| --- | --- |
| Current backend | 53 tests passed against disposable PostgreSQL 18, including a repeat against the installed wheel with newly resolved dependencies; no production database used |
| Python lint and formatting | Ruff check and format check passed |
| Browser API client | 7 Node tests passed, including same-origin credentials, conflict errors, and explicit retry identities for JSON and PDF uploads |
| Browser JavaScript | All four ES modules passed Node syntax checks |
| Native client | 19 Swift test cases passed; 3 environment-dependent private-fixture/live-server cases were skipped (22 discovered) |
| Mac release build | Version 0.5.0, build 12, arm64; ad-hoc signature verified |
| Frozen legacy adapter | 32 tests passed, 5 optional external-engine tests skipped |
| Deployment files | Compose and CI YAML parsed; Docker was unavailable, so containers were not built or run |
| Release artifacts | Source archive and wheel file lists checked; installed wheel served the browser, licenses, and corresponding source; Mac ZIP version and bundled notices checked |
| GitHub Actions | Workflow prepared with pinned action revisions; remote execution pending publication |

## Browser walkthrough

The browser was connected to an isolated API instance with synthetic papers and a disposable database. The following workflows were exercised through visible controls:

- Device login and sign-out, library and group navigation, search, batch movement to candidates.
- PDF upload followed by successful worker parsing; page rendering, page navigation and reading-position persistence.
- Figure display, source-page crop preview, region repair and successful background completion.
- Notes tied to the original PDF, source-text quotation saved as research evidence.
- Research plans and linked results, judgment revision with earlier history preserved, understanding snapshots, and JSON download with all record types present.
- Task pause/resume and refreshed status; theme changes and discovery configuration saved with scheduling disabled.
- Desktop and 390-pixel mobile layouts in both themes. The document did not overflow horizontally; research tabs scroll within their own row.

Screenshots contain synthetic demonstration content only: [desktop research](images/web-research.jpg), [mobile research](images/web-mobile.jpg), and [mobile dark library](images/web-mobile-dark.jpg).

The [publication gallery](SCREENSHOTS.md) adds ten screenshots of the browser library in both themes, browser PDF and figure views, research evidence and plans, completed tasks, the native Mac library and reader, and the mobile library. These are captures of the running application with synthetic source PDFs. The gallery's figure region was corrected through the visible controls and processed successfully by the worker.

## Limits of this check

Paid model calls, live scholarly discovery, optional Docling model downloads, fresh-machine installation, Docker runtime behavior, Apple notarization, and GitHub runner execution were not tested in this preparation. Backend provider tests use synthetic local responses. The Mac build emitted existing Command Line Tools framework-search warnings; compilation and signature verification succeeded. Python tests reported dependency deprecation warnings.

Production services, private research materials, saved connection settings, and the installed Mac application were left unchanged. The public source excludes private state and previous personal deployment notes. Source files use AGPL-3.0-only with preserved third-party notices.
