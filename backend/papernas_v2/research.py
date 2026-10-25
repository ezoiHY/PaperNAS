from __future__ import annotations

from typing import Literal

from psycopg.types.json import Jsonb
from pydantic import BaseModel, ConfigDict, Field, model_validator

from .analysis import normalized
from .core import Problem, new_id
from .db import Database


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class QuestionInput(Input):
    title: str = Field(min_length=1, max_length=300)
    context: str = Field(default="", max_length=20000)
    constraints: str = Field(default="", max_length=10000)
    status: Literal["active", "paused", "completed"] = "active"
    revision: int | None = None


class EvidenceInput(Input):
    work_id: str
    block_id: str | None = None
    figure_id: str | None = None
    quote: str = Field(default="", max_length=20000)
    note: str = Field(default="", max_length=10000)
    relation: Literal["supports", "contradicts", "context"] = "context"

    @model_validator(mode="after")
    def source_required(self):
        if not self.block_id and not self.figure_id:
            raise ValueError("A source block or figure is required")
        return self


class JudgmentInput(Input):
    statement: str = Field(min_length=1, max_length=10000)
    rationale: str = Field(default="", max_length=10000)
    next_step: str = Field(default="", max_length=10000)
    status: Literal["tentative", "accepted", "revised"] = "tentative"
    evidence_ids: list[str] = Field(default_factory=list, max_length=100)
    revision: int | None = None


class ActionInput(Input):
    judgment_id: str | None = None
    title: str = Field(min_length=1, max_length=300)
    hypothesis: str = Field(default="", max_length=10000)
    method: str = Field(default="", max_length=20000)
    baseline: str = Field(default="", max_length=10000)
    metrics: str = Field(default="", max_length=10000)
    success_criterion: str = Field(default="", max_length=10000)
    stop_condition: str = Field(default="", max_length=10000)
    resource_budget: str = Field(default="", max_length=5000)
    status: Literal["planned", "running", "completed", "abandoned"] = "planned"
    revision: int | None = None


class ResultInput(Input):
    judgment_id: str | None = None
    action_id: str | None = None
    title: str = Field(min_length=1, max_length=300)
    outcome: Literal["supports", "contradicts", "inconclusive", "observation"] = "observation"
    body: str = Field(min_length=1, max_length=30000)
    metrics: dict = Field(default_factory=dict)
    artifact_url: str = Field(default="", max_length=2000)


class SnapshotInput(Input):
    title: str = Field(min_length=1, max_length=300)
    understanding: str = Field(min_length=1, max_length=30000)
    open_questions: str = Field(default="", max_length=20000)
    next_focus: str = Field(default="", max_length=10000)
    evidence_ids: list[str] = Field(default_factory=list, max_length=100)


def question(conn, identifier, *, lock=False):
    row = conn.execute(
        "SELECT * FROM research_questions WHERE id=%s" + (" FOR UPDATE" if lock else ""), (identifier,)
    ).fetchone()
    if not row:
        raise Problem("question_missing", "研究问题不存在", 404)
    return row


def changed(conn, identifier):
    revision = conn.execute(
        "UPDATE research_questions SET revision=revision+1,updated_at=now() WHERE id=%s RETURNING revision",
        (identifier,),
    ).fetchone()["revision"]
    Database.emit(conn, "question.changed", identifier, revision)


def verify_evidence(conn, question_id, identifiers):
    found = {
        r["id"]
        for r in conn.execute(
            "SELECT id FROM evidence WHERE question_id=%s AND id=ANY(%s)", (question_id, identifiers)
        ).fetchall()
    }
    if found != set(identifiers):
        raise Problem("evidence_scope_mismatch", "所选证据不属于当前研究问题")


def verify_related(conn, table, identifier, question_id):
    if (
        identifier
        and not conn.execute(
            f"SELECT id FROM {table} WHERE id=%s AND question_id=%s", (identifier, question_id)
        ).fetchone()
    ):
        raise Problem("research_scope_mismatch", "所选研究记录不属于当前问题")


