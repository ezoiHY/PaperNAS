from __future__ import annotations

import asyncio
import logging
from datetime import datetime
from zoneinfo import ZoneInfo

from psycopg.types.json import Jsonb

from .operations import OperationInput, create_operation
from .runtime import Runtime

log = logging.getLogger(__name__)


def recover_stalled(runtime):
    """Recover only jobs whose worker heartbeat is stale, never merely long-running jobs."""
    recovered = []
    with runtime.db.connect() as conn:
        candidates = conn.execute(
            """SELECT j.id,s.id AS stage_id,s.operation_id FROM public.procrastinate_jobs j
            JOIN stages s ON s.queue_job_id=j.id LEFT JOIN public.procrastinate_workers w ON w.id=j.worker_id
            WHERE j.status='doing' AND (w.id IS NULL OR w.last_heartbeat<now()-(%s * interval '1 second'))""",
            (runtime.settings.worker_stale_seconds,),
        ).fetchall()
    for candidate in candidates:
        with runtime.db.connect() as conn:
            conn.execute("SELECT id FROM operations WHERE id=%s FOR UPDATE", (candidate["operation_id"],))
            stage = conn.execute(
                "SELECT * FROM stages WHERE id=%s FOR UPDATE", (candidate["stage_id"],)
            ).fetchone()
            job = conn.execute(
                """SELECT j.* FROM public.procrastinate_jobs j LEFT JOIN public.procrastinate_workers w ON w.id=j.worker_id
                WHERE j.id=%s AND j.status='doing' AND (w.id IS NULL OR w.last_heartbeat<now()-(%s * interval '1 second')) FOR UPDATE OF j""",
                (candidate["id"], runtime.settings.worker_stale_seconds),
            ).fetchone()
            if not job or stage["queue_job_id"] != job["id"]:
                continue
            conn.execute(
                "UPDATE attempts SET status='interrupted',finished_at=now() WHERE stage_id=%s AND status='running'",
                (stage["id"],),
            )
            conn.execute("UPDATE stages SET generation=generation+1 WHERE id=%s", (stage["id"],))
            unknown = conn.execute(
                "UPDATE model_invocations SET state='unknown',updated_at=now() WHERE stage_id=%s AND state='sending' RETURNING id",
                (stage["id"],),
            ).fetchall()
            unknown = (
                unknown
                or conn.execute(
                    "SELECT id FROM model_invocations WHERE stage_id=%s AND state='unknown'", (stage["id"],)
                ).fetchall()
            )
            if stage["outcome"] != "pending":
                conn.execute(
                    "SELECT public.procrastinate_finish_job_v1(%s,%s,false)",
                    (job["id"], "succeeded" if stage["outcome"] == "ready" else "failed"),
                )
            elif unknown:
                conn.execute(
                    "UPDATE stages SET outcome='needs_input',error=%s WHERE id=%s",
                    (
                        Jsonb(
                            {
                                "code": "model_outcome_unknown",
                                "message": "工作进程中断时模型调用尚未确认；请核对调用记录",
                            }
                        ),
                        stage["id"],
                    ),
                )
                conn.execute("SELECT public.procrastinate_finish_job_v1(%s,'failed',false)", (job["id"],))
            elif stage["attempts"] >= 4:
                conn.execute(
                    "UPDATE stages SET outcome='failed',error=%s WHERE id=%s",
                    (
                        Jsonb(
                            {"code": "recovery_limit", "message": "工作进程多次中断，请检查服务后手动重试"}
                        ),
                        stage["id"],
                    ),
                )
                conn.execute("SELECT public.procrastinate_finish_job_v1(%s,'failed',false)", (job["id"],))
            else:
                # Procrastinate's public retry function changes queue state in this same transaction.
                conn.execute(
                    "SELECT public.procrastinate_retry_job_v2(%s,now(),NULL,NULL,NULL)", (job["id"],)
                )
            for child in conn.execute(
                "SELECT stage_id FROM stage_dependencies WHERE depends_on=%s", (stage["id"],)
            ).fetchall():
                runtime.execution._schedule(conn, child["stage_id"])
            runtime.execution.summarize(conn, stage["operation_id"])
            recovered.append(stage["id"])
    return recovered


def scheduled_discovery(runtime):
    with runtime.db.connect() as conn:
        config = runtime.db.setting(conn, "discovery_config", {})
        if not config.get("enabled") or not config.get("query"):
            return
        now = datetime.now(ZoneInfo(config.get("timezone", "Asia/Shanghai")))
        if now.strftime("%H:%M") < config.get("time", "09:00"):
            return
        body = OperationInput(
            kind="discover",
            query=config["query"],
            source_queries=config.get("source_queries", {}),
            sources=config.get("sources", ["arxiv"]),
            limit=config.get("limit", 15),
        )
        key = "daily-" + now.strftime("%Y%m%d") + "-run"
        # The same date remains the same run even when settings change later that day.
        if conn.execute("SELECT 1 FROM requests WHERE scope='scheduler:daily' AND key=%s", (key,)).fetchone():
            return
        runtime.db.idempotent(
            conn,
            "scheduler:daily",
            key,
            {"date": now.date().isoformat()},
            lambda c: (202, {"operation": create_operation(runtime, c, body)}),
        )


def tick(runtime):
    recovered = recover_stalled(runtime)
    scheduled_discovery(runtime)
    runtime.db.dispatch_events()
    with runtime.db.connect() as conn:
        runtime.db.set_setting(conn, "maintenance_heartbeat", datetime.now().astimezone().isoformat())
    return recovered


async def loop(settings):
    runtime = Runtime(settings)
    while True:
        try:
            await asyncio.to_thread(tick, runtime)
        except Exception:
            log.exception("Maintenance cycle failed; will retry")
        await asyncio.sleep(10)
