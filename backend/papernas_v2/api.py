from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import secrets
from contextlib import asynccontextmanager
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, FastAPI, File, Header, Query, Request, UploadFile
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, Response, StreamingResponse
from pydantic import Field

from . import research
from .core import Problem, canonical, new_id
from .library import list_works, paper_dto, update_work, work_row
from .models import save_secret, secret_path
from .operations import OperationInput, create_operation, native_job
from .research import Input
from .runtime import Runtime
from .settings import Settings
from .sources import upsert_work, validate_url


class DeviceInput(Input):
    access_key: str = Field(min_length=1, max_length=300)
    device_name: str = Field(default="Mac", min_length=1, max_length=200)


class LinkInput(Input):
    work_id: str
    reason: str = Field(default="", max_length=10000)


class ModelInput(Input):
    base_url: str = Field(max_length=2000)
    model: str = Field(max_length=300)
    max_output_tokens: int = Field(default=4000, ge=512, le=12000)
    revision: int = Field(default=0, ge=0)


class DiscoveryInput(Input):
    query: str = Field(default="", max_length=2000)
    source_queries: dict[Literal["arxiv", "crossref"], Annotated[str, Field(max_length=2000)]] = Field(
        default_factory=dict
    )
    sources: list[Literal["arxiv", "crossref"]] = Field(default_factory=lambda: ["arxiv"])
    limit: int = Field(default=15, ge=1, le=100)
    enabled: bool = False
    time: str = "09:00"
    timezone: str = "Asia/Shanghai"
    revision: int = Field(default=0, ge=0)


class ResolutionInput(Input):
    outcome: Literal["not_charged", "charged_no_result"]
    used_tokens: int = Field(default=0, ge=0)
    note: str = Field(min_length=1, max_length=2000)


