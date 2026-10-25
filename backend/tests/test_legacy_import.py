import hashlib
import io
import json
import sqlite3

import pytest
from PIL import Image

from papernas_v2.legacy import import_snapshot
from papernas_v2.runtime import Runtime


def make_snapshot(root, pdf_bytes):
    output = root / "output"
    output.mkdir(parents=True)
    (output / "reports").mkdir()
    with sqlite3.connect(output / "state.sqlite3") as db:
        db.executescript("""
        CREATE TABLE papers(identity TEXT,metadata TEXT,paper_key TEXT,document_path TEXT,report_path TEXT,
          first_seen TEXT,last_seen TEXT,added_at TEXT,collection TEXT,workspace_revision INTEGER,enrichment TEXT,cover_figure_id TEXT);
        CREATE TABLE workspace_groups(id TEXT,name TEXT,revision INTEGER,created_at TEXT);
        CREATE TABLE paper_groups(paper_identity TEXT,group_id TEXT);
        CREATE TABLE paper_notes(id TEXT,paper_identity TEXT,pdf_sha256 TEXT,page INTEGER,selected_text TEXT,rects TEXT,body TEXT,
          revision INTEGER,created_at TEXT,updated_at TEXT,prefix TEXT,suffix TEXT);
        """)
        for key in ["first", "second"]:
            directory = output / "papers" / key
            directory.mkdir(parents=True)
            (directory / "source.pdf").write_bytes(pdf_bytes)
            stream = io.BytesIO()
            Image.new("RGB", (200, 100), "white").save(stream, "PNG")
            (directory / "figure.png").write_bytes(stream.getvalue())
            document = {
                "parser": "arxiv_html",
                "blocks": [{"id": "shared-block", "text": "Original evidence.", "page": None}],
                "figures": [
                    {
                        "id": f"f{i}",
                        "label": "Figure 2",
                        "caption": "Two panels",
                        "page": None,
                        "asset_path": f"/old/output/papers/{key}/figure.png",
                        "mime_type": "image/png",
                    }
                    for i in [1, 2]
                ],
            }
            report = {
                "findings": {
                    "overview": [{"text": "A claim", "evidence_ids": ["e1"], "figure_ids": ["f1"]}],
                    "evidence": [{"id": "e1", "block_id": "shared-block", "quote": "Original evidence."}],
                },
                "generated_at": "2026-10-22T12:00:00Z",
            }
            (directory / "document.json").write_text(json.dumps(document))
            (directory / "brief.json").write_text(
                json.dumps({"summary": "Brief preserved", "findings": report["findings"]})
            )
            (output / "reports" / f"{key}.json").write_text(json.dumps(report))
            (output / "reports" / f"{key}.md").write_text("## Full report\nOriginal export.")
            db.execute(
                "INSERT INTO papers VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    f"arxiv:{key}",
                    json.dumps({"title": key, "source": "arxiv", "arxiv_id": key}),
                    key,
                    f"/old/output/papers/{key}/document.json",
                    f"/old/output/reports/{key}.json",
                    "2026-10-20T00:00:00Z",
                    "2026-10-22T00:00:00Z",
                    None,
                    "library" if key == "first" else "candidates",
                    4,
                    json.dumps({"score": 92, "summary": "Saved summary"}),
                    "f2",
                ),
            )
        db.execute("INSERT INTO workspace_groups VALUES('group','EMG',2,'2026-10-20T00:00:00Z')")
        db.execute("INSERT INTO paper_groups VALUES('arxiv:first','group')")
        db.execute(
            "INSERT INTO paper_notes VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                "note",
                "arxiv:first",
                hashlib.sha256(pdf_bytes).hexdigest(),
                2,
                "Quoted text",
                "[]",
                "Keep this note",
                3,
                "2026-10-20T00:00:00Z",
                "2026-10-21T00:00:00Z",
                "before",
                "after",
            ),
        )
    native = root / "native.sqlite3"
    with sqlite3.connect(native) as db:
        db.executescript("""CREATE TABLE devices(id TEXT,name TEXT,token_hash TEXT,created REAL,expires REAL);
        CREATE TABLE reading(paper TEXT,pdf_sha256 TEXT,page INTEGER,section TEXT,revision INTEGER,updated REAL,device TEXT);
        INSERT INTO devices VALUES('old-device','Existing Mac','hash',1750000000,1850000000);""")
        db.execute(
            "INSERT INTO reading VALUES(?,?,?,?,?,?,?)",
            ("first", hashlib.sha256(pdf_bytes).hexdigest(), 2, "pdf", 7, 1750000000, "old-device"),
        )
    return output, native


