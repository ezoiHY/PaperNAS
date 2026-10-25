import asyncio
import json
import uuid

import httpx
import pytest
from conftest import mutate

from papernas_v2 import models
from papernas_v2.core import NeedsInput
from papernas_v2.models import extract_json
from papernas_v2.queue import DurableQueue


@pytest.mark.parametrize("content", ["", None, '{"title":', '{"title":"Complete JSON"}'])
def test_length_finish_is_truncated_even_without_usable_content(content):
    response = {"choices": [{"message": {"content": content}, "finish_reason": "length"}]}
    with pytest.raises(NeedsInput) as caught:
        extract_json(response)
    assert caught.value.code == "model_output_truncated"
    assert "思考 token" in str(caught.value)
    assert "原始响应已保存" in str(caught.value)
    assert "不会自动重新调用" in str(caught.value)
    assert "调整模型输出上限" in str(caught.value)


@pytest.mark.parametrize(
    "response",
    [
        {"choices": [{"message": {"content": '{"title":'}, "finish_reason": "stop"}]},
        {"choices": [{"message": {"content": None}, "finish_reason": "stop"}]},
        {"choices": [{"finish_reason": "stop"}]},
        {"choices": [None]},
        {"choices": []},
        {},
    ],
)
def test_malformed_untruncated_response_remains_invalid(response):
    with pytest.raises(NeedsInput) as caught:
        extract_json(response)
    assert caught.value.code == "model_output_invalid"


@pytest.mark.parametrize("content", ['{"title":"Report"}', '```json\n{"title":"Report"}\n```'])
def test_complete_json_is_accepted(content):
    response = {"choices": [{"message": {"content": content}, "finish_reason": "stop"}]}
    assert extract_json(response) == {"title": "Report"}


def test_truncated_analysis_preserves_response_and_does_not_repeat_provider_call(
    client, settings, pdf_bytes, monkeypatch
):
    def drain():
        asyncio.run(DurableQueue(settings, asynchronous=True).run(concurrency=2, wait=False))

    imported = client.post(
        "/api/v2/imports/pdf",
        params={"title": "Truncated output fixture"},
        files={"file": ("test.pdf", pdf_bytes, "application/pdf")},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert imported.status_code == 202, imported.text
    drain()
    runtime = client.app.state.runtime
    with runtime.db.connect() as conn:
        runtime.db.set_setting(
            conn,
            "model_config",
            {"base_url": "http://127.0.0.1:8080/v1", "model": "fixture", "max_output_tokens": 2048},
        )
    provider_response = {
        "choices": [
            {
                "message": {"content": "", "reasoning_content": "Synthetic unfinished model response."},
                "finish_reason": "length",
            }
        ],
        "usage": {
            "total_tokens": 2745,
            "completion_tokens": 2048,
            "completion_tokens_details": {"reasoning_tokens": 2048},
        },
    }
    calls = []

    def respond(request):
        calls.append(json.loads(request.content))
        return httpx.Response(200, json=provider_response)

    real_client = httpx.Client
    monkeypatch.setattr(
        models.httpx,
        "Client",
        lambda **kwargs: real_client(transport=httpx.MockTransport(respond), **kwargs),
    )
    operation = mutate(
        client, "POST", "/operations", {"kind": "analyze", "work_ids": [imported.json()["work_id"]]}
    )
    assert operation.status_code == 202, operation.text
    operation_id = operation.json()["operation"]["id"]
    drain()
    detail = client.get("/api/v2/operations/" + operation_id).json()
    assert detail["state"] == "needs_input"
    assert detail["stages"][0]["error"]["code"] == "model_output_truncated"
    assert detail["budget_used"] == 2745 and detail["budget_reserved"] == 0
    assert len(calls) == 1 and calls[0]["max_tokens"] == 2048
    invocation = detail["invocations"][0]
    assert invocation["state"] == "received"
    assert runtime.assets.read_json(invocation["response_sha"]) == provider_response
    assert not client.get("/api/v2/works/" + imported.json()["work_id"]).json()["has_report"]

    drain()
    assert len(calls) == 1, "A truncated result must not trigger an automatic provider retry"
    retried = mutate(client, "POST", f"/operations/{operation_id}/retry")
    assert retried.status_code == 200, retried.text
    drain()
    detail = client.get("/api/v2/operations/" + operation_id).json()
    assert detail["state"] == "needs_input"
    assert detail["stages"][0]["error"]["code"] == "model_output_truncated"
    assert len(calls) == len(detail["invocations"]) == 1
    assert detail["budget_used"] == 2745 and detail["budget_reserved"] == 0