def create_question(conn, body):
    identifier = new_id()
    row = conn.execute(
        "INSERT INTO research_questions(id,title,context,constraints,status) VALUES(%s,%s,%s,%s,%s) RETURNING *",
        (identifier, body.title, body.context, body.constraints, body.status),
    ).fetchone()
    Database.emit(conn, "question.changed", identifier, 1)
    return row


def update_question(conn, identifier, body):
    old = question(conn, identifier, lock=True)
    if body.revision != old["revision"]:
        raise Problem("revision_conflict", "研究问题已更新，请刷新后再保存", 409, current=old)
    conn.execute(
        "UPDATE research_questions SET title=%s,context=%s,constraints=%s,status=%s WHERE id=%s",
        (body.title, body.context, body.constraints, body.status, identifier),
    )
    changed(conn, identifier)
    return question(conn, identifier)


def detail(conn, identifier):
    result = question(conn, identifier)
    result["works"] = conn.execute(
        """SELECT w.id,w.title,w.authors,w.current_document_id,w.source_url,qw.reason FROM question_works qw
        JOIN works w ON w.id=qw.work_id WHERE qw.question_id=%s ORDER BY w.created_at,w.id""",
        (identifier,),
    ).fetchall()
    result["evidence"] = conn.execute(
        """SELECT e.*,w.title AS work_title,coalesce((e.source_anchor->>'page')::integer,b.page,f.page) AS page,
        f.label AS figure_label,v.pdf_asset AS pdf_sha256,w.current_document_id<>e.document_id AS source_is_older
        FROM evidence e JOIN works w ON w.id=e.work_id JOIN documents d ON d.id=e.document_id
        JOIN work_versions v ON v.id=d.version_id LEFT JOIN blocks b ON b.id=e.block_id LEFT JOIN figures f ON f.id=e.figure_id
        WHERE e.question_id=%s ORDER BY e.created_at,e.id""",
        (identifier,),
    ).fetchall()
    for key, table in [
        ("judgments", "judgments"),
        ("actions", "research_actions"),
        ("results", "research_results"),
        ("snapshots", "research_snapshots"),
    ]:
        result[key] = conn.execute(
            f"SELECT * FROM {table} WHERE question_id=%s ORDER BY created_at DESC,id", (identifier,)
        ).fetchall()
    result["comparisons"] = conn.execute(
        "SELECT id,kind,data,created_at FROM analyses WHERE question_id=%s ORDER BY created_at DESC LIMIT 30",
        (identifier,),
    ).fetchall()
    return result


def link_work(conn, question_id, work_id, reason):
    question(conn, question_id, lock=True)
    if not conn.execute("SELECT id FROM works WHERE id=%s AND deleted_at IS NULL", (work_id,)).fetchone():
        raise Problem("work_missing", "论文不存在", 404)
    conn.execute(
        "INSERT INTO question_works VALUES(%s,%s,%s) ON CONFLICT(question_id,work_id) DO UPDATE SET reason=excluded.reason",
        (question_id, work_id, reason),
    )
    changed(conn, question_id)
    return {"question_id": question_id, "work_id": work_id}


