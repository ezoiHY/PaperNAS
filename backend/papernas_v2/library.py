from __future__ import annotations

import re

from psycopg.types.json import Jsonb

from .core import Problem
from .db import Database


def figure_order(figure):
    # Migrated HTML figures often have no PDF page. Compare every numeric part
    # of the label so Figure 2 precedes 10, including panel/image suffixes.
    label = figure["label"] or ""
    natural_label = tuple(
        (0, int(part)) if part.isdigit() else (1, part) for part in re.split(r"(\d+)", label.casefold())
    )
    page = figure["page"]
    return page is None, page or 0, natural_label, label, figure["id"]


def work_row(conn, identifier, *, lock=False):
    row = conn.execute(
        "SELECT * FROM works WHERE id=%s AND deleted_at IS NULL" + (" FOR UPDATE" if lock else ""),
        (identifier,),
    ).fetchone()
    if not row:
        raise Problem("work_missing", "论文不存在", 404)
    return row


def document_data(conn, identifier):
    if not identifier:
        return None
    document = conn.execute("SELECT * FROM documents WHERE id=%s", (identifier,)).fetchone()
    document["blocks"] = conn.execute(
        "SELECT id,ordinal,kind,page,text,bbox,heading,heading AS section FROM blocks WHERE document_id=%s ORDER BY ordinal",
        (identifier,),
    ).fetchall()
    document["figures"] = sorted(
        conn.execute(
            """SELECT f.*,original.sha256 AS original_download_sha,
            coalesce(original.media_type,display.media_type,'image/png') AS original_mime_type
            FROM figures f LEFT JOIN assets original ON original.sha256=f.provenance->>'original_asset'
            LEFT JOIN assets display ON display.sha256=f.asset_sha WHERE f.document_id=%s""",
            (identifier,),
        ).fetchall(),
        key=figure_order,
    )
    for figure in document["figures"]:
        figure["asset_url"] = f"/api/v2/assets/{figure['asset_sha']}" if figure["asset_sha"] else ""
        figure["image_url"] = figure["asset_url"]
        figure["original_url"] = figure["asset_url"]
        figure["mime_type"] = "image/png"
        original_sha = figure.pop("original_download_sha") or figure["asset_sha"]
        figure["original_download_url"] = f"/api/v2/assets/{original_sha}" if original_sha else ""
        figure["source_url"] = figure["provenance"].get("url", "")
        figure["source"] = figure["provenance"].get("method", "")
        figure["caption_text"] = figure["caption"]
    return document