def test_legacy_import_keeps_content_anchors_and_is_idempotent(client, settings, tmp_path, pdf_bytes):
    output, native = make_snapshot(tmp_path / "snapshot", pdf_bytes)
    runtime = Runtime(settings)
    from pathlib import Path

    counts = import_snapshot(runtime, output, native, Path("/old/output"))
    assert counts["works"] == counts["pdfs"] == counts["reports"] == counts["briefs"] == 2
    assert counts["figures"] == 4 and counts["notes"] == 1
    first = client.get("/api/v2/works/first").json()
    second = client.get("/api/v2/works/second").json()
    assert first["has_report"] and first["has_brief"]
    assert first["summary"] == "Saved summary"
    assert first["brief"]["summary"] == "Brief preserved"
    assert first["markdown"] == "## Full report\nOriginal export."
    block = first["document"]["blocks"][0]
    assert block["page"] is None and block["text"] == "Original evidence."
    assert block["id"] != second["document"]["blocks"][0]["id"]
    assert first["report"]["findings"]["evidence"][0]["block_id"] == block["id"]
    assert len({f["label"] for f in first["document"]["figures"]}) == 2
    assert first["cover_figure_id"] == first["document"]["figures"][1]["id"]
    note = client.get("/api/v2/works/first/notes").json()["notes"][0]
    assert note["body"] == "Keep this note" and note["page"] == 2 and note["pdf_current"]
    assert note["prefix"] == "before" and note["suffix"] == "after" and note["revision"] == 3
    assert client.get("/api/v2/works/first/reading-state").json()["reading"]["revision"] == 7
    for fig in first["document"]["figures"]:
        assert client.get(fig["asset_url"]).content.startswith(b"\x89PNG")
        assert client.get(f"/api/v2/figures/{fig['id']}/page-preview").json()["title"] == "page_required"
    assert import_snapshot(runtime, output, native, Path("/old/output"))["already_imported"]
    assert client.get("/api/v2/papers").json()["total"] == 2


def test_missing_legacy_asset_aborts_entire_import(settings, tmp_path, pdf_bytes):
    from pathlib import Path

    output, native = make_snapshot(tmp_path / "snapshot", pdf_bytes)
    (output / "papers/second/figure.png").unlink()
    runtime = Runtime(settings)
    with pytest.raises(ValueError, match="missing an expected asset"):
        import_snapshot(runtime, output, native, Path("/old/output"))
    with runtime.db.connect() as conn:
        assert conn.execute("SELECT count(*) AS n FROM works").fetchone()["n"] == 0
        assert conn.execute("SELECT count(*) AS n FROM legacy_imports").fetchone()["n"] == 0


def test_migrated_gallery_and_default_cover_use_page_then_natural_label_order(
    client, settings, tmp_path, pdf_bytes
):
    from pathlib import Path

    output, native = make_snapshot(tmp_path / "snapshot", pdf_bytes)
    # Deliberately shuffled HTML labels exercise numeric order, letter suffixes,
    # and multi-image suffixes rather than relying on insertion or SQL order.
    unknown_pages = [
        ("f10", "Figure 10:"),
        ("panel10", "Figure 2: · image 10/12"),
        ("f2b", "Figure 2b:"),
        ("f2", "Figure 2:"),
        ("f02", "Figure 02:"),
        ("panel2", "Figure 2: · image 2/12"),
        ("f1", "Figure 1:"),
        ("f2a", "Figure 2a:"),
        ("panel1", "Figure 2: · image 1/12"),
    ]
    expected_unknown = [
        "Figure 1:",
        "Figure 02:",
        "Figure 2:",
        "Figure 2: · image 1/12",
        "Figure 2: · image 2/12",
        "Figure 2: · image 10/12",
        "Figure 2a:",
        "Figure 2b:",
        "Figure 10:",
    ]
    for key in ["first", "second"]:
        path = output / "papers" / key / "document.json"
        document = json.loads(path.read_text())
        template = document["figures"][0]
        document["figures"] = [
            {**template, "id": identifier, "label": label, "page": None}
            for identifier, label in unknown_pages
        ]
        if key == "second":
            document["figures"] += [
                {**template, "id": "page2", "label": "Figure 20:", "page": 2},
                {**template, "id": "page1f12", "label": "Figure 12:", "page": 1},
                {**template, "id": "page1f3", "label": "Figure 3:", "page": 1},
            ]
        path.write_text(json.dumps(document))
    with sqlite3.connect(output / "state.sqlite3") as db:
        db.execute("UPDATE papers SET cover_figure_id=NULL")
    runtime = Runtime(settings)
    import_snapshot(runtime, output, native, Path("/old/output"))

    first = client.get("/api/v2/works/first").json()
    second = client.get("/api/v2/works/second").json()
    assert [f["label"] for f in first["document"]["figures"]] == expected_unknown
    assert first["cover_label"] == "Figure 1:"
    assert [f["label"] for f in second["document"]["figures"]] == [
        "Figure 3:",
        "Figure 12:",
        "Figure 20:",
        *expected_unknown,
    ]
    assert second["cover_label"] == "Figure 3:"


