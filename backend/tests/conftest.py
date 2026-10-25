from __future__ import annotations

import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import psycopg
import pymupdf as fitz
import pytest
from fastapi.testclient import TestClient
from psycopg import sql

from papernas_v2.api import create_app
from papernas_v2.cli import initialize
from papernas_v2.settings import Settings


@pytest.fixture
def settings(tmp_path):
    raw = os.environ.get("PAPERNAS_V2_TEST_ADMIN_URL")
    if not raw:
        connection = Path(__file__).resolve().parents[1] / ".runtime" / "connection.json"
        if not connection.exists():
            pytest.skip("Set PAPERNAS_V2_TEST_ADMIN_URL to a disposable PostgreSQL cluster")
        raw = json.loads(connection.read_text())["admin_url"]
    database = "papernas_test_" + uuid.uuid4().hex
    with psycopg.connect(raw, autocommit=True) as conn:
        conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(database)))
    parts = urlsplit(raw)
    value = Settings(
        urlunsplit((parts.scheme, parts.netloc, "/" + database, parts.query, parts.fragment)),
        tmp_path / "state",
        use_docling=False,
        allow_private_hosts=("127.0.0.1",),
        worker_stale_seconds=1,
        model_timeout=2,
    )
    initialize(value)
    yield value
    with psycopg.connect(raw, autocommit=True) as conn:
        conn.execute(sql.SQL("DROP DATABASE {} WITH (FORCE)").format(sql.Identifier(database)))


@pytest.fixture
def client(settings):
    with TestClient(create_app(settings)) as value:
        response = value.post(
            "/api/v2/auth/devices",
            json={
                "access_key": settings.access_key_file.read_text().strip(),
                "device_name": "Integration test",
            },
        )
        assert response.status_code == 200, response.text
        value.headers["Authorization"] = "Bearer " + response.json()["device"]["token"]
        yield value


def mutate(client, method, path, body=None, *, key=None, **kwargs):
    headers = {"Idempotency-Key": key or str(uuid.uuid4())}
    return client.request(method, "/api/v2" + path, json=body, headers=headers, **kwargs)


@pytest.fixture
def pdf_bytes():
    with fitz.open() as doc:
        page = doc.new_page(width=612, height=792)
        page.insert_text((50, 50), "Example study: bounded evidence", fontsize=16)
        page.insert_textbox(
            fitz.Rect(50, 90, 550, 180),
            "The study compares two methods under the same evaluation protocol. Method A uses four training examples. The small sample does not establish general superiority.",
            fontsize=12,
        )
        page.draw_rect(fitz.Rect(60, 220, 530, 390), color=(0, 0, 0), fill=(0.9, 0.95, 1))
        page.insert_text((80, 300), "Vector figure: the complete experimental pipeline", fontsize=13)
        page.insert_text((50, 420), "Figure 1: Experimental workflow and evaluation conditions.", fontsize=11)
        second = doc.new_page(width=612, height=792)
        second.insert_textbox(
            fitz.Rect(50, 70, 550, 300),
            "A held-out evaluation is required before adapting this method. The authors report no measurements of long-term stability. These missing measurements limit the conclusion.",
            fontsize=12,
        )
        return doc.tobytes()


@pytest.fixture
def model_server():
    state = {
        "calls": 0,
        "mode": "valid",
        "received": threading.Event(),
        "get_received": threading.Event(),
        "get_delay": 0,
        "pdf": b"",
    }

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            state["get_received"].set()
            time.sleep(state["get_delay"])
            self.send_response(200)
            self.send_header("Content-Type", "application/pdf")
            self.send_header("Content-Length", str(len(state["pdf"])))
            self.end_headers()
            try:
                self.wfile.write(state["pdf"])
            except BrokenPipeError:
                pass

        def do_POST(self):
            state["calls"] += 1
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            state["received"].set()
            if state["mode"] == "timeout":
                time.sleep(3)
            text = body["messages"][1]["content"]
            context = json.loads(text.split("\n", 1)[1].split("\n\nOutput schema:", 1)[0])
            block = next(b for b in context["blocks"] if len(b["text"]) > 50)
            quote = block["text"][:90]
            if state["mode"] == "bad_citation":
                quote = "This sentence does not appear in the source material."
            claim = {
                "text": "该研究的结论受所提供评估条件限制。",
                "citations": [{"block_id": block["id"], "quote": quote}],
            }
            result = {
                "title": "证据核对",
                "summary": claim,
                "findings": [claim],
                "limitations": [],
                "unknowns": ["长期稳定性未在提供材料中确认。"],
                "suggested_next_steps": ["在固定划分上进行一次独立验证。"],
            }
            by_work = {}
            for candidate in context["blocks"]:
                if candidate.get("work_id") and len(candidate["text"]) > 50:
                    by_work.setdefault(candidate["work_id"], candidate)
            if len(by_work) > 1:
                result["findings"] = [
                    {
                        "text": "Each paper needs a matched protocol.",
                        "citations": [{"block_id": b["id"], "quote": b["text"][:90]}],
                    }
                    for b in by_work.values()
                ]
            if callback := state.get("before_response"):
                callback()
            data = json.dumps(
                {
                    "choices": [{"message": {"content": json.dumps(result)}, "finish_reason": "stop"}],
                    "usage": {"total_tokens": 320},
                },
                ensure_ascii=False,
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except BrokenPipeError:
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    state["base_url"] = f"http://127.0.0.1:{server.server_port}/v1"
    yield state
    server.shutdown()
    server.server_close()
