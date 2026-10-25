import asyncio
import uuid

import pytest
from conftest import mutate

from papernas_v2.analysis import markdown_report
from papernas_v2.queue import DurableQueue


def test_report_export_distinguishes_unknown_and_verified_pdf_pages():
    blocks = [
        {"id": "legacy-html", "page": None, "work_title": "Imported HTML paper"},
        {"id": "pdf-block", "page": 7, "work_title": "PDF paper"},
    ]
    claims = [
        {
            "text": "An imported claim.",
            "citations": [{"block_id": "legacy-html", "quote": "Original HTML evidence."}],
        },
        {
            "text": "A PDF claim.",
            "citations": [{"block_id": "pdf-block", "quote": "Evidence on the verified PDF page."}],
        },
    ]
    exported = markdown_report(
        {
            "title": "Mixed source report",
            "summary": claims[0],
            "findings": claims,
            "limitations": [],
            "unknowns": [],
            "suggested_next_steps": [],
        },
        blocks,
    )
    assert "[^1]: Imported HTML paper · PDF 页码未知 · `legacy-html` — Original HTML evidence." in exported
    assert "[^2]: PDF paper · p. 7 · `pdf-block` — Evidence on the verified PDF page." in exported
    assert "p. None" not in exported


@pytest.mark.parametrize(
    "table,source_field,quote_field", [("blocks", "block_id", "text"), ("figures", "figure_id", "caption")]
)
@pytest.mark.parametrize("unknown_page", [False, True])
def test_research_export_keeps_unknown_pages_explicit(
    client, settings, pdf_bytes, table, source_field, quote_field, unknown_page
):
    imported = client.post(
        "/api/v2/imports/pdf",
        params={"title": "Evidence source fixture"},
        files={"file": ("test.pdf", pdf_bytes, "application/pdf")},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert imported.status_code == 202, imported.text
    asyncio.run(DurableQueue(settings, asynchronous=True).run(concurrency=2, wait=False))
    work_id = imported.json()["work_id"]
    paper = client.get("/api/v2/works/" + work_id).json()
    source = paper["document"][table][0]
    assert source["page"] is not None
    if unknown_page:
        # Legacy HTML extractions retain unknown page anchors in these nullable columns.
        with client.app.state.runtime.db.connect() as conn:
            conn.execute(f"UPDATE {table} SET page=NULL WHERE id=%s", (source["id"],))
    question = mutate(client, "POST", "/research/questions", {"title": "Traceable source evidence"})
    assert question.status_code == 201, question.text
    question_id = question.json()["id"]
    evidence = mutate(
        client,
        "POST",
        f"/research/questions/{question_id}/evidence",
        {"work_id": work_id, source_field: source["id"], "quote": source[quote_field]},
    )
    assert evidence.status_code == 201, evidence.text
    exported = client.get(f"/api/v2/research/questions/{question_id}/export")
    assert exported.status_code == 200, exported.text
    expected_page = "PDF 页码未知" if unknown_page else f"p. {source['page']}"
    assert f"### Evidence source fixture · {expected_page}" in exported.text
    assert f"Evidence `{evidence.json()['id']}`" in exported.text
    assert source[quote_field] in exported.text.replace("\n> ", "\n")
    assert "p. None" not in exported.text
