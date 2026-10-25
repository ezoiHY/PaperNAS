"""Library, annotation and reading resources used by the native client."""

from __future__ import annotations

from typing import Literal

from fastapi import Request
from psycopg.types.json import Jsonb
from pydantic import Field, model_validator

from .core import Problem, new_id
from .library import work_row
from .research import Input


class GroupInput(Input):
    name: str = Field(min_length=1, max_length=200)
    revision: int | None = None


class Rectangle(Input):
    x: float = Field(ge=0, le=1, allow_inf_nan=False)
    y: float = Field(ge=0, le=1, allow_inf_nan=False)
    width: float = Field(gt=0, le=1, allow_inf_nan=False)
    height: float = Field(gt=0, le=1, allow_inf_nan=False)

    @model_validator(mode="after")
    def fits_page(self):
        if self.x + self.width > 1.001 or self.y + self.height > 1.001:
            raise ValueError("Rectangle exceeds page bounds")
        return self


class NoteInput(Input):
    pdf_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    page: int = Field(ge=1, le=500)
    selected_text: str = Field(default="", max_length=30000)
    rects: list[Rectangle] = Field(default_factory=list, max_length=300)
    body: str = Field(min_length=1, max_length=30000)
    prefix: str = ""
    suffix: str = ""


class NoteEdit(Input):
    body: str = Field(min_length=1, max_length=30000)
    revision: int = Field(ge=1)


class RevisionInput(Input):
    revision: int = Field(ge=1)


class ReadingInput(Input):
    page: int = Field(default=1, ge=1, le=500)
    section: Literal["report", "pdf", "source", "notes", "figures", "brief"] = "report"
    pdf_sha256: str | None = None
    revision: int = Field(default=0, ge=0)