def create_evidence(conn, question_id, body):
    question(conn, question_id, lock=True)
    document_id, text, anchor = None, "", {}
    for table, identifier in [("blocks", body.block_id), ("figures", body.figure_id)]:
        if not identifier:
            continue
        source = conn.execute(
            f"""SELECT s.*,v.work_id FROM {table} s JOIN documents d ON d.id=s.document_id
            JOIN work_versions v ON v.id=d.version_id WHERE s.id=%s""",
            (identifier,),
        ).fetchone()
        if (
            not source
            or source["work_id"] != body.work_id
            or document_id
            and document_id != source["document_id"]
        ):
            raise Problem("evidence_source_mismatch", "证据必须来自所选论文的同一文档版本")
        document_id = source["document_id"]
        if table == "blocks":
            text = source["text"]
        elif not text:
            text = source["caption"]
        if not anchor:
            anchor = {
                "page": source["page"],
                "bbox": source["bbox"],
                "asset_sha": source.get("asset_sha"),
                "revision": source.get("revision", 1),
            }
    quote = body.quote or text
    if normalized(quote) not in normalized(text):
        raise Problem("quote_mismatch", "摘录与所选原文不一致；个人解释请写在证据备注中")
    row = conn.execute(
        """INSERT INTO evidence(id,question_id,work_id,document_id,block_id,figure_id,quote,note,relation,source_anchor)
        VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
        (
            new_id(),
            question_id,
            body.work_id,
            document_id,
            body.block_id,
            body.figure_id,
            quote,
            body.note,
            body.relation,
            Jsonb(anchor),
        ),
    ).fetchone()
    conn.execute(
        "INSERT INTO question_works VALUES(%s,%s,'Saved evidence') ON CONFLICT DO NOTHING",
        (question_id, body.work_id),
    )
    changed(conn, question_id)
    return row


def save_judgment(conn, question_id, body, identifier=None):
    question(conn, question_id, lock=True)
    verify_evidence(conn, question_id, body.evidence_ids)
    if body.status == "accepted" and not body.evidence_ids:
        raise Problem("evidence_required", "确认研究判断前请关联至少一条证据；暂无证据时可保存为待验证")
    if identifier:
        old = conn.execute(
            "SELECT * FROM judgments WHERE id=%s AND question_id=%s FOR UPDATE", (identifier, question_id)
        ).fetchone()
        if not old:
            raise Problem("judgment_missing", "判断不存在", 404)
        if body.revision != old["revision"]:
            raise Problem("revision_conflict", "判断已被更新，请刷新后再保存", 409, current=old)
        import json

        from .core import canonical

        conn.execute(
            "INSERT INTO judgment_history(judgment_id,revision,snapshot) VALUES(%s,%s,%s)",
            (identifier, old["revision"], Jsonb(json.loads(canonical(old)))),
        )
        row = conn.execute(
            """UPDATE judgments SET statement=%s,rationale=%s,next_step=%s,status=%s,evidence_ids=%s,revision=revision+1,updated_at=now()
            WHERE id=%s RETURNING *""",
            (
                body.statement,
                body.rationale,
                body.next_step,
                body.status,
                Jsonb(body.evidence_ids),
                identifier,
            ),
        ).fetchone()
    else:
        row = conn.execute(
            """INSERT INTO judgments(id,question_id,statement,rationale,next_step,status,evidence_ids)
            VALUES(%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
            (
                new_id(),
                question_id,
                body.statement,
                body.rationale,
                body.next_step,
                body.status,
                Jsonb(body.evidence_ids),
            ),
        ).fetchone()
    changed(conn, question_id)
    return row


def save_action(conn, question_id, body, identifier=None):
    question(conn, question_id, lock=True)
    verify_related(conn, "judgments", body.judgment_id, question_id)
    values = body.model_dump(exclude={"revision"})
    if identifier:
        old = conn.execute(
            "SELECT * FROM research_actions WHERE id=%s AND question_id=%s FOR UPDATE",
            (identifier, question_id),
        ).fetchone()
        if not old:
            raise Problem("action_missing", "验证计划不存在", 404)
        if body.revision != old["revision"]:
            raise Problem("revision_conflict", "计划已更新，请刷新后再保存", 409, current=old)
        # Field names come exclusively from the fixed Pydantic model.
        assignments = ",".join(f"{key}=%s" for key in values)
        row = conn.execute(
            f"UPDATE research_actions SET {assignments},revision=revision+1,updated_at=now() WHERE id=%s RETURNING *",
            (*values.values(), identifier),
        ).fetchone()
    else:
        fields = ",".join(values)
        placeholders = ",".join(["%s"] * len(values))
        row = conn.execute(
            f"INSERT INTO research_actions(id,question_id,{fields}) VALUES(%s,%s,{placeholders}) RETURNING *",
            (new_id(), question_id, *values.values()),
        ).fetchone()
    changed(conn, question_id)
    return row


def create_result(conn, question_id, body):
    question(conn, question_id, lock=True)
    verify_related(conn, "judgments", body.judgment_id, question_id)
    verify_related(conn, "research_actions", body.action_id, question_id)
    if body.artifact_url and not body.artifact_url.startswith(("https://", "http://")):
        raise Problem("invalid_artifact_url", "结果链接需为 HTTP(S) 地址")
    row = conn.execute(
        """INSERT INTO research_results(id,question_id,judgment_id,action_id,title,outcome,body,metrics,artifact_url)
        VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
        (
            new_id(),
            question_id,
            body.judgment_id,
            body.action_id,
            body.title,
            body.outcome,
            body.body,
            Jsonb(body.metrics),
            body.artifact_url,
        ),
    ).fetchone()
    changed(conn, question_id)
    return row


def create_snapshot(conn, question_id, body):
    current = question(conn, question_id, lock=True)
    verify_evidence(conn, question_id, body.evidence_ids)
    row = conn.execute(
        """INSERT INTO research_snapshots(id,question_id,title,understanding,open_questions,next_focus,evidence_ids,question_revision)
        VALUES(%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
        (
            new_id(),
            question_id,
            body.title,
            body.understanding,
            body.open_questions,
            body.next_focus,
            Jsonb(body.evidence_ids),
            current["revision"],
        ),
    ).fetchone()
    changed(conn, question_id)
    return row


def export_markdown(conn, question_id):
    data = detail(conn, question_id)
    lines = [
        "# " + data["title"],
        "",
        f"Revision: {data['revision']} · Status: {data['status']}",
        "",
        data["context"],
        "",
        "## Constraints",
        "",
        data["constraints"] or "Not recorded.",
        "",
        "## Sources",
        "",
    ]
    for work in data["works"]:
        lines.append(
            f"- {work['title']} — {work['source_url']}\n  Reason: {work['reason'] or 'Not recorded.'}"
        )
    lines += ["", "## Evidence", ""]
    for evidence in data["evidence"]:
        page = f"p. {evidence['page']}" if evidence["page"] is not None else "PDF 页码未知"
        lines += [
            f"### {evidence['work_title']} · {page}",
            "",
            f"Evidence `{evidence['id']}` · {evidence['relation']} · PDF SHA-256 `{evidence['pdf_sha256']}`",
            "",
            "> " + evidence["quote"].replace("\n", "\n> "),
            "",
            evidence["note"],
            "",
        ]
    lines += ["## Research judgments", ""]
    for judgment in data["judgments"]:
        lines += [
            "### " + judgment["statement"],
            "",
            f"Status: {judgment['status']} · Revision: {judgment['revision']}",
            "",
            judgment["rationale"],
            "",
            "Evidence: " + ", ".join(judgment["evidence_ids"]),
            "",
            "Next step: " + judgment["next_step"],
            "",
        ]
    lines += ["## Validation plans", ""]
    for action in data["actions"]:
        lines += ["### " + action["title"], "", "Status: " + action["status"], ""]
        for key in (
            "hypothesis",
            "method",
            "baseline",
            "metrics",
            "success_criterion",
            "stop_condition",
            "resource_budget",
        ):
            lines += [f"**{key.replace('_', ' ').capitalize()}**: {action[key] or 'Not recorded.'}", ""]
    lines += ["## Recorded results", ""]
    for result in data["results"]:
        lines += [
            "### " + result["title"],
            "",
            f"Outcome: {result['outcome']} · Recorded: {result['created_at'].isoformat()}",
            "",
            result["body"],
            "",
            result["artifact_url"],
            "",
        ]
    lines += ["## Understanding snapshots", ""]
    for snapshot in data["snapshots"]:
        lines += [
            "### " + snapshot["title"],
            "",
            snapshot["understanding"],
            "",
            "Open questions: " + snapshot["open_questions"],
            "",
            "Next focus: " + snapshot["next_focus"],
            "",
        ]
    if data["comparisons"]:
        lines += [
            "## Latest generated comparison (review required)",
            "",
            data["comparisons"][0]["data"].get("markdown", ""),
        ]
    return "\n".join(lines)
