from __future__ import annotations

import re

from psycopg.types.json import Jsonb
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .core import NeedsInput, Superseded, canonical, fingerprint, new_id
from .models import ModelGateway, extract_json


class Citation(BaseModel):
    model_config = ConfigDict(extra="forbid")
    block_id: str
    quote: str = Field(min_length=8, max_length=1200)


class Claim(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(min_length=1, max_length=5000)
    citations: list[Citation] = Field(min_length=1, max_length=8)


class Report(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str
    summary: Claim
    findings: list[Claim] = Field(min_length=1, max_length=12)
    limitations: list[Claim] = Field(default_factory=list, max_length=8)
    unknowns: list[str] = Field(default_factory=list, max_length=12)
    suggested_next_steps: list[str] = Field(default_factory=list, max_length=8)


def normalized(value):
    return re.sub(r"\s+", " ", value).strip()


def validate_report(response, blocks):
    try:
        report = Report.model_validate(extract_json(response))
    except ValidationError as error:
        raise NeedsInput(
            "模型响应已保存，但未通过研究输出格式校验", code="analysis_schema_invalid"
        ) from error
    lookup = {b["id"]: b for b in blocks}
    for claim in [report.summary, *report.findings, *report.limitations]:
        for citation in claim.citations:
            block = lookup.get(citation.block_id)
            if not block or normalized(citation.quote) not in normalized(block["text"]):
                raise NeedsInput(
                    "模型响应已保存，但有引用不属于所提供原文；尚未发布分析", code="citation_mismatch"
                )
    return report.model_dump()


def bounded_blocks(blocks, limit=48000):
    chosen, total = [], 0
    for block in blocks:
        size = len(block["text"])
        if total + size > limit:
            continue
        total += size
        chosen.append(
            {
                "id": block["id"],
                "page": block["page"],
                "text": block["text"],
                "heading": block.get("heading", ""),
                "work_id": block.get("work_id", ""),
            }
        )
    return chosen


def markdown_report(data, blocks):
    lookup = {b["id"]: b for b in blocks}
    references = {}

    def claim_text(claim):
        markers = []
        for citation in claim["citations"]:
            key = (citation["block_id"], citation["quote"])
            references.setdefault(key, len(references) + 1)
            markers.append(f"[^{references[key]}]")
        return claim["text"] + " " + " ".join(markers)

    lines = ["# " + data["title"], "", claim_text(data["summary"]), "", "## 主要依据", ""]
    lines += ["- " + claim_text(c) for c in data["findings"]]
    if data["limitations"]:
        lines += ["", "## 条件与局限", ""] + ["- " + claim_text(c) for c in data["limitations"]]
    if data["unknowns"]:
        lines += ["", "## 尚不能确定", ""] + ["- " + text for text in data["unknowns"]]
    if data["suggested_next_steps"]:
        lines += ["", "## 建议的下一步（尚未执行）", ""] + [
            "- " + text for text in data["suggested_next_steps"]
        ]
    lines += ["", "## 原文出处", ""]
    for (block_id, quote), number in references.items():
        block = lookup[block_id]
        page = f"p. {block['page']}" if block["page"] is not None else "PDF 页码未知"
        lines += [f"[^{number}]: {block.get('work_title', '')} · {page} · `{block_id}` — {normalized(quote)}"]
    lines += ["", "引用位置与原文摘录已经程序核对；论断是否受到充分支持仍需研究者核验。"]
    return "\n".join(lines) + "\n"


def analyze_work(runtime, attempt):
    with runtime.db.connect() as conn:
        work = conn.execute("SELECT * FROM works WHERE id=%s", (attempt.input["work_id"],)).fetchone()
        if not work["current_document_id"]:
            raise NeedsInput("请先取得并解析全文", code="document_required")
        blocks = conn.execute(
            "SELECT * FROM blocks WHERE document_id=%s ORDER BY ordinal", (work["current_document_id"],)
        ).fetchall()
    selected = bounded_blocks(blocks)
    if not selected:
        raise NeedsInput("此 PDF 尚无可引用文本，需要 OCR 或补充可读文件", code="text_required")
    prompt = (
        "Analyze this paper's problem, method, evidence, conditions and limitations. Do not infer missing experiments. Identify which observations are author claims.\n"
        + canonical(
            {
                "title": work["title"],
                "blocks": selected,
                "coverage": {"provided_blocks": len(selected), "total_blocks": len(blocks)},
            }
        )
    )
    response, invocation = ModelGateway(runtime).complete(
        attempt, purpose="paper_analysis", prompt=prompt, schema=Report.model_json_schema()
    )
    data = validate_report(response, selected)
    data.update(
        schema="papernas.report.v2",
        coverage={"selected_blocks": len(selected), "total_blocks": len(blocks)},
        invocation_id=invocation,
    )
    markdown = markdown_report(data, selected)
    data["markdown"] = markdown
    artifact = runtime.assets.put_json(data)

    def publish(conn):
        current = conn.execute(
            "SELECT desired_analysis_generation,current_document_id FROM works WHERE id=%s FOR UPDATE",
            (work["id"],),
        ).fetchone()
        if (
            current["desired_analysis_generation"] != attempt.input["generation"]
            or current["current_document_id"] != work["current_document_id"]
        ):
            raise Superseded()
        identifier = new_id()
        runtime.assets.register(conn, artifact)
        conn.execute(
            """INSERT INTO analyses(id,work_id,document_id,operation_id,kind,generation,input_hash,data,artifact_sha)
            VALUES(%s,%s,%s,%s,'paper',%s,%s,%s,%s)""",
            (
                identifier,
                work["id"],
                work["current_document_id"],
                attempt.operation_id,
                attempt.input["generation"],
                fingerprint(selected),
                Jsonb(data),
                artifact["sha256"],
            ),
        )
        conn.execute(
            "UPDATE works SET current_analysis_id=%s,revision=revision+1,updated_at=now() WHERE id=%s",
            (identifier, work["id"]),
        )
        runtime.db.emit(conn, "work.changed", work["id"])
        return {"analysis_id": identifier, "work_id": work["id"], "coverage": data["coverage"]}

    return runtime.execution.publish(attempt, publish)


def compare_question(runtime, attempt):
    with runtime.db.connect() as conn:
        question = conn.execute(
            "SELECT * FROM research_questions WHERE id=%s", (attempt.input["question_id"],)
        ).fetchone()
        materials = conn.execute(
            """SELECT w.id,w.title,w.current_document_id FROM question_works qw JOIN works w ON w.id=qw.work_id
            WHERE qw.question_id=%s ORDER BY w.id FOR SHARE OF w""",
            (question["id"],),
        ).fetchall()
        blocks = conn.execute(
            """SELECT b.*,w.id AS work_id,w.title AS work_title FROM question_works qw JOIN works w ON w.id=qw.work_id
            JOIN blocks b ON b.document_id=w.current_document_id WHERE qw.question_id=%s ORDER BY b.ordinal,w.id""",
            (question["id"],),
        ).fetchall()
    selected = bounded_blocks(blocks, 60000)
    if len({b["work_id"] for b in selected}) < 2:
        raise NeedsInput("至少关联两篇有可引用全文的论文后再比较", code="comparison_materials_required")
    prompt = (
        "Compare the supplied papers for this research question. Preserve dataset, protocol, resource and metric conditions; never rank incomparable numbers. Explain disagreements and missing evidence. Propose a minimal validation step without claiming it was executed.\n"
        + canonical(
            {
                "question": {
                    "title": question["title"],
                    "context": question["context"],
                    "constraints": question["constraints"],
                },
                "materials": materials,
                "blocks": selected,
                "dimensions": attempt.input.get("dimensions", "method, evidence, conditions, limitations"),
            }
        )
    )
    response, invocation = ModelGateway(runtime).complete(
        attempt, purpose="comparison", prompt=prompt, schema=Report.model_json_schema()
    )
    data = validate_report(response, selected)
    data.update(
        coverage={"selected_blocks": len(selected), "total_blocks": len(blocks), "materials": materials},
        invocation_id=invocation,
        question_revision=question["revision"],
    )
    data["markdown"] = markdown_report(data, blocks)
    artifact = runtime.assets.put_json(data)

    def publish(conn):
        current = conn.execute(
            "SELECT desired_comparison_generation,revision FROM research_questions WHERE id=%s FOR UPDATE",
            (question["id"],),
        ).fetchone()
        current_materials = conn.execute(
            """SELECT w.id,w.title,w.current_document_id FROM question_works qw JOIN works w ON w.id=qw.work_id
            WHERE qw.question_id=%s ORDER BY w.id FOR SHARE OF w""",
            (question["id"],),
        ).fetchall()
        if (
            current["desired_comparison_generation"] != attempt.input["generation"]
            or current["revision"] != question["revision"]
            or current_materials != materials
        ):
            raise Superseded()
        identifier = new_id()
        runtime.assets.register(conn, artifact)
        conn.execute(
            """INSERT INTO analyses(id,question_id,operation_id,kind,generation,input_hash,data,artifact_sha)
            VALUES(%s,%s,%s,'comparison',%s,%s,%s,%s)""",
            (
                identifier,
                question["id"],
                attempt.operation_id,
                attempt.input["generation"],
                fingerprint(selected),
                Jsonb(data),
                artifact["sha256"],
            ),
        )
        runtime.db.emit(conn, "question.changed", question["id"])
        return {"analysis_id": identifier, "question_id": question["id"]}

    return runtime.execution.publish(attempt, publish)
