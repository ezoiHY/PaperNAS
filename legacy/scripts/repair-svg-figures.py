#!/usr/bin/env python3
"""Repair existing SVG-only figure assets without extracting/analyzing a paper.

Default is a read-only, network-free plan. --apply uses the engine's public URL
validation, byte bounds and source pacing; only then are source HTTP timestamps
updated. It stages all images first, uses the engine output lock, backs up the
document and existing assets, and atomically patches only figure asset fields.
The catalog notices the changed document stat; semantic text signatures do not
change. No database, report, Markdown, notes, or text block is written.

Run using the research-digest venv, with its source available on PYTHONPATH.
The renderer uses system Python with gi/Rsvg/cairo, not the engine venv.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urldefrag, urljoin, urlparse

from bs4 import BeautifulSoup
from PIL import Image

MAX_SVG_BYTES = 5 * 1024 * 1024
MAX_TOTAL_BYTES = 30 * 1024 * 1024
MAX_PIXELS = 12_000_000
MAX_PANELS = 6
ASSET_FIELDS = {"asset_path", "mime_type", "sha256", "width", "height", "warning"}
SVG_NS = "http://www.w3.org/2000/svg"
XLINK_NS = "http://www.w3.org/1999/xlink"
ALLOWED_TAGS = set("svg g defs path rect circle ellipse line polyline polygon text tspan "
                   "textPath clipPath mask linearGradient radialGradient stop pattern marker "
                   "use symbol title desc".split())
FRAGMENT = re.compile(r"#[A-Za-z_][A-Za-z0-9_.:-]*\Z")

# No shell, file inputs, base URI, or user-controlled imports are passed to this
# worker. Sanitized XML arrives on stdin; only a bounded PNG is returned.
RENDER_WORKER = r'''
import sys,io,resource
resource.setrlimit(resource.RLIMIT_AS,(1024**3,1024**3))
resource.setrlimit(resource.RLIMIT_CPU,(20,20))
import gi,cairo
gi.require_version("Rsvg","2.0")
from gi.repository import Rsvg
width,height=map(int,sys.argv[1:])
if not(0<width<=4096 and 0<height<=4096 and width*height<=12000000):
    raise ValueError("Invalid render size")
data=sys.stdin.buffer.read(5*1024*1024+1)
if len(data)>5*1024*1024: raise ValueError("SVG exceeds size limit")
handle=Rsvg.Handle.new_from_data(data)
surface=cairo.ImageSurface(cairo.FORMAT_ARGB32,width,height)
context=cairo.Context(surface)
context.set_source_rgb(1,1,1);context.paint()
viewport=Rsvg.Rectangle();viewport.x=0;viewport.y=0;viewport.width=width;viewport.height=height
if not handle.render_document(context,viewport): raise ValueError("SVG renderer failed")
output=io.BytesIO();surface.write_to_png(output)
if len(output.getvalue())>5*1024*1024: raise ValueError("Rendered PNG exceeds size limit")
sys.stdout.buffer.write(output.getvalue())
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def inside(root: Path, path: Path) -> Path:
    root = root.resolve()
    path = path.absolute()
    if not path.is_relative_to(root):
        raise ValueError("Path is outside the paper directory")
    for item in (path, *path.parents):
        if item == root:
            break
        if item.is_symlink():
            raise ValueError("Repair paths cannot use symlinks")
    if not path.resolve().is_relative_to(root):
        raise ValueError("Resolved path is outside the paper directory")
    return path


def safe_url(value: str) -> str:
    parsed = urlparse(value)
    if (parsed.scheme not in {"http", "https"} or not parsed.hostname
            or parsed.username or parsed.password or parsed.fragment):
        raise ValueError("Figure source must be a credential-free public HTTP(S) URL")
    return value


def sanitized_svg(body: bytes) -> tuple[bytes, int, int]:
    """Accept only self-contained static SVG; reject rather than silently alter art."""
    if len(body) > MAX_SVG_BYTES:
        raise ValueError("SVG exceeds 5 MiB limit")
    text = body.decode("utf-8-sig", errors="strict")
    if re.search(r"<!\s*(?:DOCTYPE|ENTITY)|<\?xml-stylesheet", text, re.I):
        raise ValueError("SVG declarations, entities and stylesheets are forbidden")
    root = ET.fromstring(text)
    if root.tag != "{" + SVG_NS + "}svg":
        raise ValueError("Expected an SVG namespace root")
    count = 0
    for node in root.iter():
        count += 1
        if count > 25_000:
            raise ValueError("SVG element limit exceeded")
        if not node.tag.startswith("{" + SVG_NS + "}") or node.tag.split("}")[-1] not in ALLOWED_TAGS:
            raise ValueError("SVG contains unsupported or active elements")
        for attribute, value in node.attrib.items():
            local = attribute.split("}")[-1]
            if local.lower().startswith("on") or local in {"base", "src"}:
                raise ValueError("SVG events, base URLs and resource sources are forbidden")
            if attribute.startswith("{") and attribute not in {
                "{" + XLINK_NS + "}href", "{http://www.w3.org/XML/1998/namespace}space"
            }:
                raise ValueError("Unsupported SVG attribute namespace")
            if local == "href" and not FRAGMENT.fullmatch(value):
                raise ValueError("SVG references must be local fragments")
            # Reject CSS escapes/comments/@ rules so external url() references
            # cannot be disguised; permit only plain url(#id) paint references.
            if "\\" in value or "/*" in value or "@" in value:
                raise ValueError("SVG CSS escapes, comments and at-rules are forbidden")
            cleaned = re.sub(r"url\(\s*(['\"]?)(#[A-Za-z_][A-Za-z0-9_.:-]*)\1\s*\)", "", value, flags=re.I)
            if re.search(r"url\s*\(|expression\s*\(|(?:https?|file|data|javascript):", cleaned, re.I):
                raise ValueError("SVG external or executable references are forbidden")
    viewbox = root.attrib.get("viewBox", "").replace(",", " ").split()
    if len(viewbox) != 4:
        raise ValueError("SVG requires an explicit viewBox")
    x, y, width, height = map(float, viewbox)
    if not all(math.isfinite(v) for v in (x, y, width, height)) or width <= 0 or height <= 0:
        raise ValueError("Invalid SVG viewBox")
    # 2400 pixels on the longest edge is sufficient for a native zoomable figure;
    # preserve the original viewBox aspect ratio rather than HTML display sizes.
    factor = min(2400 / width, 2400 / height)
    raster_width, raster_height = max(1, round(width * factor)), max(1, round(height * factor))
    root.set("width", str(raster_width))
    root.set("height", str(raster_height))
    ET.register_namespace("", SVG_NS)
    ET.register_namespace("xlink", XLINK_NS)
    cleaned = ET.tostring(root, encoding="utf-8")
    if len(cleaned) > MAX_SVG_BYTES:
        raise ValueError("Sanitized SVG exceeds 5 MiB limit")
    return cleaned, raster_width, raster_height


def render_svg(body: bytes, python: str = "/usr/bin/python3") -> bytes:
    cleaned, width, height = sanitized_svg(body)
    result = subprocess.run([python, "-I", "-c", RENDER_WORKER, str(width), str(height)],
                            input=cleaned, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=25, check=False)
    if result.returncode or not result.stdout.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Isolated SVG renderer failed; system Python needs gi, Rsvg and cairo")
    if len(result.stdout) > MAX_SVG_BYTES:
        raise ValueError("Rendered PNG exceeds size limit")
    with Image.open(io.BytesIO(result.stdout)) as image:
        if image.size != (width, height):
            raise ValueError("Unexpected SVG render dimensions")
        image.verify()
    return result.stdout


def composite_panels(panels: list[bytes]) -> bytes:
    if not 1 <= len(panels) <= MAX_PANELS:
        raise ValueError("Invalid SVG panel count")
    dimensions = []
    for panel in panels:
        if len(panel) > MAX_SVG_BYTES:
            raise ValueError("Rendered panel exceeds byte bounds")
        with Image.open(io.BytesIO(panel)) as image:
            if (image.format != "PNG" or not 0 < image.width <= 4096
                    or not 0 < image.height <= 4096 or image.width * image.height > MAX_PIXELS):
                raise ValueError("Invalid rendered panel")
            # Opening a PNG reads its header, not the pixel buffer. Compute all
            # scaled bounds before any decoding, resizing, or canvas allocation.
            dimensions.append(image.size)
    # Existing HTML places these panels in separate rows. Equal-width fit keeps
    # their text equally legible and preserves DOM order and full panel bounds.
    width = max(size[0] for size in dimensions)
    scaled_heights = [max(1, round(source_height * width / source_width))
                      for source_width, source_height in dimensions]
    gap = 24 if len(panels) > 1 else 0
    height = sum(scaled_heights) + gap * (len(panels) - 1)
    if height > 12_000 or width * height > MAX_PIXELS:
        raise ValueError("Composite figure exceeds pixel bounds")
    output = Image.new("RGB", (width, height), "white")
    y = 0
    for panel, panel_height in zip(panels, scaled_heights, strict=True):
        with Image.open(io.BytesIO(panel)) as source:
            image = source.convert("RGB")
            if image.size != (width, panel_height):
                image = image.resize((width, panel_height), Image.Resampling.LANCZOS)
            output.paste(image, (0, y))
        y += panel_height + gap
    result = io.BytesIO()
    output.save(result, format="PNG")
    if len(result.getvalue()) > MAX_SVG_BYTES:
        raise ValueError("Composite figure exceeds 5 MiB limit")
    return result.getvalue()


def existing_asset_valid(figure: dict, paper_dir: Path) -> bool:
    if not figure.get("asset_path") or figure.get("mime_type") != "image/png":
        return False
    path = inside(paper_dir / "figures", Path(figure["asset_path"]))
    if not path.is_file() or path.stat().st_size > 12 * 1024 * 1024:
        return False
    body = path.read_bytes()
    return body.startswith(b"\x89PNG\r\n\x1a\n") and sha(body) == figure.get("sha256")


def make_plan(root: Path, key: str, figure_ids: list[str]) -> dict:
    if not re.fullmatch(r"[a-f0-9]{20}", key):
        raise ValueError("Invalid paper key")
    if not figure_ids or len(figure_ids) != len(set(figure_ids)):
        raise ValueError("Select one or more distinct figure IDs explicitly")
    paper_dir = inside(root, root / "papers" / key)
    path = inside(paper_dir, paper_dir / "document.json")
    original = path.read_bytes()
    document = json.loads(original)
    if hashlib.sha256(document["paper_identity"].encode()).hexdigest()[:20] != key:
        raise ValueError("Paper identity does not match its directory")
    material_path = inside(paper_dir, Path(document.get("material_path") or ""))
    if material_path.suffix.lower() not in {".html", ".htm"} or material_path.stat().st_size > 50 * 1024 * 1024:
        raise ValueError("Expected bounded saved HTML source material")
    material = material_path.read_bytes()
    if sha(material) != document["content_hash"]:
        raise ValueError("Saved HTML hash differs from the extracted document")
    material_url = safe_url(document.get("material_url") or "")
    soup = BeautifulSoup(material, "html.parser")
    figures = {figure["id"]: figure for figure in document["figures"]}
    if len(figures) != len(document["figures"]):
        raise ValueError("Duplicate stored figure IDs")
    plans = []
    for figure_id in figure_ids:
        if figure_id not in figures:
            raise ValueError("Selected figure does not exist")
        figure = figures[figure_id]
        if existing_asset_valid(figure, paper_dir):
            plans.append({"id": figure_id, "status": "already_cached", "sources": []})
            continue
        origin, fragment = urldefrag(figure.get("source_url") or "")
        if origin != urldefrag(material_url)[0] or not fragment:
            raise ValueError("Missing SVG figure must refer to its saved HTML figure anchor")
        expected = "fig-" + sha((fragment + ":0").encode())[:16]
        if expected != figure_id:
            raise ValueError("Figure ID does not match the saved HTML anchor")
        nodes = soup.find_all(id=fragment)
        if len(nodes) != 1 or nodes[0].name not in {"figure", "div"}:
            raise ValueError("Expected one unambiguous saved source figure")
        node = nodes[0]
        if node.find("img"):
            raise ValueError("This repair only supports SVG-only source figures")
        objects = node.find_all("object")
        if not 1 <= len(objects) <= MAX_PANELS or any(item.get("type") != "image/svg+xml" for item in objects):
            raise ValueError("Expected one or more SVG object panels")
        # Refuse arbitrary multi-column layouts; this tool only repairs the
        # verified vertically stacked LaTeXML figures and single-panel figures.
        if len(objects) > 1 and len(node.select(".ltx_flex_break")) < len(objects) - 1:
            raise ValueError("Multiple panels lack explicit vertical source layout")
        sources = []
        for item in objects:
            raw = str(item.get("data") or "")
            if not raw or urlparse(raw).scheme in {"data", "file", "javascript", "blob"}:
                raise ValueError("Unsupported SVG object source")
            source = safe_url(urljoin(material_url, raw))
            if urlparse(source).hostname != urlparse(material_url).hostname:
                raise ValueError("SVG source is not on the saved material host")
            sources.append(source)
        plans.append({"id": figure_id, "status": "repair", "sources": sources})
    return {"root": root.resolve(), "paper_dir": paper_dir, "path": path, "original": original,
            "document": document, "figures": plans, "key": key}


def patched_document(document: dict, assets: dict[str, dict]) -> dict:
    updated = copy.deepcopy(document)
    found = set()
    for figure in updated["figures"]:
        if figure["id"] in assets:
            asset = assets[figure["id"]]
            if not set(asset).issubset(ASSET_FIELDS):
                raise ValueError("Repair attempted to modify non-asset figure metadata")
            figure.update(asset)
            found.add(figure["id"])
    if found != set(assets):
        raise ValueError("Repair target vanished")
    return updated


def publish(plan: dict, staged: Path, assets: dict[str, dict], provenance: list[dict]) -> Path:
    from research_digest.models import Document
    from research_digest.storage import run_lock
    root, paper_dir, path = plan["root"], plan["paper_dir"], plan["path"]
    destination = inside(paper_dir, paper_dir / "figures")
    mapped = {key: {**asset, "asset_path": str(destination / Path(asset["asset_path"]).name), "warning": None}
              for key, asset in assets.items()}
    updated = patched_document(plan["document"], mapped)
    Document.model_validate(updated)
    with run_lock(root):
        if path.read_bytes() != plan["original"]:
            raise ValueError("Document changed while staging; rerun the repair")
        backup_root = inside(root, root / ".svg-repair-backups")
        backup_root.mkdir(mode=0o700, exist_ok=True)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = backup_root / f"{timestamp}-{plan['key']}-{uuid.uuid4().hex[:8]}"
        backup.mkdir(mode=0o700)
        (backup / "document.json").write_bytes(plan["original"])
        os.chmod(backup / "document.json", 0o600)
        # Cache entries are immutable and new names are content hashes; still
        # preserve all previous figure assets to make rollback self-contained.
        if destination.exists():
            for item in destination.rglob("*"):
                inside(destination, item)
                if item.is_file() and item.stat().st_size > 12 * 1024 * 1024:
                    raise ValueError("Unexpectedly large existing figure asset")
            shutil.copytree(destination, backup / "figures")
        manifest = {"paper_key": plan["key"], "document_sha256_before": sha(plan["original"]),
                    "asset_updates": mapped, "svg_sources": provenance,
                    "note": "Only document figure asset fields changed. Reports and notes untouched."}
        (backup / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        destination.mkdir(mode=0o700, exist_ok=True)
        published = []
        temporary = None
        try:
            for source in staged.iterdir():
                if not re.fullmatch(r"[a-f0-9]{64}(?:-(?:thumb|preview)-v1)?\.(?:png|webp)", source.name):
                    raise ValueError("Unexpected staged asset filename")
                target = inside(destination, destination / source.name)
                data = source.read_bytes()
                if target.exists():
                    if target.read_bytes() != data:
                        raise ValueError("Existing immutable asset has different bytes")
                    continue
                descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                published.append(target)
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(data); handle.flush(); os.fsync(handle.fileno())
            if path.read_bytes() != plan["original"]:
                raise ValueError("Document changed before commit")
            with tempfile.NamedTemporaryFile(dir=paper_dir, prefix=".svg-repair-", delete=False) as handle:
                temporary = Path(handle.name)
                handle.write((json.dumps(updated, ensure_ascii=False, indent=2) + "\n").encode())
                handle.flush(); os.fsync(handle.fileno())
            temporary.replace(path)
        except BaseException:
            for item in published:
                item.unlink(missing_ok=True)
            if temporary:
                temporary.unlink(missing_ok=True)
            raise
    return backup


def apply_plan(plan: dict, config_path: Path, renderer_python: str) -> dict:
    from research_digest.config import load_config
    from research_digest.documents import _download
    from research_digest.figures import cache_raster
    from research_digest.sources import USER_AGENT
    import httpx
    repairs = [item for item in plan["figures"] if item["status"] == "repair"]
    if not repairs:
        return {"status": "unchanged", "repaired": 0}
    config = load_config(config_path)
    if Path(config.output_dir).resolve() != plan["root"]:
        raise ValueError("Configuration output directory does not match --root")
    total = 0
    assets, provenance = {}, []
    with tempfile.TemporaryDirectory(prefix="paper-nas-svg-repair-") as temporary:
        staged = Path(temporary)
        with httpx.Client(timeout=config.discovery.timeout_seconds, follow_redirects=False,
                          headers={"User-Agent": USER_AGENT}) as client:
            for item in repairs:
                panels = []
                for source in item["sources"]:
                    allowance = min(MAX_SVG_BYTES, MAX_TOTAL_BYTES - total)
                    if allowance <= 0:
                        raise ValueError("Repair transfer byte limit reached")
                    body, _content_type, final_url = _download(client, source, config, maximum_bytes=allowance)
                    total += len(body)
                    panels.append(render_svg(body, renderer_python))
                    provenance.append({"figure_id": item["id"], "source": source,
                                       "final_url": final_url, "svg_sha256": sha(body)})
                assets[item["id"]] = cache_raster(composite_panels(panels), staged)
        backup = publish(plan, staged, assets, provenance)
    return {"status": "repaired", "repaired": len(assets), "backup": str(backup),
            "catalog": "Refreshes on next normal read; semantic text unchanged"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True, help="Existing research-digest output directory")
    parser.add_argument("--key", required=True)
    parser.add_argument("--figure-id", action="append", required=True)
    parser.add_argument("--config", type=Path, help="Existing engine configuration; required for --apply")
    parser.add_argument("--renderer-python", default="/usr/bin/python3")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args(argv)
    try:
        plan = make_plan(args.root.expanduser().resolve(), args.key, args.figure_id)
        if args.apply:
            if not args.config:
                parser.error("--apply requires --config")
            result = apply_plan(plan, args.config, args.renderer_python)
        else:
            result = {"status": "dry_run", "key": args.key, "figures": plan["figures"],
                      "writes": False, "network": False}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        # Avoid rendering configuration values or network request headers.
        print(f"SVG repair stopped: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
