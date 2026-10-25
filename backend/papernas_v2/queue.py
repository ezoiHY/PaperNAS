from __future__ import annotations

import asyncio

import procrastinate
from procrastinate import retry

from .core import Retryable
from .settings import Settings


class StageRetry(retry.BaseRetryStrategy):
    def get_retry_decision(self, *, exception, job):
        if isinstance(exception, Retryable) and job.attempts < 3:
            return retry.RetryDecision(retry_in={"seconds": max(1, exception.delay)})
        return None


class DurableQueue:
    def __init__(self, settings: Settings, *, asynchronous=False):
        self.settings = settings
        connector_type = (
            procrastinate.PsycopgConnector if asynchronous else procrastinate.SyncPsycopgConnector
        )
        self.app = procrastinate.App(connector=connector_type(conninfo=settings.database_url))

        @self.app.task(name="papernas.execute_stage", queue="io", retry=StageRetry(), pass_context=True)
        async def stage(context, stage_id: str):
            from .runtime import execute_stage

            await asyncio.to_thread(execute_stage, settings, stage_id, context.job.id, context.job.attempts)

        self.task = stage

    def migrate(self, db):
        with db.connect() as conn:
            conn.execute("SELECT pg_advisory_xact_lock(72024002)")
            if not conn.execute("SELECT to_regclass('public.procrastinate_jobs') AS name").fetchone()["name"]:
                conn.execute("SET LOCAL search_path=public")
                conn.execute(self.app.schema_manager.get_schema())

    def enqueue(self, conn, stage_id, queue, *, priority=0, delay=0):
        # The caller owns this transaction. There is no separate broker write.
        return self.task.configure(
            connection=conn,
            queue=queue,
            lock=f"stage:{stage_id}",
            priority=priority,
            schedule_in={"seconds": delay},
        ).defer(stage_id=stage_id)

    async def run(self, *, queues=None, concurrency=2, wait=True):
        async with self.app.open_async():
            while True:
                await self.app.run_worker_async(
                    queues=queues,
                    concurrency=concurrency,
                    wait=wait,
                    fetch_job_polling_interval=1,
                    update_heartbeat_interval=5,
                    stalled_worker_timeout=self.settings.worker_stale_seconds,
                )
                if wait:
                    return
                # A drain worker may stop polling before a running parent publishes its children.
                from .db import Database

                with Database(self.settings.database_url).connect() as conn:
                    remaining = conn.execute(
                        """SELECT 1 FROM public.procrastinate_jobs WHERE status='todo'
                        AND (scheduled_at IS NULL OR scheduled_at<=now()) AND (%s::text[] IS NULL OR queue_name=ANY(%s)) LIMIT 1""",
                        (queues, queues),
                    ).fetchone()
                if not remaining:
                    return
