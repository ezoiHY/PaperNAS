from fastapi.testclient import TestClient

from papernas_v2.api import create_app


def test_web_shell_is_public_but_research_data_is_private(settings):
    with TestClient(create_app(settings)) as client:
        response = client.get("/app/")
        assert response.status_code == 200
        assert "Paper NAS" in response.text
        assert "frame-ancestors 'none'" in response.headers["content-security-policy"]
        assert response.headers["x-content-type-options"] == "nosniff"
        assert client.get("/api/v2/works").status_code == 401
        assert client.get("/api/v2/settings/model").status_code == 401
        assert client.get("/").url.path == "/app/"
        for path in ("/app/src/app.js", "/app/src/research.js", "/app/style.css"):
            assert client.get(path).status_code == 200
        assert client.get("/app/%2e%2e/pyproject.toml").status_code == 404
        assert client.get("/app/.runtime/connection.json").status_code == 404


def test_web_does_not_enable_cross_origin_credentials(settings):
    with TestClient(create_app(settings)) as client:
        response = client.options(
            "/api/v2/works",
            headers={"Origin": "https://unrelated.example", "Access-Control-Request-Method": "GET"},
        )
        assert "access-control-allow-origin" not in response.headers


def test_api_still_runs_when_web_files_are_not_installed(settings, tmp_path, monkeypatch):
    monkeypatch.setenv("PAPERNAS_V2_WEB_ROOT", str(tmp_path / "missing"))
    with TestClient(create_app(settings)) as client:
        assert client.get("/health").json()["api_version"] == 2
        assert client.get("/app/").status_code == 404


def test_browser_pdf_pages_are_authenticated_and_version_scoped(client, settings, pdf_bytes):
    import uuid

    result = client.post(
        "/api/v2/imports/pdf",
        files={"file": ("example.pdf", pdf_bytes, "application/pdf")},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert result.status_code == 202
    identifier = result.json()["work_id"]
    info = client.get(f"/api/v2/works/{identifier}/pdf/info").json()
    url = f"/api/v2/works/{identifier}/pdf/pages/1?version_id={info['version_id']}"
    response = client.get(url)
    assert response.status_code == 200
    assert response.content.startswith(b"\x89PNG")
    assert response.headers["x-pdf-page-count"] == "2"
    assert response.headers["x-pdf-sha256"] == info["sha256"]
    assert client.get(f"/api/v2/works/{identifier}/pdf/pages/3").status_code == 400
    assert client.get(f"/api/v2/works/{identifier}/pdf/pages/1?version_id=unrelated").status_code == 404
    with TestClient(create_app(settings)) as anonymous:
        assert anonymous.get(url).status_code == 401


def test_library_search_includes_authors(client, settings):
    from papernas_v2.runtime import Runtime
    from papernas_v2.sources import upsert_work

    with Runtime(settings).db.connect() as conn:
        identifier, _ = upsert_work(
            conn,
            {
                "source": "local",
                "identifier": "synthetic-author-search",
                "version": "test",
                "title": "A synthetic paper",
                "authors": ["Aster Example"],
                "url": "",
            },
        )
    result = client.get("/api/v2/works?q=Aster").json()
    assert [work["id"] for work in result["works"]] == [identifier]
