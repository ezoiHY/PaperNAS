from __future__ import annotations

import json
import logging
from urllib.parse import urlencode, urljoin

from bs4 import BeautifulSoup
from psycopg.types.json import Jsonb

from .assets import AssetStore
from .core import NeedsInput, Problem, Retryable, Superseded, fingerprint, new_id
from .db import Database
from .execution import Execution
from .parsing import label_key, normalize_image, parse_pdf, render_pdf_region
from .queue import DurableQueue
from .sources import Fetcher, crossref_work, parse_arxiv, resolve_reference, upsert_work

log = logging.getLogger(__name__)


class Runtime:
    def __init__(self, settings):
        self.settings = settings
        self.db = Database(settings.database_url)
        self.assets = AssetStore(settings.state_dir)
        self.queue = DurableQueue(settings)
        self.execution = Execution(self.db, self.queue)
        self.fetcher = Fetcher(settings, self.db)

    def version(self, identifier):
        with self.db.connect() as conn:
            row = conn.execute("SELECT * FROM work_versions WHERE id=%s", (identifier,)).fetchone()
            if not row:
                raise NeedsInput("论文版本不存在", code="version_missing")
            return row

    def resolve(self, attempt):
        metadata = resolve_reference(self.fetcher, attempt.input["reference"])

        def publish(conn):
            work, version = upsert_work(conn, metadata)
            html_stage = None
            if metadata.get("html_url"):
                html_stage = self.execution.add_stage(
                    conn,
                    attempt.operation_id,
                    "fetch_html",
                    {"version_id": version},
                    dependencies=[attempt.stage_id],
                )
            self.execution.add_stage(
                conn,
                attempt.operation_id,
                "fetch_pdf",
                {
                    "version_id": version,
                    "html_stage": html_stage,
                    "analyze": attempt.input.get("analyze", False),
                    "model": attempt.input.get("model"),
                },
                dependencies=[attempt.stage_id],
            )
            return {"work_id": work, "version_id": version}

        return self.execution.publish(attempt, publish)

    def fetch_html(self, attempt):
        version = self.version(attempt.input["version_id"])
        asset, warning = None, ""
        try:
            if version["html_asset"]:
                return self.execution.publish(attempt, lambda conn: {"html_asset": version["html_asset"]})
            body, _, _ = self.fetcher.get(version["metadata"]["html_url"], limit=12_000_000)
            asset = self.assets.put(body, "text/html")
        except (NeedsInput, Problem, Retryable) as error:
            warning = str(error)

        def publish(conn):
            if asset:
                self.assets.register(conn, asset)
                conn.execute(
                    "UPDATE work_versions SET html_asset=%s WHERE id=%s", (asset["sha256"], version["id"])
                )
            return {"html_available": bool(asset), "warning": warning}

        return self.execution.publish(attempt, publish)

    def fetch_pdf(self, attempt):
        version = self.version(attempt.input["version_id"])
        if version["pdf_asset"]:
            asset = None
        else:
            url = version["metadata"].get("pdf_url")
            if not url:
                raise NeedsInput("已保存论文信息；来源未提供可下载 PDF，可上传文件补充", code="pdf_required")
            body, _, _ = self.fetcher.get(url)
            if not body[:1024].lstrip().startswith(b"%PDF-"):
                raise NeedsInput("来源返回的内容不是 PDF，可上传文件补充", code="pdf_required")
            asset = self.assets.put(body, "application/pdf")

        def publish(conn):
            if asset:
                self.assets.register(conn, asset)
                conn.execute(
                    "UPDATE work_versions SET pdf_asset=%s WHERE id=%s", (asset["sha256"], version["id"])
                )
            parse_stage = self.execution.add_stage(
                conn,
                attempt.operation_id,
                "parse",
                {"version_id": version["id"], "html_stage": attempt.input.get("html_stage")},
                queue="parse",
                dependencies=[attempt.stage_id],
            )
            if attempt.input.get("analyze"):
                self.plan_analysis(
                    conn, attempt.operation_id, version["work_id"], attempt.input.get("model"), [parse_stage]
                )
            self.db.emit(conn, "work.changed", version["work_id"])
            return {"work_id": version["work_id"], "pdf_available": True}

        return self.execution.publish(attempt, publish)

    def plan_analysis(self, conn, operation, work_id, model, dependencies=()):
        generation = conn.execute(
            "UPDATE works SET desired_analysis_generation=desired_analysis_generation+1 WHERE id=%s RETURNING desired_analysis_generation",
            (work_id,),
        ).fetchone()["desired_analysis_generation"]
        return self.execution.add_stage(
            conn,
            operation,
            "analyze",
            {
                "work_id": work_id,
                "generation": generation,
                "model": model or self.db.setting(conn, "model_config", {}),
            },
            queue="model",
            dependencies=dependencies,
        )

    def parse(self, attempt):
        version = self.version(attempt.input["version_id"])
        if not version["pdf_asset"]:
            raise NeedsInput("请先取得 PDF", code="pdf_required")
        data = parse_pdf(
            self.assets.path(version["pdf_asset"]),
            self.settings,
            fingerprint([version["id"], version["pdf_asset"]]),
        )
        artifact = self.assets.put_json(data)

        def publish(conn):
            self.assets.register(conn, artifact)
            conn.execute(
                """INSERT INTO documents(id,version_id,input_hash,parser,parser_version,structure_quality,page_count,artifact_sha,warnings)
                VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT(id) DO NOTHING""",
                (
                    data["id"],
                    version["id"],
                    version["pdf_asset"],
                    data["parser"],
                    data["parser_version"],
                    data["structure_quality"],
                    data["page_count"],
                    artifact["sha256"],
                    Jsonb(data["warnings"]),
                ),
            )
            for block in data["blocks"]:
                conn.execute(
                    """INSERT INTO blocks(id,document_id,ordinal,kind,page,text,bbox,heading) VALUES(%s,%s,%s,%s,%s,%s,%s,%s)
                    ON CONFLICT(id) DO NOTHING""",
                    (
                        block["id"],
                        data["id"],
                        block["ordinal"],
                        block["kind"],
                        block["page"],
                        block["text"],
                        Jsonb(block["bbox"]),
                        block["heading"],
                    ),
                )
            for figure in data["figures"]:
                conn.execute(
                    """INSERT INTO figures(id,document_id,label,caption,page,bbox,provenance) VALUES(%s,%s,%s,%s,%s,%s,%s)
                    ON CONFLICT(id) DO NOTHING""",
                    (
                        figure["id"],
                        data["id"],
                        figure["label"],
                        figure["caption"],
                        figure["page"],
                        Jsonb(figure["bbox"]),
                        Jsonb(
                            {"region_quality": figure["region_quality"], "pdf_sha256": version["pdf_asset"]}
                        ),
                    ),
                )
                dependencies = [attempt.stage_id] + (
                    [attempt.input["html_stage"]] if attempt.input.get("html_stage") else []
                )
                self.execution.add_stage(
                    conn,
                    attempt.operation_id,
                    "figure",
                    {"figure_id": figure["id"], "generation": 0},
                    queue="io",
                    dependencies=dependencies,
                )
            conn.execute(
                """UPDATE works SET current_document_id=%s,revision=revision+1,updated_at=now()
                WHERE id=%s AND current_version_id=%s""",
                (data["id"], version["work_id"], version["id"]),
            )
            self.db.emit(conn, "work.changed", version["work_id"])
            return {
                "work_id": version["work_id"],
                "document_id": data["id"],
                "blocks": len(data["blocks"]),
                "figures": len(data["figures"]),
                "quality": data["structure_quality"],
                "warnings": data["warnings"],
            }

        return self.execution.publish(attempt, publish)

    def figure(self, attempt):
        with self.db.connect() as conn:
            figure = conn.execute(
                """SELECT f.*,v.pdf_asset,v.html_asset,v.metadata,v.work_id FROM figures f
                JOIN documents d ON d.id=f.document_id JOIN work_versions v ON v.id=d.version_id WHERE f.id=%s""",
                (attempt.input["figure_id"],),
            ).fetchone()
        if figure["desired_generation"] != attempt.input.get("generation", 0):
            raise Superseded()
        body, provenance, warning = None, {}, ""
        if figure["html_asset"] and not attempt.input.get("bbox"):
            try:
                html = BeautifulSoup(self.assets.path(figure["html_asset"]).read_bytes(), "lxml")
                for candidate in html.select("figure"):
                    caption = candidate.find("figcaption")
                    if not caption or label_key(caption.get_text(" ", strip=True)) != figure["label"]:
                        continue
                    images = candidate.select("img[src]")
                    # Multi-panel HTML can have separate assets; a layout crop preserves their arrangement.
                    if len(images) != 1:
                        warning = "HTML figure has multiple panels; using PDF layout"
                        break
                    url = urljoin(figure["metadata"].get("html_url", ""), images[0]["src"])
                    raw, media_type, final_url = self.fetcher.get(url, limit=20_000_000)
                    body, dimensions = normalize_image(raw, media_type)
                    provenance = {
                        "method": "source_image",
                        "url": final_url,
                        "source_asset": self.assets.put(raw, media_type),
                        **dimensions,
                    }
                    break
            except Exception as error:
                warning = "Source image unavailable: " + type(error).__name__
        if body is None:
            bbox = attempt.input.get("bbox") or figure["bbox"]
            page = attempt.input.get("page") or figure["page"]
            try:
                body, dimensions = render_pdf_region(
                    self.assets.path(figure["pdf_asset"]), page, bbox or None
                )
            except NeedsInput:
                if attempt.input.get("bbox"):
                    raise
                bbox = {}
                warning = "Layout region could not be rendered reliably; showing the source page"
                body, dimensions = render_pdf_region(self.assets.path(figure["pdf_asset"]), page)
            provenance = {
                "method": "manual_region"
                if attempt.input.get("bbox")
                else "pdf_region"
                if bbox
                else "pdf_page_fallback",
                **dimensions,
            }
        provenance.update(pdf_sha256=figure["pdf_asset"], warning=warning)
        asset = self.assets.put(body, "image/png")

        def publish(conn):
            self.assets.register(conn, asset)
            if provenance.get("source_asset"):
                self.assets.register(conn, provenance["source_asset"])
            updated = conn.execute(
                """UPDATE figures SET asset_sha=%s,status=%s,provenance=%s,error='',revision=revision+1,
                page=%s,bbox=%s WHERE id=%s AND revision=%s AND desired_generation=%s RETURNING id""",
                (
                    asset["sha256"],
                    "page_fallback" if provenance["method"] == "pdf_page_fallback" else "ready",
                    Jsonb(provenance),
                    provenance.get("page", figure["page"]),
                    Jsonb(attempt.input.get("bbox") or figure["bbox"]),
                    figure["id"],
                    figure["revision"],
                    attempt.input.get("generation", 0),
                ),
            ).fetchone()
            if not updated:
                raise Superseded()
            self.db.emit(conn, "work.changed", figure["work_id"])
            return {"figure_id": figure["id"], "method": provenance["method"]}

        return self.execution.publish(attempt, publish)

    def discover(self, attempt):
        source, query, limit = attempt.input["source"], attempt.input["query"], attempt.input.get("limit", 15)
        page = attempt.input.get("page", 0)
        if source == "arxiv":
            parameters = {
                "search_query": query,
                "start": page * limit,
                "max_results": limit,
                "sortBy": "submittedDate",
                "sortOrder": "descending",
            }
            body, _, _ = self.fetcher.get(
                "https://export.arxiv.org/api/query?" + urlencode(parameters), limit=8_000_000
            )
            entries = parse_arxiv(body)
        else:
            parameters = {
                "query": query,
                "rows": limit,
                "offset": page * limit,
                "sort": "published",
                "order": "desc",
            }
            body, _, _ = self.fetcher.get(
                "https://api.crossref.org/works?" + urlencode(parameters), limit=8_000_000
            )
            entries = [crossref_work(item) for item in json.loads(body)["message"]["items"]]
        raw = self.assets.put(body, "application/xml" if source == "arxiv" else "application/json")

        def publish(conn):
            self.assets.register(conn, raw)
            question_id = attempt.input.get("question_id")
            if question_id:
                conn.execute("SELECT id FROM research_questions WHERE id=%s FOR UPDATE", (question_id,))
            works = []
            for metadata in entries:
                work, _ = upsert_work(conn, metadata, collection="candidates")
                works.append(work)
                if attempt.input.get("question_id"):
                    conn.execute(
                        "INSERT INTO question_works VALUES(%s,%s,%s) ON CONFLICT DO NOTHING",
                        (attempt.input["question_id"], work, f"Matched {source} query: {query}"),
                    )
            if question_id and works:
                conn.execute(
                    "UPDATE research_questions SET revision=revision+1,updated_at=now() WHERE id=%s",
                    (question_id,),
                )
                self.db.emit(conn, "question.changed", question_id)
            coverage = {
                "status": "bounded_query",
                "page": page,
                "limit": limit,
                "returned": len(entries),
                "raw_asset": raw["sha256"],
                "complete_history": False,
                "query": query,
            }
            conn.execute(
                """INSERT INTO source_checkpoints(source,scope,cursor,coverage) VALUES(%s,%s,%s,%s)
                ON CONFLICT(source,scope) DO UPDATE SET cursor=excluded.cursor,coverage=excluded.coverage,updated_at=now()""",
                (source, fingerprint(query), Jsonb({"next_page": page + 1}), Jsonb(coverage)),
            )
            conn.execute(
                "INSERT INTO source_requests(id,operation_id,source,query,status,result) VALUES(%s,%s,%s,%s,'succeeded',%s)",
                (new_id(), attempt.operation_id, source, Jsonb(attempt.input), Jsonb(coverage)),
            )
            self.db.emit(conn, "library.changed", "candidates")
            return {"source": source, "works": works, "coverage": coverage}

        return self.execution.publish(attempt, publish)

    def analyze(self, attempt):
        from .analysis import analyze_work

        return analyze_work(self, attempt)

    def compare(self, attempt):
        from .analysis import compare_question

        return compare_question(self, attempt)


def execute_stage(settings, stage_id, job_id, job_attempts=0):
    runtime = Runtime(settings)
    attempt = runtime.execution.begin(stage_id, job_id)
    if not attempt:
        return
    try:
        handler = getattr(runtime, attempt.kind, None)
        if not handler or attempt.kind.startswith("_"):
            raise NeedsInput("不支持的处理阶段", code="unknown_stage")
        handler(attempt)
    except Superseded:
        runtime.execution.supersede(attempt)
    except Retryable as error:
        terminal = job_attempts >= 3
        runtime.execution.fail(attempt, code=error.code, message=str(error), terminal=terminal)
        if not terminal:
            raise
    except (NeedsInput, Problem) as error:
        runtime.execution.fail(attempt, code=error.code, message=str(error), needs_input=True)
    except Exception:
        log.exception("Stage failed: %s", stage_id)
        runtime.execution.fail(
            attempt, code="processing_failed", message="处理失败；已保留完成的材料，可重试此阶段"
        )
