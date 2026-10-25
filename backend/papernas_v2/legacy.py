"""Offline, atomic import of a frozen v1 snapshot; never modifies the source.

Run against a new database while both API and worker are stopped. All originals
remain in content-addressed storage and the separate v1 backup. No network or
model calls are made. Unknown HTML-to-PDF anchors remain unknown.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import sqlite3
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import pymupdf as fitz
from psycopg.types.json import Jsonb

from .cli import initialize
from .core import canonical, fingerprint
from .parsing import normalize_image
from .settings import Settings


def read_json(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


def remap(value, identifiers):
    if isinstance(value, str):
        return identifiers.get(value, value)
    if isinstance(value, list):
        return [remap(item, identifiers) for item in value]
    if isinstance(value, dict):
        return {key: remap(item, identifiers) for key, item in value.items()}
    return value


def legacy_id(kind, *parts):
    return "legacy-" + kind + "-" + fingerprint(parts)[:28]


def source_path(value, output, original_output):
    path = Path(value)
    if path.is_absolute():
        try:
            path = path.relative_to(original_output)
        except ValueError as error:
            raise ValueError(f"Legacy path is outside the source output: {path}") from error
    elif path.parts and path.parts[0] == "output":
        path = Path(*path.parts[1:])
    result = (output / path).resolve()
    if not result.is_relative_to(output.resolve()):
        raise ValueError("Legacy path escapes the snapshot")
    return result


def sqlite_rows(path, table):
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
        db.row_factory = sqlite3.Row
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
            return []
        return [dict(row) for row in db.execute(f'SELECT * FROM "{table}"')]


def import_snapshot(runtime, output: Path, native: Path, original_output: Path):
    output, native = output.resolve(), native.resolve()
    database = output / "state.sqlite3"
    tables = {
        name: sqlite_rows(database, name)
        for name in ["papers", "workspace_groups", "paper_groups", "paper_notes", "paper_views"]
    }
    native_tables = {name: sqlite_rows(native, name) for name in ["devices", "reading"]}
    # Include file hashes so an idempotent rerun cannot conceal changed artifacts.
    manifest = {
        "schema": "papernas.v1.snapshot",
        "tables": tables,
        "native": native_tables,
        "files": {
            str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
            for base in [output / "papers", output / "reports"]
            for p in sorted(base.rglob("*"))
            if p.is_file()
        },
    }
    snapshot = runtime.assets.put_json(manifest)
    counts = Counter()
    identities, views = {}, {r["identity"]: json.loads(r["entry"]) for r in tables["paper_views"]}
    with runtime.db.connect() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(72024004)")
        old = conn.execute(
            "SELECT counts FROM legacy_imports WHERE snapshot_sha=%s", (snapshot["sha256"],)
        ).fetchone()
        if old:
            return {**old["counts"], "already_imported": True}
        if conn.execute("SELECT count(*) AS n FROM works").fetchone()["n"]:
            raise ValueError("Legacy migration requires an empty target library; refusing to overwrite data")
        runtime.assets.register(conn, snapshot)
        operation = legacy_id("import", snapshot["sha256"])
        conn.execute(
            "INSERT INTO operations(id,kind,input,state,result) VALUES(%s,'legacy_import',%s,'succeeded',%s)",
            (operation, Jsonb({"snapshot_sha": snapshot["sha256"]}), Jsonb({"archived": True})),
        )

        def save_file(path, media=None):
            if not path.is_file():
                raise ValueError(f"Snapshot is missing an expected asset: {path}")
            asset = runtime.assets.put(
                path.read_bytes(), media or mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            )
            runtime.assets.register(conn, asset)
            return asset["sha256"]

        def save_json(value):
            asset = runtime.assets.put_json(value)
            runtime.assets.register(conn, asset)
            return asset["sha256"]

        for row in tables["papers"]:
            metadata = json.loads(row["metadata"])
            key = row.get("paper_key") or hashlib.sha256(row["identity"].encode()).hexdigest()[:20]
            identities[row["identity"]] = key
            directory = output / "papers" / key
            pdf_path = directory / "source.pdf"
            pdf_sha, pages = None, 0
            if pdf_path.exists():
                pdf_sha = save_file(pdf_path, "application/pdf")
                with fitz.open(pdf_path) as pdf:
                    pages = len(pdf)
                counts["pdfs"] += 1
            document = (
                json.loads(source_path(row["document_path"], output, original_output).read_text())
                if row.get("document_path")
                else None
            )
            report = (
                json.loads(source_path(row["report_path"], output, original_output).read_text())
                if row.get("report_path")
                else None
            )
            brief = read_json(directory / "brief.json")
            markdown_path = output / "reports" / (key + ".md")
            markdown = markdown_path.read_text() if markdown_path.exists() else ""
            original = {
                "row": row,
                "document": document,
                "report": report,
                "brief": brief,
                "markdown": markdown,
                "list_entry": views.get(row["identity"], {}),
            }
            original_sha = save_json(original)
            version_id = legacy_id("version", key, pdf_sha or row["identity"])
            document_id = legacy_id("document", key, fingerprint(document)) if document else None
            enrichment = json.loads(row.get("enrichment") or "{}")
            conn.execute(
                """INSERT INTO works(id,title,authors,abstract,source,source_url,published_at,venue,
                collection,revision,enrichment,created_at,updated_at) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (
                    key,
                    metadata["title"],
                    Jsonb(metadata.get("authors") or []),
                    metadata.get("abstract") or "",
                    metadata.get("source") or "local",
                    metadata.get("url") or "",
                    metadata.get("published_at") or "",
                    metadata.get("venue") or "",
                    row.get("collection", "candidates"),
                    row.get("workspace_revision", 1),
                    Jsonb(enrichment),
                    row.get("added_at") or row["first_seen"],
                    row["last_seen"],
                ),
            )
            html_sha = None
            if document and document.get("material_path"):
                material = source_path(document["material_path"], output, original_output)
                if material.suffix.lower() in {".html", ".htm"}:
                    html_sha = save_file(material, "text/html")
            conn.execute(
                "INSERT INTO work_versions(id,work_id,label,source_url,pdf_asset,html_asset,metadata) VALUES(%s,%s,%s,%s,%s,%s,%s)",
                (
                    version_id,
                    key,
                    metadata.get("version") or "legacy",
                    metadata.get("url") or "",
                    pdf_sha,
                    html_sha,
                    Jsonb(metadata),
                ),
            )
            external = metadata.get("arxiv_id") or metadata.get("doi") or metadata.get("source_id")
            if metadata.get("doi") and metadata.get("source") != "arxiv":
                external = metadata["doi"].lower()
            if external:
                conn.execute(
                    "INSERT INTO external_ids VALUES(%s,%s,%s) ON CONFLICT DO NOTHING",
                    (metadata.get("source") or "legacy", external, key),
                )
            identifiers = {}
            if document:
                for kind, items in [
                    ("block", document.get("blocks", [])),
                    ("figure", document.get("figures", [])),
                ]:
                    for item in items:
                        identifiers[item["id"]] = legacy_id(kind, key, item["id"])
                mapped = remap(document, identifiers)
                document_sha = save_json(mapped)
                warnings = list(document.get("warnings") or [])
                warnings.append(
                    "Migrated v1 extraction. Missing PDF page anchors remain unknown; original content is preserved."
                )
                conn.execute(
                    """INSERT INTO documents(id,version_id,input_hash,parser,parser_version,structure_quality,page_count,artifact_sha,warnings)
                    VALUES(%s,%s,%s,%s,'v1','legacy',%s,%s,%s)""",
                    (
                        document_id,
                        version_id,
                        fingerprint(document),
                        str(document.get("parser") or "legacy"),
                        pages,
                        document_sha,
                        Jsonb(warnings),
                    ),
                )
                for ordinal, block in enumerate(mapped.get("blocks", [])):
                    page = block.get("page")
                    page = page if isinstance(page, int) and 1 <= page <= pages else None
                    conn.execute(
                        "INSERT INTO blocks(id,document_id,ordinal,kind,page,text,bbox,heading) VALUES(%s,%s,%s,%s,%s,%s,%s,%s)",
                        (
                            block["id"],
                            document_id,
                            ordinal,
                            block.get("kind") or "paragraph",
                            page,
                            block.get("text") or "",
                            Jsonb(block.get("bbox") or {}),
                            block.get("section") or block.get("heading") or "",
                        ),
                    )
                    counts["blocks"] += 1
                labels = Counter(f.get("label") or f["id"] for f in mapped.get("figures", []))
                label_index = Counter()
                for figure in mapped.get("figures", []):
                    label = figure.get("label") or figure["id"]
                    label_index[label] += 1
                    shown_label = (
                        label if labels[label] == 1 else f"{label} image {label_index[label]}/{labels[label]}"
                    )
                    image_sha, original_image = None, None
                    if figure.get("asset_path"):
                        path = source_path(figure["asset_path"], output, original_output)
                        original_image = save_file(path, figure.get("mime_type"))
                        png, _ = normalize_image(path.read_bytes(), figure.get("mime_type") or "")
                        asset = runtime.assets.put(png, "image/png")
                        runtime.assets.register(conn, asset)
                        image_sha = asset["sha256"]
                    page = figure.get("page")
                    page = page if isinstance(page, int) and 1 <= page <= pages else None
                    provenance = {
                        "method": "legacy_source",
                        "url": figure.get("source_url") or "",
                        "original_asset": original_image,
                        "pdf_sha256": pdf_sha,
                        "original_label": label,
                        "anchor_verified": page is not None,
                    }
                    conn.execute(
                        """INSERT INTO figures(id,document_id,label,caption,page,bbox,status,asset_sha,provenance,error)
                        VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                        (
                            figure["id"],
                            document_id,
                            shown_label,
                            figure.get("caption") or "",
                            page,
                            Jsonb(figure.get("bbox") or {}),
                            "ready" if image_sha else "failed",
                            image_sha,
                            Jsonb(provenance),
                            "" if image_sha else "旧记录没有本地图像",
                        ),
                    )
                    counts["figures"] += 1
                counts["documents"] += 1
                if row.get("cover_figure_id") in identifiers:
                    enrichment["cover_figure_id"] = identifiers[row["cover_figure_id"]]
            analysis_id = None
            if report:
                analysis_id = legacy_id("analysis", key, fingerprint(report))
                mapped_report = remap(report, identifiers)
                mapped_report["markdown"] = markdown
                report_sha = save_json(mapped_report)
                conn.execute(
                    """INSERT INTO analyses(id,work_id,document_id,operation_id,kind,generation,input_hash,data,artifact_sha,created_at)
                    VALUES(%s,%s,%s,%s,'legacy_deep',0,%s,%s,%s,%s)""",
                    (
                        analysis_id,
                        key,
                        document_id,
                        operation,
                        fingerprint(report),
                        Jsonb(mapped_report),
                        report_sha,
                        report.get("generated_at") or row["last_seen"],
                    ),
                )
                counts["reports"] += 1
            view = views.get(row["identity"], {})
            summary = (
                enrichment.get("summary") or view.get("brief_summary") or view.get("report_summary") or ""
            )
            if not isinstance(summary, str):
                summary = ""
            conn.execute(
                "INSERT INTO legacy_records VALUES(%s,%s,%s,%s,%s,%s,%s,%s)",
                (
                    key,
                    row["identity"],
                    document_id,
                    original_sha,
                    Jsonb(remap(brief, identifiers)) if brief else None,
                    summary,
                    markdown,
                    Jsonb(view.get("bibliography") or {}),
                ),
            )
            if view.get("report_stale"):
                analysis_id = None
                counts["archived_stale_reports"] += 1
            conn.execute(
                "UPDATE works SET current_version_id=%s,current_document_id=%s,current_analysis_id=%s,enrichment=%s WHERE id=%s",
                (version_id, document_id, analysis_id, Jsonb(enrichment), key),
            )
            counts["briefs"] += bool(brief)
            counts[row.get("collection", "candidates")] += 1
            counts["works"] += 1

        for group in tables["workspace_groups"]:
            conn.execute(
                "INSERT INTO groups(id,name,revision,created_at) VALUES(%s,%s,%s,%s)",
                (group["id"], group["name"], group["revision"], group["created_at"]),
            )
            counts["groups"] += 1
        for membership in tables["paper_groups"]:
            conn.execute(
                "INSERT INTO group_works VALUES(%s,%s)",
                (membership["group_id"], identities[membership["paper_identity"]]),
            )
            counts["memberships"] += 1
        for note in tables["paper_notes"]:
            conn.execute(
                """INSERT INTO notes(id,work_id,pdf_sha256,page,selected_text,rects,body,revision,created_at,updated_at,prefix,suffix)
                VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (
                    note["id"],
                    identities[note["paper_identity"]],
                    note["pdf_sha256"],
                    note["page"],
                    note["selected_text"],
                    Jsonb(json.loads(note["rects"])),
                    note["body"],
                    note["revision"],
                    note["created_at"],
                    note["updated_at"],
                    note.get("prefix") or "",
                    note.get("suffix") or "",
                ),
            )
            counts["notes"] += 1
        for device in native_tables["devices"]:
            conn.execute(
                """INSERT INTO devices(id,name,token_hash,created_at,expires_at) VALUES(%s,%s,%s,%s,%s) ON CONFLICT(id) DO NOTHING""",
                (
                    device["id"],
                    device["name"],
                    device["token_hash"],
                    datetime.fromtimestamp(device["created"], timezone.utc),
                    datetime.fromtimestamp(device["expires"], timezone.utc),
                ),
            )
        for reading in native_tables["reading"]:
            if reading["paper"] not in identities.values():
                continue
            conn.execute(
                """INSERT INTO reading_state(work_id,pdf_sha256,page,section,revision,device_id,updated_at)
                VALUES(%s,%s,%s,%s,%s,%s,%s)""",
                (
                    reading["paper"],
                    reading["pdf_sha256"],
                    reading["page"],
                    reading["section"],
                    reading["revision"],
                    reading["device"],
                    datetime.fromtimestamp(reading["updated"], timezone.utc),
                ),
            )
            counts["reading_positions"] += 1
        for key in identities.values():
            runtime.db.emit(conn, "work.changed", key)
        conn.execute(
            "INSERT INTO legacy_imports(snapshot_sha,source,counts) VALUES(%s,%s,%s)",
            (snapshot["sha256"], str(original_output), Jsonb(dict(counts))),
        )
    return {**counts, "snapshot_sha": snapshot["sha256"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="Frozen v1 output directory")
    parser.add_argument("--native-db", required=True, type=Path)
    parser.add_argument(
        "--original-output", required=True, type=Path, help="Original path stored in v1 records"
    )
    args = parser.parse_args()
    print(
        canonical(
            import_snapshot(
                initialize(Settings.environment()), args.output, args.native_db, args.original_output
            )
        )
    )


if __name__ == "__main__":
    main()