def create_app(settings=None):
    settings = settings or Settings.environment()
    runtime = Runtime(settings)

    @asynccontextmanager
    async def lifespan(app):
        runtime.db.migrate()
        runtime.queue.migrate(runtime.db)
        yield

    app = FastAPI(title="Paper NAS research API", version="0.5.0", lifespan=lifespan)
    app.state.runtime = runtime

    @app.exception_handler(Problem)
    async def problem_handler(request, error):
        return JSONResponse(
            status_code=error.status,
            content=jsonable_encoder(
                {
                    "type": "urn:papernas:error:" + error.code,
                    "title": error.code,
                    "status": error.status,
                    "detail": error.message,
                    "error": error.message,
                    **error.context,
                }
            ),
            media_type="application/problem+json",
        )

    @app.exception_handler(RequestValidationError)
    async def validation_handler(request, error):
        return JSONResponse(
            status_code=422,
            content={
                "error": "输入字段无效，请检查后再保存",
                "code": "validation_error",
                "fields": [{"path": list(e["loc"]), "message": e["msg"]} for e in error.errors()],
            },
        )

    @app.get("/health")
    @app.get("/api/v2/health")
    def health():
        with runtime.db.connect() as conn:
            conn.execute("SELECT 1")
            workers = conn.execute(
                "SELECT count(*) AS n FROM public.procrastinate_workers WHERE last_heartbeat>now()-(%s * interval '1 second')",
                (settings.worker_stale_seconds,),
            ).fetchone()["n"]
        return {"status": "ok", "api_version": 2, "version": "0.5.0", "active_workers": workers}

    @app.post("/api/v2/auth/devices")
    def register_device(body: DeviceInput, request: Request):
        if not settings.access_key_file.exists():
            raise Problem("server_not_initialized", "服务器尚未初始化访问密钥", 503)
        if not hmac.compare_digest(body.access_key, settings.access_key_file.read_text().strip()):
            raise Problem("invalid_access_key", "访问密钥无效", 401)
        token, identifier = secrets.token_urlsafe(40), new_id()
        with runtime.db.connect() as conn:
            conn.execute(
                "INSERT INTO devices(id,name,token_hash,expires_at) VALUES(%s,%s,%s,now()+interval '365 days')",
                (identifier, body.device_name, hashlib.sha256(token.encode()).hexdigest()),
            )
            server = runtime.db.setting(conn, "server_id")
            cursor = conn.execute("SELECT cursor FROM event_counter").fetchone()["cursor"]
        return {
            "device": {"id": identifier, "token": token},
            "server_id": server,
            "event_cursor": cursor,
            "api_version": 2,
        }

    def authenticate(request: Request, authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith("Bearer "):
            raise Problem("authentication_required", "请连接服务器", 401)
        digest = hashlib.sha256(authorization[7:].encode()).hexdigest()
        with runtime.db.connect() as conn:
            device = conn.execute(
                "SELECT id FROM devices WHERE token_hash=%s AND revoked_at IS NULL AND expires_at>now()",
                (digest,),
            ).fetchone()
        if not device:
            raise Problem("device_expired", "设备连接已过期或已撤销，请重新连接", 401)
        request.state.device = device["id"]
        return device["id"]

    router = APIRouter(prefix="/api/v2", dependencies=[Depends(authenticate)])

    def mutation(request, payload, action, *, status=200):
        key = request.headers.get("Idempotency-Key", "")
        scope = request.state.device + ":" + request.method + ":" + request.url.path
        with runtime.db.connect() as conn:
            code, response, replayed = runtime.db.idempotent(
                conn, scope, key, payload, lambda c: (status, action(c))
            )
        return JSONResponse(
            status_code=code,
            content=jsonable_encoder(response),
            headers={"Idempotency-Replayed": str(replayed).lower()},
        )

    @router.get("/capabilities")
    def capabilities():
        with runtime.db.connect() as conn:
            return {
                "api_version": 2,
                "server_id": runtime.db.setting(conn, "server_id"),
                "event_cursor": conn.execute("SELECT cursor FROM event_counter").fetchone()["cursor"],
                "features": {
                    "research_space": True,
                    "pdf_upload": True,
                    "durable_operations": True,
                    "evidence": True,
                    "comparison": True,
                    "figure_correction": True,
                    "full_text_search": True,
                    "semantic_search": False,
                    "zotero_sync": False,
                },
            }

    @router.get("/devices")
    def devices():
        with runtime.db.connect() as conn:
            return {
                "devices": conn.execute(
                    "SELECT id,name,created_at,last_seen_at,expires_at FROM devices WHERE revoked_at IS NULL ORDER BY created_at"
                ).fetchall()
            }

    @router.delete("/devices/{identifier}")
    def revoke_device(identifier: str, request: Request):
        def save(conn):
            conn.execute("UPDATE devices SET revoked_at=now() WHERE id=%s", (identifier,))
            return {"revoked": identifier}

        return mutation(request, {}, save)

    @router.get("/overview")
    def overview():
        with runtime.db.connect() as conn:
            return {
                "counts": {
                    r["collection"]: r["n"]
                    for r in conn.execute(
                        "SELECT collection,count(*) AS n FROM works WHERE deleted_at IS NULL GROUP BY collection"
                    ).fetchall()
                },
                "research_questions": conn.execute(
                    "SELECT count(*) AS n FROM research_questions WHERE status='active'"
                ).fetchone()["n"],
                "sources": conn.execute(
                    "SELECT * FROM source_checkpoints ORDER BY updated_at DESC"
                ).fetchall(),
                "operations": conn.execute(
                    "SELECT id,kind,state,updated_at FROM operations ORDER BY updated_at DESC LIMIT 10"
                ).fetchall(),
            }

    @router.get("/works")
    @router.get("/papers", include_in_schema=False)
    def works(
        collection: str | None = None,
        q: str = "",
        group: str | None = None,
        source: str | None = None,
        offset: int = Query(0, ge=0),
        limit: int = Query(40, ge=1, le=100),
        sort: str = "published_desc",
        status: str = "",
    ):
        with runtime.db.connect() as conn:
            result = list_works(
                conn,
                collection=collection,
                query=q[:2000],
                group=group,
                source=source,
                offset=offset,
                limit=limit,
                sort=sort,
                status=status,
            )
            result["works"] = result["papers"]
            return result

    @router.get("/works/{identifier}")
    @router.get("/papers/{identifier}", include_in_schema=False)
    def work(identifier: str):
        with runtime.db.connect() as conn:
            return paper_dto(conn, work_row(conn, identifier), full=True)

    @router.patch("/works/{identifier}")
    @router.patch("/papers/{identifier}", include_in_schema=False)
    def patch_work(identifier: str, body: dict, request: Request):
        return mutation(request, body, lambda conn: update_work(conn, identifier, body))

    @router.delete("/works/{identifier}")
    @router.delete("/papers/{identifier}", include_in_schema=False)
    def remove_work(identifier: str, request: Request):
        def remove(conn):
            work_row(conn, identifier, lock=True)
            revision = conn.execute(
                "UPDATE works SET deleted_at=now(),revision=revision+1 WHERE id=%s RETURNING revision",
                (identifier,),
            ).fetchone()["revision"]
            runtime.db.emit(conn, "work.deleted", identifier, revision)
            return {"deleted": identifier, "revision": revision}

        return mutation(request, {}, remove)

    @router.get("/assets/{sha}")
    def asset(sha: str):
        with runtime.db.connect() as conn:
            asset = conn.execute("SELECT * FROM assets WHERE sha256=%s", (sha,)).fetchone()
            if not asset or not runtime.assets.path(sha).exists():
                raise Problem("asset_missing", "材料文件不存在", 404)
        # HTML and raw provider payloads are attachments; only passive images/PDF are inline.
        media = asset["media_type"]
        inline = media in {"image/png", "image/jpeg", "image/webp", "application/pdf"}
        return FileResponse(
            runtime.assets.path(sha),
            media_type=media if inline else "application/octet-stream",
            headers={
                "ETag": '"' + sha + '"',
                "X-Content-Type-Options": "nosniff",
                "Cache-Control": "private, max-age=31536000, immutable",
            },
        )

    @router.get("/blocks/{identifier}")
    def source_block(identifier: str):
        with runtime.db.connect() as conn:
            row = conn.execute(
                """SELECT b.*,v.pdf_asset AS pdf_sha256,v.work_id,w.title AS work_title FROM blocks b
                JOIN documents d ON d.id=b.document_id JOIN work_versions v ON v.id=d.version_id JOIN works w ON w.id=v.work_id
                WHERE b.id=%s""",
                (identifier,),
            ).fetchone()
            if not row:
                raise Problem("block_missing", "原文段落不存在", 404)
            return row

    @router.get("/figures/{identifier}/page-preview")
    def figure_page_preview(identifier: str, page: int | None = Query(None, ge=1, le=500)):
        import pymupdf as fitz

        from .parsing import render_pdf_region

        with runtime.db.connect() as conn:
            figure = conn.execute(
                """SELECT f.page,v.pdf_asset FROM figures f JOIN documents d ON d.id=f.document_id
                JOIN work_versions v ON v.id=d.version_id WHERE f.id=%s""",
                (identifier,),
            ).fetchone()
            if not figure:
                raise Problem("figure_missing", "图表不存在", 404)
        page = page or figure["page"]
        if page is None:
            raise Problem("page_required", "旧图表没有已确认的 PDF 页码，请选择原文页码")
        if not figure["pdf_asset"]:
            raise Problem("pdf_missing", "此版本没有 PDF，请先补充原文文件", 404)
        path = runtime.assets.path(figure["pdf_asset"])
        with fitz.open(path) as pdf:
            if page > len(pdf):
                raise Problem("page_invalid", "页码超出 PDF 范围")
            bounds, count = pdf[page - 1].rect, len(pdf)
        content, _ = render_pdf_region(path, page)
        image = runtime.assets.put(content, "image/png")
        with runtime.db.connect() as conn:
            runtime.assets.register(conn, image)
        return {
            "page": page,
            "page_count": count,
            "width": bounds.width,
            "height": bounds.height,
            "pdf_sha256": figure["pdf_asset"],
            "asset_url": "/api/v2/assets/" + image["sha256"],
        }

    def pdf_info_data(conn, identifier):
        work = work_row(conn, identifier)
        version = conn.execute(
            "SELECT * FROM work_versions WHERE id=%s", (work["current_version_id"],)
        ).fetchone()
        sha = version["pdf_asset"] if version else None
        document = conn.execute(
            "SELECT page_count FROM documents WHERE id=%s", (work["current_document_id"],)
        ).fetchone()
        return {
            "available": bool(sha and runtime.assets.path(sha).exists()),
            "sha256": sha,
            "page_count": document["page_count"] if document else 0,
            "version_id": work["current_version_id"],
            "download": None,
        }

    @router.get("/works/{identifier}/pdf/info")
    @router.get("/papers/{identifier}/pdf/info", include_in_schema=False)
    def pdf_info(identifier: str):
        with runtime.db.connect() as conn:
            return pdf_info_data(conn, identifier)

    @router.get("/works/{identifier}/pdf")
    @router.get("/papers/{identifier}/pdf", include_in_schema=False)
    def pdf(identifier: str, version_id: str | None = None):
        with runtime.db.connect() as conn:
            work = work_row(conn, identifier)
            version = conn.execute(
                "SELECT pdf_asset FROM work_versions WHERE id=%s AND work_id=%s",
                (version_id or work["current_version_id"], identifier),
            ).fetchone()
            if not version or not version["pdf_asset"]:
                raise Problem("pdf_missing", "PDF 尚未取得", 404)
            return asset(version["pdf_asset"])

    @router.post("/papers/{identifier}/pdf", include_in_schema=False)
    def fetch_pdf(identifier: str, request: Request):
        body = OperationInput(kind="extract", work_ids=[identifier])
        return mutation(
            request, body.model_dump(), lambda conn: create_operation(runtime, conn, body), status=202
        )

    @router.get("/works/{identifier}/pdf/pages/{page}")
    def pdf_page(identifier: str, page: int, version_id: str | None = None):
        import pymupdf as fitz

        from .parsing import render_pdf_region

        if not 1 <= page <= 500:
            raise Problem("page_invalid", "Choose a PDF page between 1 and 500")
        with runtime.db.connect() as conn:
            work = work_row(conn, identifier)
            version = conn.execute(
                "SELECT pdf_asset FROM work_versions WHERE id=%s AND work_id=%s",
                (version_id or work["current_version_id"], identifier),
            ).fetchone()
            if not version or not version["pdf_asset"]:
                raise Problem("pdf_missing", "PDF is not available", 404)
        source = runtime.assets.path(version["pdf_asset"])
        if not source.is_file():
            raise Problem("pdf_missing", "PDF file is missing", 404)
        with fitz.open(source) as pdf:
            count = len(pdf)
        if page > count:
            raise Problem("page_invalid", "Page is outside this PDF")
        content, _ = render_pdf_region(source, page)
        return Response(
            content,
            media_type="image/png",
            headers={
                "X-PDF-Page-Count": str(count),
                "X-PDF-SHA256": version["pdf_asset"],
                "X-Content-Type-Options": "nosniff",
                "Cache-Control": "private, max-age=300",
                "ETag": f'"{version["pdf_asset"]}-{page}"',
            },
        )

    @router.post("/imports/pdf")
    async def upload_pdf(
        request: Request, file: Annotated[UploadFile, File()], title: str = "", work_id: str | None = None
    ):
        content = bytearray()
        while chunk := await file.read(1024 * 1024):
            content.extend(chunk)
            if len(content) > settings.max_download_bytes:
                raise Problem("pdf_too_large", "PDF 超过上传大小限制", 413)
        if not content[:1024].lstrip().startswith(b"%PDF-"):
            raise Problem("invalid_pdf", "请选择 PDF 文件")
        asset = await asyncio.to_thread(runtime.assets.put, bytes(content), "application/pdf")
        payload = {"sha256": asset["sha256"], "title": title[:1000], "work_id": work_id}

        def save(conn):
            runtime.assets.register(conn, asset)
            if work_id:
                work = work_row(conn, work_id, lock=True)
                current = conn.execute(
                    "SELECT * FROM work_versions WHERE id=%s", (work["current_version_id"],)
                ).fetchone()
                if current and (not current["pdf_asset"] or current["pdf_asset"] == asset["sha256"]):
                    version = current["id"]
                    conn.execute(
                        "UPDATE work_versions SET pdf_asset=%s WHERE id=%s", (asset["sha256"], version)
                    )
                else:
                    version = conn.execute(
                        """INSERT INTO work_versions(id,work_id,label,pdf_asset) VALUES(%s,%s,%s,%s)
                        ON CONFLICT(work_id,label) DO UPDATE SET pdf_asset=excluded.pdf_asset RETURNING id""",
                        (new_id(), work_id, "upload-" + asset["sha256"][:12], asset["sha256"]),
                    ).fetchone()["id"]
                identifier = work_id
            else:
                identifier, version = upsert_work(
                    conn,
                    {
                        "source": "local",
                        "identifier": asset["sha256"],
                        "version": "uploaded",
                        "title": title[:1000] or (file.filename or "Imported paper").removesuffix(".pdf"),
                        "authors": [],
                        "url": "",
                    },
                )
                conn.execute("UPDATE work_versions SET pdf_asset=%s WHERE id=%s", (asset["sha256"], version))
            conn.execute(
                """UPDATE works SET current_document_id=CASE WHEN current_version_id=%s THEN current_document_id ELSE NULL END,
                current_analysis_id=CASE WHEN current_version_id=%s THEN current_analysis_id ELSE NULL END,current_version_id=%s,revision=revision+1 WHERE id=%s""",
                (version, version, version, identifier),
            )
            operation = runtime.execution.create_operation(
                conn, "import_pdf", {"work_id": identifier, "version_id": version}
            )
            runtime.execution.add_stage(conn, operation, "parse", {"version_id": version}, queue="parse")
            runtime.db.emit(conn, "work.changed", identifier)
            return {"work_id": identifier, "operation": runtime.execution.get(conn, operation)}

        return await asyncio.to_thread(mutation, request, payload, save, status=202)

    @router.get("/operations")
    def operations(limit: int = Query(50, ge=1, le=200)):
        with runtime.db.connect() as conn:
            return {
                "operations": [
                    runtime.execution.get(conn, row["id"])
                    for row in conn.execute(
                        "SELECT id FROM operations ORDER BY created_at DESC LIMIT %s", (limit,)
                    ).fetchall()
                ]
            }

    @router.post("/operations")
    def post_operation(body: OperationInput, request: Request):
        return mutation(
            request,
            body.model_dump(),
            lambda conn: {"operation": create_operation(runtime, conn, body)},
            status=202,
        )

    @router.get("/operations/{identifier}")
    def operation(identifier: str):
        with runtime.db.connect() as conn:
            result = runtime.execution.get(conn, identifier)
            result["invocations"] = conn.execute(
                """SELECT m.* FROM model_invocations m JOIN stages s ON s.id=m.stage_id WHERE s.operation_id=%s ORDER BY m.created_at""",
                (identifier,),
            ).fetchall()
            return result

    @router.post("/operations/{identifier}/{action}")
    @router.post("/jobs/{identifier}/{action}", include_in_schema=False)
    def control_operation(
        identifier: str, action: Literal["pause", "resume", "retry", "cancel"], request: Request
    ):
        return mutation(
            request, {"action": action}, lambda conn: runtime.execution.control(conn, identifier, action)
        )

    @router.get("/jobs", include_in_schema=False)
    def jobs():
        rows = operations()["operations"]
        active = [row for row in rows if row["state"] in {"queued", "running"}]
        return {
            "recent": rows,
            "active": active[0] if active else None,
            "queued": active[1:],
            "pending": None,
        }

    @router.post("/jobs", include_in_schema=False)
    def post_job(body: dict, request: Request):
        return mutation(request, body, lambda conn: native_job(runtime, conn, body), status=202)

    @router.get("/jobs/{identifier}/log", include_in_schema=False)
    def job_log(identifier: str):
        return PlainTextResponse(
            json.dumps(jsonable_encoder(operation(identifier)), ensure_ascii=False, indent=2)
        )

    @router.get("/downloads", include_in_schema=False)
    def downloads():
        with runtime.db.connect() as conn:
            return {
                "downloads": conn.execute("""SELECT s.id,s.outcome AS status,w.id AS key,w.title FROM stages s
                JOIN work_versions v ON v.id=s.input->>'version_id' JOIN works w ON w.id=v.work_id
                WHERE s.kind='fetch_pdf' AND s.outcome<>'ready' ORDER BY s.created_at DESC LIMIT 100""").fetchall()
            }

    @router.get("/settings/model")
    def model_config():
        with runtime.db.connect() as conn:
            row = conn.execute("SELECT * FROM settings WHERE key='model_config'").fetchone()
            return {
                "config": row["value"] if row else {},
                "revision": row["revision"] if row else 0,
                "key_configured": secret_path(settings).exists(),
            }

    @router.put("/settings/model")
    def save_model(body: ModelInput, request: Request):
        if body.base_url:
            validate_url(body.base_url, settings)

        def save(conn):
            conn.execute("SELECT pg_advisory_xact_lock(72024003)")
            old = conn.execute("SELECT revision FROM settings WHERE key='model_config'").fetchone()
            if body.revision != (old["revision"] if old else 0):
                raise Problem("revision_conflict", "模型设置已更新，请重新载入", 409)
            runtime.db.set_setting(conn, "model_config", body.model_dump(exclude={"revision"}))
            return {"saved": True}

        return mutation(request, body.model_dump(), save)

    @router.put("/settings/model/key")
    @router.put("/key", include_in_schema=False)
    def save_model_key(body: dict, request: Request):
        key = body.get("api_key")
        if not isinstance(key, str) or not 1 <= len(key) <= 1000:
            raise Problem("invalid_model_key", "请输入有效模型密钥")
        # A secret is never stored in request bodies, events, or GET responses.
        save_secret(settings, key)
        return {"saved": True, "key_configured": True}

    @router.get("/settings/discovery")
    def discovery_config():
        with runtime.db.connect() as conn:
            row = conn.execute("SELECT * FROM settings WHERE key='discovery_config'").fetchone()
            return {
                "config": row["value"] if row else DiscoveryInput().model_dump(exclude={"revision"}),
                "revision": row["revision"] if row else 0,
            }

    @router.put("/settings/discovery")
    def save_discovery(body: DiscoveryInput, request: Request):
        import re
        from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

        if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", body.time) or body.enabled and not body.query:
            raise Problem("invalid_schedule", "请填写检索式和有效执行时间")
        try:
            ZoneInfo(body.timezone)
        except ZoneInfoNotFoundError as error:
            raise Problem("invalid_timezone", "时区无效") from error

        def save(conn):
            conn.execute("SELECT pg_advisory_xact_lock(72024004)")
            old = conn.execute("SELECT revision FROM settings WHERE key='discovery_config'").fetchone()
            if body.revision != (old["revision"] if old else 0):
                raise Problem("revision_conflict", "发现设置已更新，请重新载入", 409)
            runtime.db.set_setting(conn, "discovery_config", body.model_dump(exclude={"revision"}))
            return {"saved": True}

        return mutation(request, body.model_dump(), save)

    @router.post("/model-invocations/{identifier}/resolve")
    def resolve_invocation(identifier: str, body: ResolutionInput, request: Request):
        if body.outcome == "charged_no_result" and body.used_tokens <= 0:
            raise Problem("usage_required", "请记录已核对的 token 用量")

        def save(conn):
            row = conn.execute(
                """SELECT m.*,s.operation_id FROM model_invocations m JOIN stages s ON s.id=m.stage_id WHERE m.id=%s""",
                (identifier,),
            ).fetchone()
            if not row:
                raise Problem("invocation_missing", "调用记录不存在", 404)
            conn.execute("SELECT id FROM operations WHERE id=%s FOR UPDATE", (row["operation_id"],))
            row = conn.execute(
                "SELECT * FROM model_invocations WHERE id=%s FOR UPDATE", (identifier,)
            ).fetchone()
            if row["state"] != "unknown":
                raise Problem("invocation_state_conflict", "仅能处理结果未知的调用", 409)
            used = body.used_tokens if body.outcome == "charged_no_result" else 0
            operation = conn.execute(
                "SELECT operation_id FROM stages WHERE id=%s", (row["stage_id"],)
            ).fetchone()["operation_id"]
            conn.execute(
                "UPDATE model_invocations SET state='resolved',used_tokens=%s,error=%s,updated_at=now() WHERE id=%s",
                (used, body.note, identifier),
            )
            conn.execute(
                "UPDATE operations SET budget_reserved=budget_reserved-%s,budget_used=budget_used+%s WHERE id=%s",
                (row["reserved_tokens"], used, operation),
            )
            runtime.db.emit(conn, "operation.changed", operation)
            return {"resolved": identifier, "retry_requires_explicit_action": True}

        return mutation(request, body.model_dump(), save)

    @router.get("/research/questions")
    def questions(q: str = ""):
        with runtime.db.connect() as conn:
            return {
                "questions": conn.execute(
                    """SELECT q.*,(SELECT count(*) FROM evidence e WHERE e.question_id=q.id) AS evidence_count,
                (SELECT count(*) FROM question_works qw WHERE qw.question_id=q.id) AS work_count FROM research_questions q
                WHERE q.title ILIKE %s OR q.context ILIKE %s ORDER BY q.updated_at DESC,q.id""",
                    ("%" + q[:1000] + "%", "%" + q[:1000] + "%"),
                ).fetchall()
            }

    @router.post("/research/questions")
    def post_question(body: research.QuestionInput, request: Request):
        return mutation(
            request, body.model_dump(), lambda conn: research.create_question(conn, body), status=201
        )

    @router.get("/research/questions/{identifier}")
    def question_detail(identifier: str):
        with runtime.db.connect() as conn:
            return research.detail(conn, identifier)

    @router.patch("/research/questions/{identifier}")
    def patch_question(identifier: str, body: research.QuestionInput, request: Request):
        return mutation(
            request, body.model_dump(), lambda conn: research.update_question(conn, identifier, body)
        )

    @router.post("/research/questions/{identifier}/works")
    def link_work(identifier: str, body: LinkInput, request: Request):
        return mutation(
            request,
            body.model_dump(),
            lambda conn: research.link_work(conn, identifier, body.work_id, body.reason),
        )

    @router.delete("/research/questions/{identifier}/works/{work_id}")
    def unlink_work(identifier: str, work_id: str, request: Request):
        def save(conn):
            research.question(conn, identifier, lock=True)
            conn.execute(
                "DELETE FROM question_works WHERE question_id=%s AND work_id=%s", (identifier, work_id)
            )
            research.changed(conn, identifier)
            return {"unlinked": work_id}

        return mutation(request, {}, save)

    @router.post("/research/questions/{identifier}/evidence")
    def post_evidence(identifier: str, body: research.EvidenceInput, request: Request):
        return mutation(
            request,
            body.model_dump(),
            lambda conn: research.create_evidence(conn, identifier, body),
            status=201,
        )

    @router.post("/research/questions/{identifier}/judgments")
    def post_judgment(identifier: str, body: research.JudgmentInput, request: Request):
        return mutation(
            request,
            body.model_dump(),
            lambda conn: research.save_judgment(conn, identifier, body),
            status=201,
        )

    @router.patch("/research/questions/{identifier}/judgments/{judgment_id}")
    def patch_judgment(identifier: str, judgment_id: str, body: research.JudgmentInput, request: Request):
        return mutation(
            request,
            body.model_dump(),
            lambda conn: research.save_judgment(conn, identifier, body, judgment_id),
        )

    @router.get("/research/questions/{identifier}/judgments/{judgment_id}/history")
    def judgment_history(identifier: str, judgment_id: str):
        with runtime.db.connect() as conn:
            research.verify_related(conn, "judgments", judgment_id, identifier)
            return {
                "history": conn.execute(
                    "SELECT * FROM judgment_history WHERE judgment_id=%s ORDER BY revision DESC",
                    (judgment_id,),
                ).fetchall()
            }

    @router.post("/research/questions/{identifier}/actions")
    def post_action(identifier: str, body: research.ActionInput, request: Request):
        return mutation(
            request, body.model_dump(), lambda conn: research.save_action(conn, identifier, body), status=201
        )

    @router.patch("/research/questions/{identifier}/actions/{action_id}")
    def patch_action(identifier: str, action_id: str, body: research.ActionInput, request: Request):
        return mutation(
            request, body.model_dump(), lambda conn: research.save_action(conn, identifier, body, action_id)
        )

    @router.post("/research/questions/{identifier}/results")
    def post_result(identifier: str, body: research.ResultInput, request: Request):
        return mutation(
            request,
            body.model_dump(),
            lambda conn: research.create_result(conn, identifier, body),
            status=201,
        )

    @router.post("/research/questions/{identifier}/snapshots")
    def post_snapshot(identifier: str, body: research.SnapshotInput, request: Request):
        return mutation(
            request,
            body.model_dump(),
            lambda conn: research.create_snapshot(conn, identifier, body),
            status=201,
        )

    @router.get("/research/questions/{identifier}/export")
    def export_question(identifier: str, format: Literal["markdown", "json"] = "markdown"):
        with runtime.db.connect() as conn:
            if format == "json":
                return JSONResponse(jsonable_encoder(research.detail(conn, identifier)))
            return PlainTextResponse(
                research.export_markdown(conn, identifier), media_type="text/markdown; charset=utf-8"
            )

    @router.put("/works/{identifier}/feedback")
    def feedback(identifier: str, body: dict, request: Request):
        if body.get("choice") not in {"useful", "known", "later", "irrelevant"}:
            raise Problem("invalid_feedback", "反馈选项无效")

        def save(conn):
            work_row(conn, identifier)
            question_id = body.get("question_id", "")
            if question_id:
                research.question(conn, question_id)
            conn.execute(
                """INSERT INTO feedback(work_id,question_id,choice,reason) VALUES(%s,%s,%s,%s)
                ON CONFLICT(work_id,question_id) DO UPDATE SET choice=excluded.choice,reason=excluded.reason,revision=feedback.revision+1,updated_at=now()""",
                (identifier, question_id, body["choice"], str(body.get("reason", ""))[:10000]),
            )
            runtime.db.emit(conn, "work.changed", identifier)
            return {"saved": True}

        return mutation(request, body, save)

    @router.get("/events")
    async def events(request: Request, after: int = Query(0, ge=0)):
        def batch(cursor):
            runtime.db.dispatch_events()
            with runtime.db.connect() as conn:
                return conn.execute(
                    "SELECT * FROM events WHERE cursor>%s ORDER BY cursor LIMIT 200", (cursor,)
                ).fetchall()

        async def stream():
            cursor = after
            for _ in range(50):
                if await request.is_disconnected():
                    return
                rows = await asyncio.to_thread(batch, cursor)
                for row in rows:
                    cursor = row["cursor"]
                    yield f"id: {cursor}\nevent: {row['kind']}\ndata: {canonical(row['payload'])}\n\n"
                if not rows:
                    yield ": keepalive\n\n"
                    await asyncio.sleep(1)

        return StreamingResponse(
            stream(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    from .native_routes import install_native_routes

    install_native_routes(router, runtime, mutation, pdf_info_data)
    app.include_router(router)
    from .web_ui import install_web

    install_web(app)
    return app
