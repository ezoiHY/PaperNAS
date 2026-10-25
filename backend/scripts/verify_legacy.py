#!/usr/bin/env python3
"""Read-only migration audit against a frozen v1 snapshot and all stored assets."""

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path

from papernas_v2.legacy import read_json, source_path, sqlite_rows
from papernas_v2.library import paper_dto
from papernas_v2.runtime import Runtime
from papernas_v2.settings import Settings


def verify(runtime, output, native, original_output):
    counts = Counter()
    source = sqlite_rows(output / "state.sqlite3", "papers")
    with runtime.db.connect() as conn:
        assert conn.execute("SELECT count(*) AS n FROM works").fetchone()["n"] == len(source)
        for row in source:
            key = row["paper_key"]
            work = conn.execute("SELECT * FROM works WHERE id=%s", (key,)).fetchone()
            legacy = conn.execute("SELECT * FROM legacy_records WHERE work_id=%s", (key,)).fetchone()
            preserved = runtime.assets.read_json(legacy["original_asset"])
            assert preserved["row"] == row, key
            for field, path in [("document", "document_path"), ("report", "report_path")]:
                expected = (
                    read_json(source_path(row[path], output, original_output)) if row.get(path) else None
                )
                assert preserved[field] == expected, (key, field)
            assert preserved["brief"] == read_json(output / "papers" / key / "brief.json"), key
            assert work["title"] == json.loads(row["metadata"])["title"]
            assert work["collection"] == row["collection"]
            version = conn.execute(
                "SELECT * FROM work_versions WHERE id=%s", (work["current_version_id"],)
            ).fetchone()
            pdf = output / "papers" / key / "source.pdf"
            if pdf.exists():
                assert version["pdf_asset"] == hashlib.sha256(pdf.read_bytes()).hexdigest(), key
                counts["pdf_hashes"] += 1
            dto = paper_dto(conn, work, full=True)
            assert dto["title"] == work["title"]
            if preserved["report"]:
                assert dto["has_report"] or not work["current_analysis_id"]
                counts["original_reports"] += 1
            doc = preserved["document"] or {}
            for table, field in [("blocks", "blocks"), ("figures", "figures")]:
                total = conn.execute(
                    f"SELECT count(*) AS n FROM {table} WHERE document_id=%s", (legacy["document_id"],)
                ).fetchone()["n"]
                assert total == len(doc.get(field, [])), (key, field)
                counts[field] += total
            counts["works"] += 1
        for table, target in [
            ("workspace_groups", "groups"),
            ("paper_groups", "group_works"),
            ("paper_notes", "notes"),
        ]:
            rows = sqlite_rows(output / "state.sqlite3", table)
            assert conn.execute(f"SELECT count(*) AS n FROM {target}").fetchone()["n"] == len(rows)
            counts[target] = len(rows)
            if table == "paper_notes":
                for note in rows:
                    migrated = conn.execute("SELECT * FROM notes WHERE id=%s", (note["id"],)).fetchone()
                    for field in [
                        "body",
                        "selected_text",
                        "pdf_sha256",
                        "page",
                        "revision",
                        "prefix",
                        "suffix",
                    ]:
                        assert migrated[field] == note[field], (note["id"], field)
                    assert migrated["rects"] == json.loads(note["rects"])
        positions = sqlite_rows(native, "reading")
        for position in positions:
            migrated = conn.execute(
                "SELECT * FROM reading_state WHERE work_id=%s", (position["paper"],)
            ).fetchone()
            assert migrated
            for field in ["pdf_sha256", "page", "section", "revision"]:
                assert migrated[field] == position[field]
        counts["reading_positions"] = len(positions)
        for asset in conn.execute("SELECT * FROM assets").fetchall():
            data = runtime.assets.path(asset["sha256"]).read_bytes()
            assert len(data) == asset["byte_size"]
            assert hashlib.sha256(data).hexdigest() == asset["sha256"]
            counts["verified_assets"] += 1
    return dict(counts)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native-db", type=Path, required=True)
    parser.add_argument("--original-output", type=Path, required=True)
    args = parser.parse_args()
    print(
        json.dumps(verify(Runtime(Settings.environment()), args.output, args.native_db, args.original_output))
    )
