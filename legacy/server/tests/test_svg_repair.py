"""SVG repair safety and preservation tests; all artifacts live under tmp_path."""
import copy
import importlib.util
import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from PIL import Image

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "repair-svg-figures.py"
spec = importlib.util.spec_from_file_location("svg_repair", SCRIPT)
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)

SVG = b'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
 viewBox="0 0 100 50"><defs><path id="shape" d="M0 0H10V10Z"/></defs>
 <use xlink:href="#shape" fill="blue"/></svg>'''


def png(color="red", size=(20, 10)):
    data = io.BytesIO()
    Image.new("RGB", size, color).save(data, "PNG")
    return data.getvalue()


def snapshot(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}


@pytest.fixture
def archive(tmp_path):
    identity = "arxiv:1234.56789v1"
    key = repair.sha(identity.encode())[:20]
    root = tmp_path / "output"
    paper = root / "papers" / key
    paper.mkdir(parents=True)
    html = b'''<article><figure id="S1.F1"><div class="ltx_flex_figure">
    <div><object type="image/svg+xml" data="1234.56789v1/top.svg"></object></div>
    <div class="ltx_flex_break"></div>
    <div><object type="image/svg+xml" data="1234.56789v1/bottom.svg"></object></div>
    </div><figcaption>Figure 1: Two panels.</figcaption></figure></article>'''
    material = paper / "material.html"
    material.write_bytes(html)
    figure_id = "fig-" + repair.sha(b"S1.F1:0")[:16]
    figure = {"id": figure_id, "label": "Figure 1:", "caption": "Two panels.",
              "section": "Method", "page": None, "block_ids": ["b00001"],
              "source_url": "https://arxiv.org/html/1234.56789v1#S1.F1", "asset_path": None,
              "mime_type": None, "width": None, "height": None, "sha256": None,
              "kind": "figure", "warning": "Original figure unavailable"}
    document = {"paper_identity": identity, "content_hash": repair.sha(html),
                "parser": "beautifulsoup-article", "scope": "main_text",
                "blocks": [{"id": "b00001", "text": "Original evidence text.", "section": "Method",
                            "page": None, "kind": "text"}], "warnings": ["Original archival warning"],
                "material_path": str(material), "material_url": "https://arxiv.org/html/1234.56789v1",
                "figures": [figure]}
    (paper / "document.json").write_text(json.dumps(document))
    reports = root / "reports"
    reports.mkdir()
    (reports / f"{key}.json").write_bytes(b'unchanged report with original document snapshot')
    (paper / "notes.json").write_bytes(b'unchanged notes and anchors')
    return root, key, figure_id, document


@pytest.fixture
def engine():
    source = os.environ.get("PAPER_NAS_ENGINE_SOURCE")
    if source:
        sys.path.insert(0, str(Path(source) / "src"))
    return pytest.importorskip("research_digest.figures", reason="Engine source needed for publish integration")


def test_static_svg_fragment_references_are_preserved():
    clean, width, height = repair.sanitized_svg(SVG)
    assert (width, height) == (2400, 1200)
    assert b'xlink:href="#shape"' in clean
    assert b'fill="blue"' in clean


@pytest.mark.parametrize("fragment", [
    '<script>alert(1)</script>', '<foreignObject><p>active</p></foreignObject>',
    '<image href="https://example.test/image.png"/>', '<use href="https://example.test/x#shape"/>',
    '<use href="file:///etc/passwd"/>', '<use href="data:image/svg+xml,hello"/>',
    '<style>@import "https://example.test/style.css";</style>',
    '<path style="fill:url(https://example.test/image.svg#x)"/>',
    '<path style="fill:u\\72l(https://example.test/image.svg#x)"/>',
    '<path style="fill:u/**/rl(https://example.test/image.svg#x)"/>',
    '<g xml:base="https://example.test/"><use href="#shape"/></g>',
    '<path onload="doSomething()"/>', '<animate attributeName="href" values="bad"/>',
])
def test_active_and_external_svg_content_is_rejected(fragment):
    body = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">' + fragment + '</svg>').encode()
    with pytest.raises(ValueError):
        repair.sanitized_svg(body)


@pytest.mark.parametrize("prefix", [b'<!DOCTYPE svg>', b'<!ENTITY x "test">',
                                      b'<?xml-stylesheet href="https://example.test/style.css"?>'])
def test_xml_entities_and_stylesheets_are_rejected(prefix):
    with pytest.raises(ValueError):
        repair.sanitized_svg(prefix + SVG)


def test_viewbox_and_byte_limits_are_enforced():
    with pytest.raises(ValueError):
        repair.sanitized_svg(SVG.replace(b"0 0 100 50", b"0 0 nan 50"))
    with pytest.raises(ValueError):
        repair.sanitized_svg(b" " * (repair.MAX_SVG_BYTES + 1))


def test_plan_is_read_only_and_keeps_both_panels(archive):
    root, key, figure_id, _ = archive
    before = snapshot(root)
    plan = repair.make_plan(root, key, [figure_id])
    assert plan["figures"] == [{"id": figure_id, "status": "repair", "sources": [
        "https://arxiv.org/html/1234.56789v1/top.svg",
        "https://arxiv.org/html/1234.56789v1/bottom.svg"]}]
    assert snapshot(root) == before


def test_material_tampering_and_symlink_escape_are_rejected(archive, tmp_path):
    root, key, figure_id, document = archive
    path = Path(document["material_path"])
    original = path.read_bytes()
    path.write_bytes(original + b"tamper")
    with pytest.raises(ValueError, match="hash"):
        repair.make_plan(root, key, [figure_id])
    path.unlink()
    external = tmp_path / "external.html"
    external.write_bytes(original)
    path.symlink_to(external)
    with pytest.raises(ValueError, match="symlink"):
        repair.make_plan(root, key, [figure_id])


def test_composite_contains_both_complete_panels_in_order():
    body = repair.composite_panels([png("red", (20, 10)), png("blue", (10, 5))])
    image = Image.open(io.BytesIO(body))
    assert image.size == (20, 44)
    assert image.getpixel((10, 5)) == (255, 0, 0)
    assert image.getpixel((10, 20)) == (255, 255, 255)
    assert image.getpixel((10, 40)) == (0, 0, 255)


@pytest.mark.parametrize("sizes", [
    [(1, 2400), (2400, 1)],
    [(2400, 2400), (2400, 2400), (2400, 2400)],
])
def test_composite_checks_aggregate_bounds_before_allocating(sizes, monkeypatch):
    panels = [png(size=size) for size in sizes]

    def forbidden_allocation(*_args, **_kwargs):
        raise AssertionError("No pixel allocation is allowed before composite bounds pass")

    monkeypatch.setattr(Image.Image, "load", forbidden_allocation)
    monkeypatch.setattr(Image.Image, "resize", forbidden_allocation)
    monkeypatch.setattr(Image, "new", forbidden_allocation)
    with pytest.raises(ValueError, match="Composite figure exceeds pixel bounds"):
        repair.composite_panels(panels)


def test_patch_changes_asset_fields_only(archive):
    _, _, figure_id, document = archive
    original = copy.deepcopy(document)
    updates = {"asset_path": "/cache/test.png", "mime_type": "image/png", "width": 20,
               "height": 10, "sha256": "a" * 64, "warning": None}
    result = repair.patched_document(document, {figure_id: updates})
    assert document == original
    original_figure = original["figures"][0]
    for field in repair.ASSET_FIELDS:
        result["figures"][0][field] = original_figure[field]
    assert result == original
    with pytest.raises(ValueError, match="non-asset"):
        repair.patched_document(document, {figure_id: {"caption": "replacement"}})


def test_publish_backs_up_and_preserves_report_notes_and_identity(archive, tmp_path, engine):
    root, key, figure_id, document = archive
    plan = repair.make_plan(root, key, [figure_id])
    staged = tmp_path / "staged"
    staged.mkdir()
    asset = engine.cache_raster(png(), staged)
    report = root / "reports" / f"{key}.json"
    notes = root / "papers" / key / "notes.json"
    backup = repair.publish(plan, staged, {figure_id: asset}, [])
    assert (backup / "document.json").read_bytes() == plan["original"]
    after = json.loads(plan["path"].read_bytes())
    assert after["content_hash"] == document["content_hash"]
    assert after["blocks"] == document["blocks"]
    assert after["figures"][0]["id"] == figure_id
    assert after["figures"][0]["source_url"] == document["figures"][0]["source_url"]
    assert report.read_bytes() == b'unchanged report with original document snapshot'
    assert notes.read_bytes() == b'unchanged notes and anchors'
    assert repair.existing_asset_valid(after["figures"][0], root / "papers" / key)
    before = snapshot(root)
    again = repair.make_plan(root, key, [figure_id])
    assert again["figures"][0]["status"] == "already_cached"
    assert repair.apply_plan(again, tmp_path / "missing-config.yaml", "/missing") == {
        "status": "unchanged", "repaired": 0}
    assert snapshot(root) == before


def test_changed_document_aborts_before_any_publish(archive, tmp_path, engine):
    root, key, figure_id, _ = archive
    plan = repair.make_plan(root, key, [figure_id])
    staged = tmp_path / "staged"
    staged.mkdir()
    asset = engine.cache_raster(png(), staged)
    plan["path"].write_bytes(plan["original"] + b"\n")
    with pytest.raises(ValueError, match="changed"):
        repair.publish(plan, staged, {figure_id: asset}, [])
    assert not (root / ".svg-repair-backups").exists()
    assert not (root / "papers" / key / "figures").exists()


def test_apply_downloads_and_composites_every_panel_without_extraction(archive, tmp_path, engine, monkeypatch):
    from research_digest import documents
    root, key, figure_id, original = archive
    config = tmp_path / "config.yaml"
    config.write_text(json.dumps({"output_dir": str(root), "sources": [], "daily": {"enabled": False}}))
    sources = []

    def download(_client, source, _config, *, maximum_bytes):
        assert maximum_bytes == repair.MAX_SVG_BYTES
        sources.append(source)
        return SVG, "image/svg+xml", source

    def renderer(_body, _python):
        return png("red" if len(sources) == 1 else "blue")

    monkeypatch.setattr(documents, "_download", download)
    monkeypatch.setattr(repair, "render_svg", renderer)
    plan = repair.make_plan(root, key, [figure_id])
    result = repair.apply_plan(plan, config, "/fake-renderer-used-by-test")
    assert result["repaired"] == 1
    assert len(sources) == 2
    updated = json.loads(plan["path"].read_bytes())
    assert updated["blocks"] == original["blocks"]
    assert updated["content_hash"] == original["content_hash"]
    assert updated["figures"][0]["height"] == 44
    with Image.open(updated["figures"][0]["asset_path"]) as image:
        assert image.getpixel((10, 5)) == (255, 0, 0)
        assert image.getpixel((10, 40)) == (0, 0, 255)


def test_real_system_renderer_if_available():
    if sys.platform != "linux":
        pytest.skip("Production SVG renderer uses Linux gi/Rsvg/cairo")
    check = subprocess.run(["/usr/bin/python3", "-I", "-c",
                            'import gi,cairo;gi.require_version("Rsvg","2.0");from gi.repository import Rsvg'],
                           capture_output=True, timeout=10)
    if check.returncode:
        pytest.skip("System gi/Rsvg/cairo unavailable")
    image = Image.open(io.BytesIO(repair.render_svg(SVG)))
    assert image.size == (2400, 1200)
    assert image.getpixel((5, 5))[:3] == (0, 0, 255)