@pytest.mark.parametrize(
    ("scenario", "expected_attention"),
    [
        ("healthy", False),
        ("brief_only", False),
        ("unread", True),
        ("missing_structure", True),
        ("failed", True),
        ("page_fallback", True),
        ("stale", True),
    ],
)
def test_attention_filter_matches_list_and_detail_materials(
    client, settings, tmp_path, pdf_bytes, scenario, expected_attention
):
    from pathlib import Path

    output, native = make_snapshot(tmp_path / "snapshot", pdf_bytes)
    runtime = Runtime(settings)
    import_snapshot(runtime, output, native, Path("/old/output"))
    with runtime.db.connect() as conn:
        work = conn.execute("SELECT * FROM works WHERE id='first'").fetchone()
        document_id = work["current_document_id"]
        if scenario in {"brief_only", "unread", "missing_structure"}:
            conn.execute("UPDATE works SET current_analysis_id=NULL WHERE id='first'")
        if scenario == "unread":
            conn.execute("UPDATE legacy_records SET brief=NULL WHERE work_id='first'")
        if scenario == "missing_structure":
            conn.execute("UPDATE works SET current_document_id=NULL WHERE id='first'")
        if scenario in {"failed", "page_fallback"}:
            conn.execute("UPDATE figures SET status=%s WHERE document_id=%s", (scenario, document_id))
        if scenario == "stale":
            conn.execute(
                """INSERT INTO documents(id,version_id,input_hash,parser,parser_version,structure_quality,artifact_sha)
                SELECT id || '-reparsed',version_id,'reparsed',parser,parser_version,structure_quality,artifact_sha
                FROM documents WHERE id=%s""",
                (document_id,),
            )
            conn.execute(
                "UPDATE works SET current_document_id=%s WHERE id='first'", (document_id + "-reparsed",)
            )

    listed = next(p for p in client.get("/api/v2/papers").json()["papers"] if p["key"] == "first")
    detail = client.get("/api/v2/papers/first").json()
    filtered = client.get("/api/v2/papers", params={"status": "attention"}).json()["papers"]
    assert {p["key"] for p in filtered} == ({"first"} if expected_attention else set())
    assert "document" not in listed
    for key in ("has_report", "has_brief", "report_stale"):
        assert listed[key] == detail[key]
    expected_counts = dict.fromkeys(("ready", "page_fallback", "pending", "failed"), 0)
    if scenario not in {"missing_structure", "stale"}:
        expected_counts[scenario if scenario in {"failed", "page_fallback"} else "ready"] = 2
    assert listed["materials"]["figures"] == detail["materials"]["figures"] == expected_counts
    for value in (listed, detail):
        assert (value["materials"]["structure"] == "missing") == (scenario == "missing_structure")
        assert value["report_stale"] == (scenario == "stale")
        assert (not value["has_report"] and not value["has_brief"]) == (scenario == "unread")


@pytest.mark.parametrize("image_kind", ["jpeg", "svg"])
def test_legacy_figure_download_preserves_original_bytes_and_png_display(
    client, settings, tmp_path, pdf_bytes, image_kind
):
    from pathlib import Path

    output, native = make_snapshot(tmp_path / "snapshot", pdf_bytes)
    if image_kind == "jpeg":
        stream = io.BytesIO()
        Image.new("RGB", (200, 100), "navy").save(stream, "JPEG", quality=90)
        original = stream.getvalue()
        mime = "image/jpeg"
    else:
        original = b'<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="navy"/></svg>'
        mime = "image/svg+xml"
    directory = output / "papers" / "first"
    (directory / ("original." + image_kind)).write_bytes(original)
    path = directory / "document.json"
    document = json.loads(path.read_text())
    document["figures"][0].update(
        asset_path=f"/old/output/papers/first/original.{image_kind}", mime_type=mime
    )
    path.write_text(json.dumps(document))
    runtime = Runtime(settings)
    import_snapshot(runtime, output, native, Path("/old/output"))
    original_sha = hashlib.sha256(original).hexdigest()
    figure = next(
        f
        for f in client.get("/api/v2/works/first").json()["document"]["figures"]
        if f["provenance"]["original_asset"] == original_sha
    )
    assert figure["mime_type"] == "image/png"
    assert figure["asset_url"] == figure["original_url"]
    assert figure["original_download_url"] != figure["asset_url"]
    assert figure["original_mime_type"] == mime
    exported = client.get(figure["original_download_url"])
    assert exported.content == original
    # SVG remains a download attachment; its saved MIME supplies the filename.
    assert exported.headers["content-type"].split(";")[0] == (
        "application/octet-stream" if image_kind == "svg" else mime
    )
    assert client.get(figure["asset_url"]).content.startswith(b"\x89PNG")

    # Native PDF figures have no separate legacy original, so exports use the PNG.
    with runtime.db.connect() as conn:
        conn.execute("UPDATE figures SET provenance='{}' WHERE id=%s", (figure["id"],))
    current = next(
        f for f in client.get("/api/v2/works/first").json()["document"]["figures"] if f["id"] == figure["id"]
    )
    assert current["original_download_url"] == current["asset_url"]
    assert current["original_mime_type"] == "image/png"