def paper_dto(conn, work, *, full=False):
    identifier = work["id"]
    version = (
        conn.execute("SELECT * FROM work_versions WHERE id=%s", (work["current_version_id"],)).fetchone()
        if work["current_version_id"]
        else None
    )
    analysis = (
        conn.execute(
            "SELECT data,document_id FROM analyses WHERE id=%s", (work["current_analysis_id"],)
        ).fetchone()
        if work["current_analysis_id"]
        else None
    )
    groups = conn.execute(
        "SELECT g.* FROM groups g JOIN group_works gw ON gw.group_id=g.id WHERE gw.work_id=%s ORDER BY g.name",
        (identifier,),
    ).fetchall()
    cover_id = work["enrichment"].get("cover_figure_id")
    figures = conn.execute(
        "SELECT id,label,page,status,asset_sha FROM figures WHERE document_id=%s",
        (work["current_document_id"],),
    ).fetchall()
    cover = min(
        (figure for figure in figures if figure["asset_sha"] is not None),
        key=lambda figure: (
            figure["id"] != cover_id,
            figure["status"] != "ready",
            *figure_order(figure),
        ),
        default=None,
    )
    data = analysis["data"] if analysis else {}
    legacy = conn.execute("SELECT * FROM legacy_records WHERE work_id=%s", (identifier,)).fetchone() or {}
    summary = data.get("summary")
    summary = summary.get("text", "") if isinstance(summary, dict) else summary
    summary = summary or legacy.get("summary") or work["enrichment"].get("summary") or work["abstract"]
    raw = {
        **work,
        "key": identifier,
        "bibliography": legacy.get("bibliography") or {},
        "paper": {
            "title": work["title"],
            "authors": work["authors"],
            "abstract": work["abstract"],
            "source": work["source"],
            "url": work["source_url"],
            "published_at": work["published_at"],
            "venue": work["venue"],
            **(
                {
                    k: v
                    for k, v in version["metadata"].items()
                    if k in {"doi", "arxiv_id", "version", "pdf_url", "html_url"}
                }
                if version
                else {}
            ),
        },
        "summary": summary,
        "has_document": bool(work["current_document_id"]),
        "has_report": bool(analysis),
        "has_brief": bool(legacy.get("brief")),
        "status": "analyzed" if analysis else "extracted" if work["current_document_id"] else "metadata",
        "report_stale": bool(analysis and analysis["document_id"] != work["current_document_id"]),
        "error": None,
        "group_ids": [g["id"] for g in groups],
        "groups": groups,
        "added_at": work["created_at"],
        "first_seen": work["created_at"],
        "cover_figure_id": cover["id"] if cover else "",
        "cover_asset_url": f"/api/v2/assets/{cover['asset_sha']}" if cover else "",
        "cover_label": cover["label"] if cover else "",
        "notes_count": conn.execute(
            "SELECT count(*) AS n FROM notes WHERE work_id=%s", (identifier,)
        ).fetchone()["n"],
        "materials": {
            "metadata": "ready",
            "pdf": "ready" if version and version["pdf_asset"] else "missing",
            "structure": "ready" if work["current_document_id"] else "missing",
            "analysis": "ready" if analysis else "missing",
            "figures": {
                status: sum(f["status"] == status for f in figures)
                for status in ("ready", "page_fallback", "pending", "failed")
            },
        },
    }
    if full:
        raw["document"] = document_data(conn, work["current_document_id"])
        raw["report"] = data
        raw["brief"] = legacy.get("brief")
        raw["markdown"] = data.get("markdown") or legacy.get("markdown", "")
        raw["versions"] = conn.execute(
            "SELECT id,label,pdf_asset,created_at FROM work_versions WHERE work_id=%s ORDER BY created_at DESC",
            (identifier,),
        ).fetchall()
        if raw["document"]:
            raw["materials"]["structure"] = raw["document"]["structure_quality"]
    return raw


