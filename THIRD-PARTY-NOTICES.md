# Third-party notices

Paper NAS is licensed under AGPL-3.0-only. Dependencies retain their own licenses. This file does not relicense third-party code, fonts, documents, or model weights.

## Vendored Mac assets

**KaTeX 0.19.0 — MIT.** Unmodified JavaScript, CSS, fonts, and the complete upstream license are in `macOS/Sources/PaperNAS/Resources/katex/`. `VENDORED.json` records the source archive and SHA-256. [Upstream KaTeX](https://github.com/KaTeX/KaTeX).

## Backend components

| Component | License / notice |
| --- | --- |
| PyMuPDF / MuPDF | AGPL-3.0 or a separate Artifex commercial license; this project uses the open-source option. [Official licensing](https://pymupdf.readthedocs.io/en/latest/about.html) |
| FastAPI, Pydantic, Procrastinate, Beautiful Soup, pgvector Python | MIT |
| Uvicorn, HTTPX, lxml | BSD-3-Clause; XML libraries carry additional notices |
| Psycopg | LGPL-3.0; unmodified dependency, binary wheels include their own notices |
| python-multipart | Apache-2.0 |
| defusedxml | Python Software Foundation license |
| Pillow | MIT-CMU and historical PIL notices |
| NumPy | BSD-3-Clause and bundled component notices |
| Docling (optional) | MIT software; model weights have separate terms |
| PostgreSQL | PostgreSQL License; an external service |

This is a summary of direct dependencies and major optional components, not a replacement for installed packages' complete notices. The source archive does not redistribute PyTorch, Docling weights, browser binaries, Apple frameworks, or PostgreSQL. Container/wheel distributors must retain dependency notices and check model terms before redistributing weights.

## First-party browser assets

The browser client uses system fonts, first-party CSS/JavaScript, and simple first-party SVG drawings. It does not vendor an icon library or fetch assets from CDNs.

## Research materials

Software licensing grants no rights to papers, figures, provider responses, or imported datasets. These are not bundled in releases. Documentation screenshots must use clearly labeled synthetic data or material that can be redistributed.