def install_native_routes(router, runtime, mutation, pdf_info_data):
    @router.get("/groups")
    def groups():
        with runtime.db.connect() as conn:
            return {
                "groups": conn.execute("""SELECT g.*,count(w.id) AS count FROM groups g LEFT JOIN group_works gw ON gw.group_id=g.id
                LEFT JOIN works w ON w.id=gw.work_id AND w.deleted_at IS NULL GROUP BY g.id ORDER BY g.name""").fetchall()
            }

    @router.post("/groups")
    def create_group(body: GroupInput, request: Request):
        def save(conn):
            row = conn.execute(
                "INSERT INTO groups(id,name) VALUES(%s,%s) RETURNING *", (new_id(), body.name)
            ).fetchone()
            runtime.db.emit(conn, "group.changed", row["id"], row["revision"])
            return row

        return mutation(request, body.model_dump(), save, status=201)

    @router.patch("/groups/{identifier}")
    def patch_group(identifier: str, body: GroupInput, request: Request):
        def save(conn):
            row = conn.execute(
                "UPDATE groups SET name=%s,revision=revision+1 WHERE id=%s AND revision=%s RETURNING *",
                (body.name, identifier, body.revision),
            ).fetchone()
            if not row:
                raise Problem("revision_conflict", "分组已更新或已删除，请刷新后再保存", 409)
            runtime.db.emit(conn, "group.changed", identifier, row["revision"])
            return row

        return mutation(request, body.model_dump(), save)

    @router.delete("/groups/{identifier}")
    def delete_group(identifier: str, request: Request):
        def save(conn):
            conn.execute("DELETE FROM groups WHERE id=%s", (identifier,))
            runtime.db.emit(conn, "group.deleted", identifier)
            return {"deleted": identifier}

        return mutation(request, {}, save)

    @router.get("/works/{identifier}/notes")
    @router.get("/papers/{identifier}/notes", include_in_schema=False)
    def notes(identifier: str):
        with runtime.db.connect() as conn:
            info = pdf_info_data(conn, identifier)
            rows = conn.execute(
                "SELECT * FROM notes WHERE work_id=%s ORDER BY page,created_at", (identifier,)
            ).fetchall()
            for row in rows:
                row["pdf_current"] = row["pdf_sha256"] == info["sha256"]
            return {"notes": rows}

    @router.post("/works/{identifier}/notes")
    @router.post("/papers/{identifier}/notes", include_in_schema=False)
    def post_note(identifier: str, body: NoteInput, request: Request):
        def save(conn):
            work_row(conn, identifier, lock=True)
            info = pdf_info_data(conn, identifier)
            if body.pdf_sha256 != info["sha256"]:
                raise Problem("pdf_version_conflict", "PDF 版本已更新，请核对当前文件后保存", 409)
            if info["page_count"] and body.page > info["page_count"]:
                raise Problem("invalid_page", "批注页码超出 PDF 范围")
            row = conn.execute(
                """INSERT INTO notes(id,work_id,pdf_sha256,page,selected_text,rects,body,prefix,suffix) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s)
                RETURNING *""",
                (
                    new_id(),
                    identifier,
                    body.pdf_sha256,
                    body.page,
                    body.selected_text,
                    Jsonb([r.model_dump() for r in body.rects]),
                    body.body,
                    body.prefix,
                    body.suffix,
                ),
            ).fetchone()
            runtime.db.emit(conn, "note.changed", row["id"], 1, work_id=identifier)
            return row

        return mutation(request, body.model_dump(), save, status=201)

    @router.patch("/works/{identifier}/notes/{note_id}")
    @router.patch("/papers/{identifier}/notes/{note_id}", include_in_schema=False)
    def patch_note(identifier: str, note_id: str, body: NoteEdit, request: Request):
        def save(conn):
            work_row(conn, identifier)
            row = conn.execute(
                "UPDATE notes SET body=%s,revision=revision+1,updated_at=now() WHERE id=%s AND work_id=%s AND revision=%s RETURNING *",
                (body.body, note_id, identifier, body.revision),
            ).fetchone()
            if not row:
                raise Problem("revision_conflict", "笔记已更新或已删除，请刷新后再保存", 409)
            runtime.db.emit(conn, "note.changed", note_id, row["revision"], work_id=identifier)
            return row

        return mutation(request, body.model_dump(), save)

    @router.delete("/works/{identifier}/notes/{note_id}")
    @router.delete("/papers/{identifier}/notes/{note_id}", include_in_schema=False)
    def delete_note(identifier: str, note_id: str, body: RevisionInput, request: Request):
        def save(conn):
            removed = conn.execute(
                "DELETE FROM notes WHERE id=%s AND work_id=%s AND revision=%s RETURNING id",
                (note_id, identifier, body.revision),
            ).fetchone()
            if not removed:
                raise Problem("revision_conflict", "笔记已更新或已删除，请刷新后再操作", 409)
            runtime.db.emit(conn, "note.deleted", note_id, body.revision + 1, work_id=identifier)
            return {"deleted": note_id}

        return mutation(request, body.model_dump(), save)

    @router.get("/works/{identifier}/reading-state")
    @router.get("/papers/{identifier}/reading-state", include_in_schema=False)
    def reading(identifier: str):
        with runtime.db.connect() as conn:
            work_row(conn, identifier)
            return {
                "reading": conn.execute(
                    "SELECT * FROM reading_state WHERE work_id=%s", (identifier,)
                ).fetchone()
                or {"revision": 0, "page": 1, "section": "report"}
            }

    @router.put("/works/{identifier}/reading-state")
    @router.put("/papers/{identifier}/reading-state", include_in_schema=False)
    def save_reading(identifier: str, body: ReadingInput, request: Request):
        def save(conn):
            work_row(conn, identifier, lock=True)
            old = conn.execute(
                "SELECT revision FROM reading_state WHERE work_id=%s", (identifier,)
            ).fetchone()
            if body.revision != (old["revision"] if old else 0):
                raise Problem("revision_conflict", "阅读位置已由其他设备更新", 409)
            if (
                body.pdf_sha256
                and not conn.execute(
                    "SELECT id FROM work_versions WHERE work_id=%s AND pdf_asset=%s",
                    (identifier, body.pdf_sha256),
                ).fetchone()
            ):
                raise Problem("pdf_version_conflict", "阅读位置所指 PDF 不属于当前论文", 409)
            row = conn.execute(
                """INSERT INTO reading_state(work_id,pdf_sha256,page,section,device_id) VALUES(%s,%s,%s,%s,%s)
                ON CONFLICT(work_id) DO UPDATE SET pdf_sha256=excluded.pdf_sha256,page=excluded.page,section=excluded.section,
                device_id=excluded.device_id,revision=reading_state.revision+1,updated_at=now() RETURNING *""",
                (identifier, body.pdf_sha256, body.page, body.section, request.state.device),
            ).fetchone()
            runtime.db.emit(conn, "reading.changed", identifier, row["revision"])
            return {"reading": row}

        return mutation(request, body.model_dump(), save)

    @router.get("/local-index", include_in_schema=False)
    def index():
        with runtime.db.connect() as conn:
            return {
                "indexed": conn.execute(
                    "SELECT count(*) AS n FROM works WHERE current_document_id IS NOT NULL AND deleted_at IS NULL"
                ).fetchone()["n"],
                "pending": 0,
                "engine": "postgresql_fts",
                "automatic": True,
            }
