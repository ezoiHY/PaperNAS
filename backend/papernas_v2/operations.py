from __future__ import annotations

from typing import Annotated, Literal

from pydantic import Field

from .core import Problem
from .library import work_row
from .research import Input, question


class OperationInput(Input):
    kind: Literal["import", "extract", "analyze", "discover", "compare", "repair_figure"]
    reference: str = Field(default="", max_length=3000)
    work_ids: list[str] = Field(default_factory=list, max_length=100)
    question_id: str | None = None
    query: str = Field(default="", max_length=2000)
    source_queries: dict[Literal["arxiv", "crossref"], Annotated[str, Field(max_length=2000)]] = Field(
        default_factory=dict
    )
    sources: list[Literal["arxiv", "crossref"]] = Field(default_factory=lambda: ["arxiv"])
    limit: int = Field(default=15, ge=1, le=100)
    page: int = Field(default=0, ge=0, le=100)
    analyze: bool = False
    dimensions: str = Field(default="method, evidence, conditions, limitations", max_length=4000)
    figure_id: str | None = None
    bbox: dict[str, float] | None = None
    figure_page: int | None = Field(default=None, ge=1, le=500)
    token_budget: int = Field(default=120000, ge=0, le=2000000)


def create_operation(runtime, conn, body):
    model = runtime.db.setting(conn, "model_config", {})
    operation = runtime.execution.create_operation(
        conn, body.kind, body.model_dump(), budget=body.token_budget
    )
    if body.kind == "import":
        if not body.reference:
            raise Problem("reference_required", "请输入论文链接、DOI 或 arXiv ID")
        runtime.execution.add_stage(
            conn, operation, "resolve", {"reference": body.reference, "analyze": body.analyze, "model": model}
        )
    elif body.kind in {"extract", "analyze"}:
        if not body.work_ids:
            raise Problem("works_required", "请先选择论文")
        for work_id in dict.fromkeys(body.work_ids):
            work = work_row(conn, work_id)
            if body.kind == "analyze" and work["current_document_id"]:
                runtime.plan_analysis(conn, operation, work_id, model)
            else:
                if not work["current_version_id"]:
                    raise Problem("version_missing", "此论文没有材料版本")
                version = conn.execute(
                    "SELECT * FROM work_versions WHERE id=%s", (work["current_version_id"],)
                ).fetchone()
                html_stage = None
                if version["metadata"].get("html_url"):
                    html_stage = runtime.execution.add_stage(
                        conn, operation, "fetch_html", {"version_id": version["id"]}
                    )
                runtime.execution.add_stage(
                    conn,
                    operation,
                    "fetch_pdf",
                    {
                        "version_id": version["id"],
                        "html_stage": html_stage,
                        "analyze": body.kind == "analyze",
                        "model": model,
                    },
                )
    elif body.kind == "discover":
        if not body.query or not body.sources:
            raise Problem("query_required", "请填写检索式并选择来源")
        if body.question_id:
            question(conn, body.question_id)
        for source in dict.fromkeys(body.sources):
            runtime.execution.add_stage(
                conn,
                operation,
                "discover",
                {
                    "query": body.source_queries.get(source) or body.query,
                    "source": source,
                    "limit": body.limit,
                    "page": body.page,
                    "question_id": body.question_id,
                },
            )
    elif body.kind == "compare":
        if not body.question_id:
            raise Problem("question_required", "请选择研究问题")
        question(conn, body.question_id, lock=True)
        generation = conn.execute(
            "UPDATE research_questions SET desired_comparison_generation=desired_comparison_generation+1 WHERE id=%s RETURNING desired_comparison_generation",
            (body.question_id,),
        ).fetchone()["desired_comparison_generation"]
        runtime.execution.add_stage(
            conn,
            operation,
            "compare",
            {
                "question_id": body.question_id,
                "dimensions": body.dimensions,
                "model": model,
                "generation": generation,
            },
            queue="model",
        )
    else:
        if (
            not body.figure_id
            or not conn.execute("SELECT id FROM figures WHERE id=%s", (body.figure_id,)).fetchone()
        ):
            raise Problem("figure_missing", "图表不存在", 404)
        if body.bbox and (
            set(body.bbox) != {"x0", "y0", "x1", "y1"}
            or body.bbox["x1"] <= body.bbox["x0"]
            or body.bbox["y1"] <= body.bbox["y0"]
        ):
            raise Problem("invalid_bbox", "请提供有效的 PDF 页面坐标范围")
        generation = conn.execute(
            "UPDATE figures SET desired_generation=desired_generation+1 WHERE id=%s RETURNING desired_generation",
            (body.figure_id,),
        ).fetchone()["desired_generation"]
        runtime.execution.add_stage(
            conn,
            operation,
            "figure",
            {
                "figure_id": body.figure_id,
                "bbox": body.bbox,
                "page": body.figure_page,
                "generation": generation,
            },
        )
    return runtime.execution.get(conn, operation)


def native_job(runtime, conn, payload):
    action = payload.get("action", "")
    keys = payload.get("keys") or ([payload["key"]] if payload.get("key") else [])
    common = {"work_ids": keys, "token_budget": payload.get("token_budget", 120000)}
    if action in {"inspect", "add_candidate"}:
        body = OperationInput(
            kind="import",
            reference=payload.get("reference")
            or payload.get("url")
            or payload.get("input")
            or payload.get("identifier")
            or "",
            analyze=action == "inspect",
        )
    elif action in {"analyze_paper", "analyze_selected", "brief_paper", "summarize_paper"}:
        body = OperationInput(kind="analyze", **common)
    elif action in {"extract_paper", "extract_selected"}:
        body = OperationInput(kind="extract", **common)
    elif action in {"daily", "collect", "check_sources"}:
        config = runtime.db.setting(conn, "discovery_config", {})
        body = OperationInput(
            kind="discover",
            query=payload.get("query") or config.get("query", ""),
            sources=config.get("sources", ["arxiv"]),
            limit=config.get("limit", 15),
        )
    else:
        raise Problem("action_unavailable", "此操作尚未在新后端启用，请选择论文范围或使用研究空间")
    operation = create_operation(runtime, conn, body)
    return {"job": operation, "operation": operation, "id": operation["id"]}
