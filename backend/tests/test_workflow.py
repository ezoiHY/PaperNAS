from __future__ import annotations

import asyncio
import hashlib
import os
import signal
import subprocess
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest
from conftest import mutate

from papernas_v2.core import Problem, Superseded
from papernas_v2.maintenance import recover_stalled, scheduled_discovery
from papernas_v2.models import save_secret
from papernas_v2.queue import DurableQueue
from papernas_v2.runtime import Runtime


def drain(settings):
    asyncio.run(DurableQueue(settings, asynchronous=True).run(concurrency=2, wait=False))


def upload(client, pdf, title="Test paper"):
    response = client.post(
        "/api/v2/imports/pdf",
        params={"title": title},
        files={"file": ("test.pdf", pdf, "application/pdf")},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert response.status_code == 202, response.text
    return response.json()


def configure_model(settings, server):
    runtime = Runtime(settings)
    with runtime.db.connect() as conn:
        runtime.db.set_setting(
            conn,
            "model_config",
            {"base_url": server["base_url"], "model": "test-model", "max_output_tokens": 1000},
        )
    save_secret(settings, "local-test-key")


def test_discovery_preserves_queries_for_each_source(client):
    response = mutate(
        client,
        "POST",
        "/operations",
        {
            "kind": "discover",
            "query": "robot learning",
            "sources": ["arxiv", "crossref"],
            "source_queries": {"arxiv": "cat:cs.RO", "crossref": "sEMG hand pose"},
        },
    )
    assert response.status_code == 202
    runtime = client.app.state.runtime
    with runtime.db.connect() as conn:
        stages = conn.execute(
            "SELECT input FROM stages WHERE operation_id=%s", (response.json()["operation"]["id"],)
        ).fetchall()
    assert {s["input"]["source"]: s["input"]["query"] for s in stages} == {
        "arxiv": "cat:cs.RO",
        "crossref": "sEMG hand pose",
    }


def test_comparison_preserves_cross_paper_sources_and_rejects_changed_materials(
    client, settings, pdf_bytes, model_server
):
    first = upload(client, pdf_bytes, "First fixture")
    second = upload(client, pdf_bytes + b"\n% second fixture\n", "Second fixture")
    drain(settings)
    assert first["work_id"] != second["work_id"]
    q = mutate(client, "POST", "/research/questions", {"title": "Matched evaluation"}).json()
    for work in (first, second):
        linked = mutate(client, "POST", f"/research/questions/{q['id']}/works", {"work_id": work["work_id"]})
        assert linked.status_code == 200, linked.text
    configure_model(settings, model_server)
    body = {"kind": "compare", "question_id": q["id"]}
    op = mutate(client, "POST", "/operations", body).json()["operation"]
    drain(settings)
    assert client.get("/api/v2/operations/" + op["id"]).json()["state"] == "succeeded"
    runtime = Runtime(settings)
    with runtime.db.connect() as conn:
        report = conn.execute("SELECT data FROM analyses WHERE question_id=%s", (q["id"],)).fetchone()["data"]
        assert len(report["findings"]) == 2
        assert "First fixture" in report["markdown"] and "Second fixture" in report["markdown"]

    def change_material():
        with runtime.db.connect() as conn:
            conn.execute("UPDATE works SET current_document_id=NULL WHERE id=%s", (second["work_id"],))

    model_server["before_response"] = change_material
    stale = mutate(client, "POST", "/operations", body).json()["operation"]
    drain(settings)
    status = client.get("/api/v2/operations/" + stale["id"]).json()
    assert status["stages"][0]["error"]["code"] == "superseded"
    with runtime.db.connect() as conn:
        assert (
            conn.execute("SELECT count(*) AS n FROM analyses WHERE question_id=%s", (q["id"],)).fetchone()[
                "n"
            ]
            == 1
        )


def test_research_workflow_survives_roundtrip(client, settings, pdf_bytes):
    imported = upload(client, pdf_bytes)
    drain(settings)
    paper = client.get("/api/v2/works/" + imported["work_id"]).json()
    assert paper["has_document"]
    assert len(paper["document"]["blocks"]) >= 4
    figure = paper["document"]["figures"][0]
    assert figure["status"] == "page_fallback"
    assert figure["provenance"]["pdf_sha256"] == hashlib.sha256(pdf_bytes).hexdigest()
    assert client.get(figure["asset_url"]).content.startswith(b"\x89PNG")
    job = client.get("/api/v2/operations/" + imported["operation"]["id"]).json()
    assert job["state"] == "succeeded", job
    question = mutate(
        client,
        "POST",
        "/research/questions",
        {"title": "Which method fits a small sample?", "constraints": "Four training examples"},
    ).json()
    block = paper["document"]["blocks"][1]
    evidence = mutate(
        client,
        "POST",
        f"/research/questions/{question['id']}/evidence",
        {
            "work_id": paper["id"],
            "block_id": block["id"],
            "quote": block["text"],
            "relation": "supports",
            "note": "Keep the evaluation condition.",
        },
    )
    assert evidence.status_code == 201, evidence.text
    judgment = mutate(
        client,
        "POST",
        f"/research/questions/{question['id']}/judgments",
        {
            "statement": "Run a matched evaluation first.",
            "status": "accepted",
            "evidence_ids": [evidence.json()["id"]],
        },
    )
    assert judgment.status_code == 201, judgment.text
    plan = mutate(
        client,
        "POST",
        f"/research/questions/{question['id']}/actions",
        {
            "title": "Independent check",
            "judgment_id": judgment.json()["id"],
            "baseline": "Existing method",
            "success_criterion": "Equal protocol, report uncertainty",
            "stop_condition": "Budget exhausted",
        },
    )
    assert plan.status_code == 201, plan.text
    result = mutate(
        client,
        "POST",
        f"/research/questions/{question['id']}/results",
        {
            "title": "Investigation log",
            "action_id": plan.json()["id"],
            "outcome": "inconclusive",
            "body": "Test fixture only; no scientific experiment was executed.",
        },
    )
    assert result.status_code == 201, result.text
    amended = mutate(
        client,
        "PATCH",
        f"/research/questions/{question['id']}/judgments/{judgment.json()['id']}",
        {
            "statement": "Still unverified.",
            "revision": 1,
            "status": "revised",
            "evidence_ids": [evidence.json()["id"]],
        },
    )
    assert amended.status_code == 200
    history = client.get(
        f"/api/v2/research/questions/{question['id']}/judgments/{judgment.json()['id']}/history"
    ).json()["history"]
    assert history[0]["snapshot"]["statement"] == "Run a matched evaluation first."
    exported = client.get(f"/api/v2/research/questions/{question['id']}/export").text
    assert (
        block["text"] in exported.replace("\n> ", "\n")
        and "Independent check" in exported
        and "inconclusive" in exported
    )
    # Reconstructing the service does not reconstruct or erase user records.
    with Runtime(settings).db.connect() as conn:
        assert conn.execute("SELECT count(*) AS n FROM research_results").fetchone()["n"] == 1


def test_atomic_queue_and_concurrent_idempotency(settings):
    runtime = Runtime(settings)
    with runtime.db.connect() as conn:
        operation = runtime.execution.create_operation(conn, "test", {})
        runtime.execution.add_stage(conn, operation, "discover", {"source": "arxiv", "query": "test"})
        assert conn.execute("SELECT count(*) AS n FROM public.procrastinate_jobs").fetchone()["n"] == 1
        conn.rollback()
    with runtime.db.connect() as conn:
        assert conn.execute("SELECT count(*) AS n FROM operations").fetchone()["n"] == 0
        assert conn.execute("SELECT count(*) AS n FROM public.procrastinate_jobs").fetchone()["n"] == 0
    key = str(uuid.uuid4())

    def submit():
        with runtime.db.connect() as conn:
            return runtime.db.idempotent(
                conn,
                "test",
                key,
                {"same": True},
                lambda c: (201, {"id": runtime.execution.create_operation(c, "test", {})}),
            )[1]["id"]

    with ThreadPoolExecutor(max_workers=4) as pool:
        identifiers = list(pool.map(lambda _: submit(), range(8)))
    assert len(set(identifiers)) == 1
    with runtime.db.connect() as conn:
        with pytest.raises(Problem, match="不同内容"):
            runtime.db.idempotent(conn, "test", key, {"different": True}, lambda c: (200, {}))


def test_source_validation_revision_and_idempotent_upload(client, settings, pdf_bytes):
    key = str(uuid.uuid4())
    headers = {"Idempotency-Key": key}
    first = client.post(
        "/api/v2/imports/pdf", files={"file": ("test.pdf", pdf_bytes, "application/pdf")}, headers=headers
    )
    second = client.post(
        "/api/v2/imports/pdf", files={"file": ("test.pdf", pdf_bytes, "application/pdf")}, headers=headers
    )
    assert first.json() == second.json()
    drain(settings)
    paper = client.get("/api/v2/works/" + first.json()["work_id"]).json()
    q = mutate(client, "POST", "/research/questions", {"title": "Check"}).json()
    bad = mutate(
        client,
        "POST",
        f"/research/questions/{q['id']}/evidence",
        {
            "work_id": paper["id"],
            "block_id": paper["document"]["blocks"][0]["id"],
            "quote": "An invented quote.",
        },
    )
    assert bad.status_code == 400
    update = mutate(client, "PATCH", f"/research/questions/{q['id']}", {"title": "Edited", "revision": 1})
    assert update.status_code == 200
    stale = mutate(client, "PATCH", f"/research/questions/{q['id']}", {"title": "Overwrite", "revision": 1})
    assert stale.status_code == 409
    note = mutate(
        client,
        "POST",
        f"/works/{paper['id']}/notes",
        {
            "body": "Saved annotation",
            "pdf_sha256": hashlib.sha256(pdf_bytes).hexdigest(),
            "page": 1,
            "rects": [{"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.05}],
        },
    )
    assert note.status_code == 201, note.text
    assert client.get(f"/api/v2/works/{paper['id']}/notes").json()["notes"][0]["pdf_current"]
    invalid = mutate(
        client,
        "POST",
        f"/works/{paper['id']}/notes",
        {"body": "Invalid page", "pdf_sha256": hashlib.sha256(pdf_bytes).hexdigest(), "page": 300},
    )
    assert invalid.status_code == 400
    assert client.get("/api/v2/works", params={"q": "evaluation protocol"}).json()["total"] == 1


def test_model_cache_citations_and_budget(client, settings, pdf_bytes, model_server):
    imported = upload(client, pdf_bytes)
    drain(settings)
    configure_model(settings, model_server)
    body = {"kind": "analyze", "work_ids": [imported["work_id"]]}
    operation = mutate(client, "POST", "/operations", body).json()["operation"]
    drain(settings)
    status = client.get("/api/v2/operations/" + operation["id"]).json()
    assert status["state"] == "succeeded", status
    assert status["budget_used"] == 320 and status["budget_reserved"] == 0
    assert model_server["calls"] == 1
    paper = client.get("/api/v2/works/" + imported["work_id"]).json()
    assert paper["has_report"] and "原文出处" in paper["markdown"]
    model_server["mode"] = "bad_citation"
    failed = mutate(client, "POST", "/operations", body).json()["operation"]
    drain(settings)
    bad = client.get("/api/v2/operations/" + failed["id"]).json()
    assert bad["state"] == "needs_input"
    assert bad["stages"][0]["error"]["code"] == "citation_mismatch"
    assert bad["invocations"][0]["response_sha"]
    mutate(client, "POST", f"/operations/{failed['id']}/retry")
    drain(settings)
    assert model_server["calls"] == 2, "Validation retry must reuse the persisted provider response"
    budget = mutate(client, "POST", "/operations", {**body, "token_budget": 10}).json()["operation"]
    drain(settings)
    stopped = client.get("/api/v2/operations/" + budget["id"]).json()
    assert stopped["stages"][0]["error"]["code"] == "budget_exhausted"
    assert model_server["calls"] == 2


def test_unknown_model_result_is_not_reissued(client, settings, pdf_bytes, model_server):
    imported = upload(client, pdf_bytes)
    drain(settings)
    configure_model(settings, model_server)
    model_server["mode"] = "timeout"
    operation = mutate(
        client, "POST", "/operations", {"kind": "analyze", "work_ids": [imported["work_id"]]}
    ).json()["operation"]
    drain(settings)
    detail = client.get("/api/v2/operations/" + operation["id"]).json()
    assert detail["state"] == "needs_input"
    assert detail["invocations"][0]["state"] == "unknown"
    assert detail["budget_reserved"] > 0
    refused = mutate(client, "POST", f"/operations/{operation['id']}/retry")
    assert refused.status_code == 409
    assert model_server["calls"] == 1
    resolved = mutate(
        client,
        "POST",
        f"/model-invocations/{detail['invocations'][0]['id']}/resolve",
        {
            "outcome": "charged_no_result",
            "used_tokens": 300,
            "note": "Confirmed in the simulated provider log.",
        },
    )
    assert resolved.status_code == 200
    assert client.get("/api/v2/operations/" + operation["id"]).json()["budget_reserved"] == 0


def test_fencing_and_heartbeat_recovery(settings):
    runtime = Runtime(settings)
    with runtime.db.connect() as conn:
        operation = runtime.execution.create_operation(conn, "test", {})
        stage = runtime.execution.add_stage(conn, operation, "discover", {"source": "arxiv", "query": "test"})
        job = conn.execute("SELECT queue_job_id FROM stages WHERE id=%s", (stage,)).fetchone()["queue_job_id"]
        worker = conn.execute(
            "INSERT INTO public.procrastinate_workers DEFAULT VALUES RETURNING id"
        ).fetchone()["id"]
        conn.execute(
            "UPDATE public.procrastinate_jobs SET status='doing',worker_id=%s WHERE id=%s", (worker, job)
        )
    old = runtime.execution.begin(stage, job)
    assert recover_stalled(runtime) == []
    with runtime.db.connect() as conn:
        conn.execute(
            "UPDATE public.procrastinate_workers SET last_heartbeat=now()-interval '10 seconds' WHERE id=%s",
            (worker,),
        )
    assert recover_stalled(runtime) == [stage]
    new = runtime.execution.begin(stage, job)
    assert new.generation > old.generation
    with pytest.raises(Superseded):
        runtime.execution.publish(old, lambda conn: {"stale": True})
    runtime.execution.publish(new, lambda conn: {"current": True})
    with runtime.db.connect() as conn:
        assert runtime.execution.get(conn, operation)["state"] == "succeeded"


def test_committed_event_cursor_does_not_skip_late_commit(settings):
    runtime = Runtime(settings)
    with runtime.db.connect() as late:
        runtime.db.emit(late, "test.changed", "late")
        with runtime.db.connect() as early:
            runtime.db.emit(early, "test.changed", "early")
        first = runtime.db.dispatch_events()
        with runtime.db.connect() as reader:
            rows = reader.execute("SELECT entity_id FROM events ORDER BY cursor").fetchall()
            assert [r["entity_id"] for r in rows] == ["early"]
    last = runtime.db.dispatch_events()
    assert last > first
    with runtime.db.connect() as conn:
        assert (
            conn.execute("SELECT entity_id FROM events WHERE cursor>%s", (first,)).fetchone()["entity_id"]
            == "late"
        )


def test_schedule_uses_one_transactional_run_per_date(settings):
    runtime = Runtime(settings)
    with runtime.db.connect() as conn:
        runtime.db.set_setting(
            conn,
            "discovery_config",
            {
                "enabled": True,
                "query": "all:robot",
                "sources": ["arxiv", "crossref"],
                "time": "00:00",
                "timezone": "UTC",
            },
        )
    scheduled_discovery(runtime)
    scheduled_discovery(runtime)
    with runtime.db.connect() as conn:
        assert conn.execute("SELECT count(*) AS n FROM operations").fetchone()["n"] == 1
        assert conn.execute("SELECT count(*) AS n FROM stages").fetchone()["n"] == 2


def start_worker(settings):
    env = {
        **os.environ,
        "PAPERNAS_V2_DATABASE_URL": settings.database_url,
        "PAPERNAS_V2_STATE": str(settings.state_dir),
        "PAPERNAS_V2_DOCLING": "0",
        "PAPERNAS_V2_ALLOW_PRIVATE_HOSTS": "127.0.0.1",
        "PAPERNAS_V2_WORKER_STALE_SECONDS": "1",
        "PAPERNAS_V2_MODEL_TIMEOUT": "30",
    }
    code = "import asyncio; from papernas_v2.settings import Settings; from papernas_v2.queue import DurableQueue; asyncio.run(DurableQueue(Settings.environment(),asynchronous=True).run(concurrency=1))"
    return subprocess.Popen(
        [sys.executable, "-c", code],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def test_cli_worker_exits_cleanly_on_sigterm(settings):
    process = subprocess.Popen(
        [sys.executable, "-m", "papernas_v2.cli", "worker", "--concurrency", "1"],
        env={
            **os.environ,
            "PAPERNAS_V2_DATABASE_URL": settings.database_url,
            "PAPERNAS_V2_STATE": str(settings.state_dir),
            "PAPERNAS_V2_DOCLING": "0",
        },
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        runtime = Runtime(settings)
        for _ in range(100):
            with runtime.db.connect() as conn:
                if conn.execute("SELECT 1 FROM public.procrastinate_workers LIMIT 1").fetchone():
                    break
            assert process.poll() is None
            time.sleep(0.05)
        else:
            pytest.fail("CLI worker did not register")
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def test_killed_worker_resumes_download_without_duplicate_work(client, settings, pdf_bytes, model_server):
    model_server["pdf"] = pdf_bytes
    model_server["get_delay"] = 4
    reference = model_server["base_url"].removesuffix("/v1") + "/paper.pdf"
    operation = mutate(client, "POST", "/operations", {"kind": "import", "reference": reference}).json()[
        "operation"
    ]
    process = start_worker(settings)
    try:
        assert model_server["get_received"].wait(10), "Worker never started source download"
    finally:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
    time.sleep(1.2)
    runtime = Runtime(settings)
    assert recover_stalled(runtime)
    model_server["get_delay"] = 0
    drain(settings)
    result = client.get("/api/v2/operations/" + operation["id"]).json()
    assert result["state"] == "succeeded", result
    assert client.get("/api/v2/works").json()["total"] == 1
    assert any(stage["attempts"] == 2 for stage in result["stages"] if stage["kind"] == "fetch_pdf")


def test_killed_model_worker_requires_reconciliation(client, settings, pdf_bytes, model_server):
    imported = upload(client, pdf_bytes)
    drain(settings)
    configure_model(settings, model_server)
    model_server["mode"] = "timeout"
    operation = mutate(
        client, "POST", "/operations", {"kind": "analyze", "work_ids": [imported["work_id"]]}
    ).json()["operation"]
    process = start_worker(settings)
    try:
        assert model_server["received"].wait(10), "Worker never sent the model request"
    finally:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
    time.sleep(1.2)
    assert recover_stalled(Runtime(settings))
    drain(settings)
    result = client.get("/api/v2/operations/" + operation["id"]).json()
    assert result["state"] == "needs_input", result
    assert result["invocations"][0]["state"] == "unknown"
    assert result["budget_reserved"] > 0
    assert model_server["calls"] == 1


def test_figure_correction_preserves_original_and_page(client, settings, pdf_bytes):
    imported = upload(client, pdf_bytes)
    drain(settings)
    paper = client.get("/api/v2/works/" + imported["work_id"]).json()
    figure = paper["document"]["figures"][0]
    original = figure["asset_sha"]
    question = mutate(client, "POST", "/research/questions", {"title": "Original figure evidence"}).json()
    evidence = mutate(
        client,
        "POST",
        f"/research/questions/{question['id']}/evidence",
        {"work_id": imported["work_id"], "figure_id": figure["id"]},
    ).json()
    preview = client.get(f"/api/v2/figures/{figure['id']}/page-preview").json()
    assert preview["width"] == 612 and preview["height"] == 792
    repair = mutate(
        client,
        "POST",
        "/operations",
        {
            "kind": "repair_figure",
            "figure_id": figure["id"],
            "figure_page": 1,
            "bbox": {"x0": 55, "y0": 210, "x1": 540, "y1": 400},
        },
    )
    assert repair.status_code == 202, repair.text
    drain(settings)
    updated = client.get("/api/v2/works/" + imported["work_id"]).json()["document"]["figures"][0]
    assert updated["status"] == "ready" and updated["asset_sha"] != original
    assert updated["provenance"]["method"] == "manual_region"
    assert updated["provenance"]["page"] == 1
    assert client.get("/api/v2/assets/" + original).status_code == 200
    saved = client.get(f"/api/v2/research/questions/{question['id']}").json()["evidence"][0]
    assert saved["source_anchor"] == evidence["source_anchor"]
    assert saved["source_anchor"]["asset_sha"] == original


def test_paused_and_cancelled_jobs_never_publish_early(client, settings, pdf_bytes):
    paused = upload(client, pdf_bytes)
    identifier = paused["operation"]["id"]
    assert mutate(client, "POST", f"/operations/{identifier}/pause").status_code == 200
    drain(settings)
    assert client.get(f"/api/v2/operations/{identifier}").json()["state"] == "paused"
    assert not client.get("/api/v2/works/" + paused["work_id"]).json()["has_document"]
    assert mutate(client, "POST", f"/operations/{identifier}/resume").status_code == 200
    drain(settings)
    assert client.get(f"/api/v2/operations/{identifier}").json()["state"] == "succeeded"
    cancelled = upload(client, pdf_bytes + b"\n% cancelled fixture\n")
    identifier = cancelled["operation"]["id"]
    assert mutate(client, "POST", f"/operations/{identifier}/cancel").status_code == 200
    drain(settings)
    assert client.get(f"/api/v2/operations/{identifier}").json()["state"] == "cancelled"
    assert not client.get("/api/v2/works/" + cancelled["work_id"]).json()["has_document"]
    assert mutate(client, "POST", f"/operations/{identifier}/resume").status_code == 409
