"""Serve the buildless web client from the same origin as the authenticated API."""

from __future__ import annotations

import os
from pathlib import Path

from fastapi.responses import FileResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; "
        "img-src 'self' blob: data:; font-src 'self'; connect-src 'self'; "
        "frame-src blob:; object-src 'none'; base-uri 'none'; "
        "form-action 'self'; frame-ancestors 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "Cache-Control": "no-cache",
}


class WebFiles(StaticFiles):
    async def get_response(self, path, scope):
        response = await super().get_response(path, scope)
        response.headers.update(SECURITY_HEADERS)
        return response


def install_web(app):
    package = Path(__file__).resolve().parent
    source = package.parents[1] / "frontend"
    configured = os.environ.get("PAPERNAS_V2_WEB_ROOT")
    root = Path(configured).resolve() if configured else source if source.is_dir() else package / "web"
    if not (root / "index.html").is_file():
        return

    @app.get("/", include_in_schema=False)
    def home():
        return RedirectResponse("/app/", status_code=307)

    # A release's source archive is generated from an audited allowlist. This
    # endpoint must never construct an archive from arbitrary runtime directories.
    archive = package / "source" / "paper-nas-source.tar.gz"
    if archive.is_file():

        @app.get("/source", include_in_schema=False)
        def corresponding_source():
            return FileResponse(
                archive,
                media_type="application/gzip",
                filename="paper-nas-source.tar.gz",
                headers={"X-Content-Type-Options": "nosniff"},
            )

    app.mount("/app", WebFiles(directory=root, html=True), name="web")
