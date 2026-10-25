from __future__ import annotations

from dataclasses import dataclass

from psycopg.types.json import Jsonb

from .core import Problem, Superseded, fingerprint, new_id
from .db import Database

TERMINAL = {"ready", "failed", "cancelled", "skipped", "needs_input"}


@dataclass(frozen=True)
class Attempt:
    stage_id: str
    operation_id: str
    id: str
    generation: int
    kind: str
    input: dict
    queue_job_id: int


class Execution:
    def __init__(self, db: Database, queue):
        self.db, self.queue = db, queue

    def create_operation(self, conn, kind, payload, *, budget=120000):
        identifier = new_id()
        conn.execute(
            "INSERT INTO operations(id,kind,input,budget_limit) VALUES(%s,%s,%s,%s)",
            (identifier, kind, Jsonb(payload), budget),
        )
        self.db.emit(conn, "operation.changed", identifier)
        return identifier

    def add_stage(self, conn, operation_id, kind, payload, *, queue="io", dependencies=(), priority=0):
        identifier = new_id()
        row = conn.execute(
            """INSERT INTO stages(id,operation_id,kind,queue,input,input_hash)
            VALUES(%s,%s,%s,%s,%s,%s) ON CONFLICT(operation_id,kind,input_hash) DO NOTHING RETURNING id""",
            (identifier, operation_id, kind, queue, Jsonb(payload), fingerprint(payload)),
        ).fetchone()
        if not row:
            return conn.execute(
                "SELECT id FROM stages WHERE operation_id=%s AND kind=%s AND input_hash=%s",
                (operation_id, kind, fingerprint(payload)),
            ).fetchone()["id"]
        for parent in dependencies:
            conn.execute("INSERT INTO stage_dependencies VALUES(%s,%s)", (identifier, parent))
        self._schedule(conn, identifier, priority=priority)
        return identifier

    def _schedule(self, conn, stage_id, *, priority=0):
        stage = conn.execute(
            """SELECT s.*,o.pause_requested,o.cancel_requested FROM stages s JOIN operations o
            ON o.id=s.operation_id WHERE s.id=%s FOR UPDATE OF s""",
            (stage_id,),
        ).fetchone()
        if (
            stage["outcome"] != "pending"
            or stage["queue_job_id"] is not None
            or stage["pause_requested"]
            or stage["cancel_requested"]
        ):
            return
        parents = conn.execute(
            "SELECT s.outcome FROM stage_dependencies d JOIN stages s ON s.id=d.depends_on WHERE d.stage_id=%s",
            (stage_id,),
        ).fetchall()
        if any(x["outcome"] in {"failed", "cancelled", "skipped"} for x in parents):
            conn.execute(
                "UPDATE stages SET outcome='skipped',error=%s WHERE id=%s",
                (Jsonb({"code": "dependency_failed", "message": "前置材料尚未准备好"}), stage_id),
            )
            for child in conn.execute(
                "SELECT stage_id FROM stage_dependencies WHERE depends_on=%s", (stage_id,)
            ).fetchall():
                self._schedule(conn, child["stage_id"])
            return
        if not all(x["outcome"] == "ready" for x in parents):
            return
        job_id = self.queue.enqueue(conn, stage_id, stage["queue"], priority=priority)
        conn.execute("UPDATE stages SET queue_job_id=%s WHERE id=%s", (job_id, stage_id))

    def begin(self, stage_id, job_id) -> Attempt | None:
        with self.db.connect() as conn:
            owner = conn.execute("SELECT operation_id FROM stages WHERE id=%s", (stage_id,)).fetchone()
            if not owner:
                return None
            conn.execute("SELECT id FROM operations WHERE id=%s FOR UPDATE", (owner["operation_id"],))
            row = conn.execute(
                """SELECT s.*,o.cancel_requested,o.pause_requested FROM stages s
                JOIN operations o ON o.id=s.operation_id WHERE s.id=%s FOR UPDATE OF s""",
                (stage_id,),
            ).fetchone()
            if not row or row["outcome"] == "ready" or row["queue_job_id"] != job_id:
                return None
            if row["cancel_requested"] or row["outcome"] in {"cancelled", "skipped"}:
                conn.execute(
                    "UPDATE stages SET outcome='cancelled' WHERE id=%s AND outcome<>'ready'", (stage_id,)
                )
                self.summarize(conn, row["operation_id"])
                return None
            if row["pause_requested"]:
                conn.execute("UPDATE stages SET queue_job_id=NULL WHERE id=%s", (stage_id,))
                self.summarize(conn, row["operation_id"])
                return None
            if row["outcome"] in {"needs_input", "failed"}:
                return None
            generation = row["generation"] + 1
            attempt_id = new_id()
            conn.execute(
                "UPDATE stages SET generation=%s,attempts=attempts+1,error='{}',updated_at=now() WHERE id=%s",
                (generation, stage_id),
            )
            conn.execute(
                "INSERT INTO attempts(id,stage_id,generation) VALUES(%s,%s,%s)",
                (attempt_id, stage_id, generation),
            )
            conn.execute(
                "UPDATE operations SET state='running',updated_at=now() WHERE id=%s", (row["operation_id"],)
            )
            self.db.emit(conn, "operation.changed", row["operation_id"])
            return Attempt(
                stage_id, row["operation_id"], attempt_id, generation, row["kind"], row["input"], job_id
            )

    def check(self, conn, attempt: Attempt):
        conn.execute("SELECT id FROM operations WHERE id=%s FOR UPDATE", (attempt.operation_id,))
        row = conn.execute(
            """SELECT s.generation,s.outcome,s.queue_job_id,o.cancel_requested FROM stages s
            JOIN operations o ON o.id=s.operation_id WHERE s.id=%s FOR UPDATE OF s""",
            (attempt.stage_id,),
        ).fetchone()
        if (
            not row
            or row["generation"] != attempt.generation
            or row["cancel_requested"]
            or row["queue_job_id"] != attempt.queue_job_id
        ):
            raise Superseded()
        return row

    def publish(self, attempt: Attempt, callback):
        with self.db.connect() as conn:
            self.check(conn, attempt)
            result = callback(conn) or {}
            conn.execute(
                "UPDATE stages SET outcome='ready',result=%s,error='{}',updated_at=now() WHERE id=%s",
                (Jsonb(result), attempt.stage_id),
            )
            conn.execute(
                "UPDATE attempts SET status='succeeded',finished_at=now() WHERE id=%s", (attempt.id,)
            )
            children = conn.execute(
                "SELECT stage_id FROM stage_dependencies WHERE depends_on=%s", (attempt.stage_id,)
            ).fetchall()
            for child in children:
                self._schedule(conn, child["stage_id"])
            self.summarize(conn, attempt.operation_id)
            return result

    def supersede(self, attempt):
        with self.db.connect() as conn:
            conn.execute("SELECT id FROM operations WHERE id=%s FOR UPDATE", (attempt.operation_id,))
            conn.execute(
                "UPDATE attempts SET status='superseded',finished_at=now() WHERE id=%s", (attempt.id,)
            )
            conn.execute(
                """UPDATE stages SET outcome='skipped',error=%s WHERE id=%s AND generation=%s AND outcome='pending'""",
                (
                    Jsonb({"code": "superseded", "message": "已有较新的结果请求，此次结果未覆盖当前版本"}),
                    attempt.stage_id,
                    attempt.generation,
                ),
            )
            self.summarize(conn, attempt.operation_id)

    def fail(self, attempt: Attempt, *, code, message, terminal=True, needs_input=False):
        with self.db.connect() as conn:
            try:
                self.check(conn, attempt)
            except Superseded:
                conn.execute(
                    "UPDATE attempts SET status='superseded',finished_at=now() WHERE id=%s", (attempt.id,)
                )
                return
            outcome = "needs_input" if needs_input else "failed" if terminal else "pending"
            error = {"code": code, "message": message}
            conn.execute(
                "UPDATE stages SET outcome=%s,error=%s,updated_at=now() WHERE id=%s",
                (outcome, Jsonb(error), attempt.stage_id),
            )
            conn.execute(
                "UPDATE attempts SET status=%s,error=%s,finished_at=now() WHERE id=%s",
                ("failed" if terminal else "retrying", Jsonb(error), attempt.id),
            )
            if (terminal or needs_input) and attempt.kind == "figure":
                affected = conn.execute(
                    """UPDATE figures SET status=CASE WHEN asset_sha IS NULL THEN 'failed' ELSE status END,error=%s
                    WHERE id=%s AND desired_generation=%s RETURNING document_id""",
                    (message, attempt.input["figure_id"], attempt.input.get("generation", 0)),
                ).fetchone()
                if affected:
                    work = conn.execute(
                        "SELECT v.work_id FROM documents d JOIN work_versions v ON v.id=d.version_id WHERE d.id=%s",
                        (affected["document_id"],),
                    ).fetchone()
                    self.db.emit(conn, "work.changed", work["work_id"])
            if terminal:
                for child in conn.execute(
                    "SELECT stage_id FROM stage_dependencies WHERE depends_on=%s", (attempt.stage_id,)
                ).fetchall():
                    self._schedule(conn, child["stage_id"])
            self.summarize(conn, attempt.operation_id)

    def summarize(self, conn, operation_id):
        operation = conn.execute(
            "SELECT * FROM operations WHERE id=%s FOR UPDATE", (operation_id,)
        ).fetchone()
        rows = conn.execute(
            "SELECT outcome,result,error FROM stages WHERE operation_id=%s", (operation_id,)
        ).fetchall()
        counts = {key: sum(r["outcome"] == key for r in rows) for key in {"pending", *TERMINAL}}
        if operation["cancel_requested"]:
            state = "cancelled"
        elif operation["pause_requested"] and counts["pending"]:
            state = "paused"
        elif counts["needs_input"]:
            state = "needs_input"
        elif counts["pending"]:
            state = "running"
        elif counts["failed"] or counts["skipped"]:
            state = "completed_with_gaps" if counts["ready"] else "failed"
        else:
            state = "succeeded"
        result = {
            "counts": counts,
            "outputs": [r["result"] for r in rows if r["result"]],
            "issues": [r["error"] for r in rows if r["error"]],
        }
        conn.execute(
            "UPDATE operations SET state=%s,result=%s,updated_at=now() WHERE id=%s",
            (state, Jsonb(result), operation_id),
        )
        self.db.emit(conn, "operation.changed", operation_id, state=state)

    def control(self, conn, operation_id, action):
        operation = conn.execute(
            "SELECT * FROM operations WHERE id=%s FOR UPDATE", (operation_id,)
        ).fetchone()
        if not operation:
            raise Problem("operation_missing", "任务不存在", 404)
        if action == "cancel":
            conn.execute("UPDATE operations SET cancel_requested=true WHERE id=%s", (operation_id,))
            conn.execute(
                "UPDATE stages SET outcome='cancelled',generation=generation+1 WHERE operation_id=%s AND outcome<>'ready'",
                (operation_id,),
            )
        elif action == "pause":
            conn.execute("UPDATE operations SET pause_requested=true WHERE id=%s", (operation_id,))
        elif action in {"resume", "retry"}:
            if operation["cancel_requested"]:
                raise Problem("cancelled_operation", "已取消的操作不能恢复，请重新提交明确范围的任务", 409)
            conn.execute("UPDATE operations SET pause_requested=false WHERE id=%s", (operation_id,))
            if action == "retry":
                unknown = conn.execute(
                    """SELECT 1 FROM model_invocations m JOIN stages s ON s.id=m.stage_id
                    WHERE s.operation_id=%s AND m.state IN ('sending','unknown') LIMIT 1""",
                    (operation_id,),
                ).fetchone()
                if unknown:
                    raise Problem(
                        "unknown_model_result", "存在结果未知的模型调用，请先核对调用记录再决定是否重试", 409
                    )
                conn.execute(
                    """UPDATE stages SET outcome='pending',queue_job_id=NULL,generation=generation+1,error='{}'
                    WHERE operation_id=%s AND outcome IN ('failed','needs_input','skipped')""",
                    (operation_id,),
                )
            for row in conn.execute(
                "SELECT id FROM stages WHERE operation_id=%s AND outcome='pending'", (operation_id,)
            ).fetchall():
                self._schedule(conn, row["id"], priority=5)
        else:
            raise Problem("invalid_action", "不支持的任务操作")
        self.summarize(conn, operation_id)
        return self.get(conn, operation_id)

    def get(self, conn, operation_id):
        row = conn.execute("SELECT * FROM operations WHERE id=%s", (operation_id,)).fetchone()
        if not row:
            raise Problem("operation_missing", "任务不存在", 404)
        stages = conn.execute(
            """SELECT s.*,j.status::text AS execution_status,j.scheduled_at FROM stages s
            LEFT JOIN public.procrastinate_jobs j ON j.id=s.queue_job_id WHERE s.operation_id=%s ORDER BY s.created_at,s.id""",
            (operation_id,),
        ).fetchall()
        row["stages"] = stages
        row["id"] = operation_id
        row["status"] = row["state"]
        row["action"] = row["kind"]
        counts = row["result"].get("counts", {})
        row["progress"] = {
            "total": len(stages),
            "completed": counts.get("ready", 0),
            "failed": counts.get("failed", 0),
            "message": next((s["error"].get("message", "") for s in stages if s["error"]), ""),
        }
        return row