def list_works(
    conn,
    *,
    collection=None,
    query="",
    group=None,
    source=None,
    offset=0,
    limit=40,
    sort="published_desc",
    status="",
):
    clauses, values = ["w.deleted_at IS NULL"], []
    if collection:
        clauses.append("w.collection=%s")
        values.append(collection)
    if source:
        clauses.append("w.source=%s")
        values.append(source)
    if group:
        clauses.append("EXISTS(SELECT 1 FROM group_works gw WHERE gw.work_id=w.id AND gw.group_id=%s)")
        values.append(group)
    if query:
        clauses.append("""(w.title ILIKE %s OR w.abstract ILIKE %s OR w.authors::text ILIKE %s OR EXISTS(SELECT 1 FROM blocks b WHERE b.document_id=w.current_document_id
            AND (b.search @@ websearch_to_tsquery('english',%s) OR b.text ILIKE %s)))""")
        values += ["%" + query + "%", "%" + query + "%", "%" + query + "%", query, "%" + query + "%"]
    if status == "analyzed":
        clauses.append("w.current_analysis_id IS NOT NULL")
    elif status in {"pending", "unread"}:
        clauses.append("w.current_analysis_id IS NULL")
    elif status == "extracted":
        clauses.append("w.current_document_id IS NOT NULL")
    elif status == "attention":
        clauses.append("""(w.current_document_id IS NULL
            OR EXISTS(SELECT 1 FROM figures f WHERE f.document_id=w.current_document_id
                AND f.status IN ('failed','page_fallback'))
            OR EXISTS(SELECT 1 FROM analyses a WHERE a.id=w.current_analysis_id
                AND a.document_id IS DISTINCT FROM w.current_document_id)
            OR (w.current_analysis_id IS NULL AND NOT EXISTS(SELECT 1 FROM legacy_records lr
                WHERE lr.work_id=w.id AND lr.brief IS NOT NULL)))""")
    where = " AND ".join(clauses)
    ordering = {
        "published_desc": "w.published_at DESC,w.id",
        "published_asc": "w.published_at,w.id",
        "title": "w.title,w.id",
        "added_desc": "w.created_at DESC,w.id",
        "added_asc": "w.created_at,w.id",
    }.get(sort, "w.created_at DESC,w.id")
    total = conn.execute("SELECT count(*) AS n FROM works w WHERE " + where, values).fetchone()["n"]
    rows = conn.execute(
        f"SELECT w.* FROM works w WHERE {where} ORDER BY {ordering} LIMIT %s OFFSET %s",
        (*values, limit, offset),
    ).fetchall()
    counts = {
        r["collection"]: r["n"]
        for r in conn.execute(
            "SELECT collection,count(*) AS n FROM works WHERE deleted_at IS NULL GROUP BY collection"
        ).fetchall()
    }
    return {
        "papers": [paper_dto(conn, row) for row in rows],
        "total": total,
        "offset": offset,
        "limit": limit,
        "counts_by_collection": counts,
    }


def update_work(conn, identifier, body):
    work = work_row(conn, identifier, lock=True)
    if body.get("revision") != work["revision"]:
        raise Problem("revision_conflict", "论文记录已更新，请刷新后再保存", 409, revision=work["revision"])
    unknown = set(body) - {"revision", "collection", "group_ids", "cover_figure_id", "title"}
    if unknown:
        raise Problem("unsupported_fields", "无法修改这些论文字段")
    if "collection" in body:
        if body["collection"] not in {"library", "candidates"}:
            raise Problem("invalid_collection", "论文集合无效")
        conn.execute("UPDATE works SET collection=%s WHERE id=%s", (body["collection"], identifier))
    if "title" in body:
        if not isinstance(body["title"], str) or not 1 <= len(body["title"].strip()) <= 1000:
            raise Problem("invalid_title", "标题长度无效")
        conn.execute("UPDATE works SET title=%s WHERE id=%s", (body["title"].strip(), identifier))
    if "group_ids" in body:
        groups = body["group_ids"]
        if not isinstance(groups, list) or len(groups) > 100 or any(not isinstance(g, str) for g in groups):
            raise Problem("invalid_groups", "分组无效")
        actual = {
            r["id"] for r in conn.execute("SELECT id FROM groups WHERE id=ANY(%s)", (groups,)).fetchall()
        }
        if actual != set(groups):
            raise Problem("group_missing", "分组不存在", 404)
        conn.execute("DELETE FROM group_works WHERE work_id=%s", (identifier,))
        for group in actual:
            conn.execute("INSERT INTO group_works VALUES(%s,%s)", (group, identifier))
    if "cover_figure_id" in body:
        figure = conn.execute(
            "SELECT id FROM figures WHERE id=%s AND document_id=%s",
            (body["cover_figure_id"], work["current_document_id"]),
        ).fetchone()
        if not figure:
            raise Problem("figure_missing", "代表图不属于当前文档", 404)
        conn.execute(
            "UPDATE works SET enrichment=enrichment || %s WHERE id=%s",
            (Jsonb({"cover_figure_id": figure["id"]}), identifier),
        )
    revision = conn.execute(
        "UPDATE works SET revision=revision+1,updated_at=now() WHERE id=%s RETURNING revision", (identifier,)
    ).fetchone()["revision"]
    Database.emit(conn, "work.changed", identifier, revision)
    return paper_dto(conn, work_row(conn, identifier), full=True)
