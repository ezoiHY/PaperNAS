"""Isolated document parsing and verifiable figure rendering; no generative image repair."""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

import pymupdf as fitz
from PIL import Image

from .core import NeedsInput, canonical

CAPTION = re.compile(r"^\s*((?:Figure|Fig\.?)\s*\d+[a-z]?)\s*[:.\s]", re.I)
PARSER_REVISION = "2"


def label_key(value):
    match = re.search(r"(?:Figure|Fig\.?)\s*(\d+[a-z]?)", value, re.I)
    return "Figure " + match[1].lower() if match else value.strip()


def identifier(prefix, *parts):
    return prefix + hashlib.sha256(canonical(parts).encode()).hexdigest()[:24]


def basic_parse(path):
    blocks, figures = [], []
    with fitz.open(path) as pdf:
        if pdf.needs_pass:
            raise ValueError("PDF is password protected")
        if len(pdf) > 500:
            raise ValueError("PDF exceeds the 500 page limit")
        for page in pdf:
            for raw in page.get_text("blocks", sort=True):
                text = raw[4].strip()
                if not text or raw[6] != 0:
                    continue
                bbox = {"x0": raw[0], "y0": raw[1], "x1": raw[2], "y1": raw[3]}
                caption = CAPTION.match(text)
                blocks.append(
                    {
                        "text": text,
                        "page": page.number + 1,
                        "bbox": bbox,
                        "kind": "figure_caption" if caption else "paragraph",
                        "heading": "",
                    }
                )
                if caption:
                    figures.append(
                        {
                            "label": label_key(caption[1]),
                            "caption": text,
                            "page": page.number + 1,
                            "bbox": {},
                            "caption_bbox": bbox,
                            "region_quality": "page_fallback",
                        }
                    )
        return {
            "blocks": blocks,
            "figures": figures,
            "page_count": len(pdf),
            "parser": "pymupdf",
            "parser_version": fitz.VersionBind,
            "structure_quality": "basic",
            "warnings": [],
        }


def docling_parse(path, base):
    from importlib.metadata import version

    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption

    options = PdfPipelineOptions(
        do_ocr=False,
        do_table_structure=True,
        do_formula_enrichment=False,
        generate_picture_images=False,
        generate_page_images=False,
    )
    converter = DocumentConverter(
        allowed_formats=[InputFormat.PDF],
        format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=options)},
    )
    doc = converter.convert(str(path), max_num_pages=500).document
    blocks, figures, pictures, heading = [], [], [], ""
    with fitz.open(path) as pdf:
        for item, _ in doc.iterate_items():
            if not item.prov:
                continue
            prov = item.prov[0]
            page = int(prov.page_no)
            if not 1 <= page <= len(pdf):
                continue
            box = prov.bbox.to_top_left_origin(page_height=pdf[page - 1].rect.height)
            bbox = {"x0": box.l, "y0": box.t, "x1": box.r, "y1": box.b}
            kind = str(item.label.value)
            text = getattr(item, "text", "")
            if kind == "section_header":
                heading = text
            if kind == "table":
                text = item.export_to_markdown(doc=doc)
            if text.strip():
                blocks.append(
                    {"text": text.strip(), "page": page, "bbox": bbox, "kind": kind, "heading": heading}
                )
            if kind == "picture":
                caption = item.caption_text(doc)
                match = CAPTION.match(caption)
                pictures.append({"page": page, "bbox": bbox, "label": label_key(match[1]) if match else None})
                if match:
                    figures.append(
                        {
                            "label": label_key(match[1]),
                            "caption": caption,
                            "page": page,
                            "bbox": bbox,
                            "region_quality": "layout_region",
                        }
                    )
    figures = merge_picture_regions(figures, pictures, base["figures"])
    # Keep every caption candidate from the PDF, including unrecognized/vector figures.
    present = {f["label"] for f in figures}
    figures += [f for f in base["figures"] if f["label"] not in present]
    if blocks:
        base.update(
            blocks=blocks,
            figures=figures,
            parser="docling",
            parser_version=version("docling"),
            structure_quality="structured",
        )
        base["warnings"].append(
            "OCR and formula transcription are not enabled; verify formulas and scanned text in the source PDF."
        )
    return base


def merge_picture_regions(figures, pictures, captions):
    """Keep adjacent panels sharing one caption, including panels Docling leaves uncaptioned."""
    merged = {}
    for figure in figures:
        key = (figure["page"], figure["label"])
        rectangle = fitz.Rect(*(figure["bbox"][k] for k in ("x0", "y0", "x1", "y1")))
        if key in merged:
            previous = merged[key]
            old = fitz.Rect(*(previous["bbox"][k] for k in ("x0", "y0", "x1", "y1")))
            rectangle |= old
        merged[key] = {**figure, "bbox": dict(zip(("x0", "y0", "x1", "y1"), rectangle))}
    for key, figure in merged.items():
        caption = next((c for c in captions if c["page"] == key[0] and c["label"] == key[1]), {})
        caption_box = caption.get("caption_bbox", {})
        rectangle = fitz.Rect(*(figure["bbox"][k] for k in ("x0", "y0", "x1", "y1")))
        matched = set()
        for _ in range(4):
            added = False
            for index, picture in enumerate(pictures):
                if index in matched or picture["page"] != key[0] or picture["label"] not in {None, key[1]}:
                    continue
                candidate = fitz.Rect(*(picture["bbox"][k] for k in ("x0", "y0", "x1", "y1")))
                if caption_box and (
                    candidate.y1 > caption_box["y0"] + 10
                    or candidate.x1 < caption_box["x0"] - 20
                    or candidate.x0 > caption_box["x1"] + 20
                ):
                    continue
                vertical_overlap = max(0, min(candidate.y1, rectangle.y1) - max(candidate.y0, rectangle.y0))
                horizontal_overlap = max(0, min(candidate.x1, rectangle.x1) - max(candidate.x0, rectangle.x0))
                horizontal_gap = max(0, max(candidate.x0, rectangle.x0) - min(candidate.x1, rectangle.x1))
                vertical_gap = max(0, max(candidate.y0, rectangle.y0) - min(candidate.y1, rectangle.y1))
                caption_gap = (caption_box["x1"] - caption_box["x0"]) * 0.4 if caption_box else 0
                adjacent = (
                    vertical_overlap >= min(candidate.height, rectangle.height) * 0.5
                    and horizontal_gap <= max(max(candidate.width, rectangle.width) * 0.85, caption_gap)
                ) or (
                    horizontal_overlap >= min(candidate.width, rectangle.width) * 0.5 and vertical_gap <= 32
                )
                if picture["label"] == key[1] or adjacent:
                    rectangle |= candidate
                    matched.add(index)
                    added = True
            if not added:
                break
        multipart = bool(re.search(r"\b(?:left|right|top|bottom)\b|\([a-d]\)", figure["caption"], re.I))
        if (
            multipart
            and len(matched) <= 1
            and caption_box
            and rectangle.width < (caption_box["x1"] - caption_box["x0"]) * 0.7
        ):
            figure.update(bbox={}, region_quality="page_fallback")
        else:
            if multipart and len(matched) > 1 and caption_box:
                # Panel titles and axis labels can sit outside the detector's picture boxes.
                # The shared caption gives the complete horizontal extent and lower boundary.
                rectangle.x0 = min(rectangle.x0, caption_box["x0"])
                rectangle.x1 = max(rectangle.x1, caption_box["x1"])
                rectangle.y1 = max(rectangle.y1, caption_box["y0"] - 8)
            rectangle += (-4, -4, 4, 4)
            figure.update(bbox=dict(zip(("x0", "y0", "x1", "y1"), rectangle)), panel_regions=len(matched))
    return list(merged.values())


def parse_child(path, output, use_docling):
    base = basic_parse(path)
    Path(output).write_text(canonical(base))  # Basic text remains usable if the layout model times out.
    if use_docling:
        try:
            base = docling_parse(path, base)
        except Exception as error:
            base["warnings"].append("Layout parser unavailable: " + type(error).__name__)
    Path(output).write_text(canonical(base))


def parse_pdf(path, settings, input_sha):
    with tempfile.TemporaryDirectory(prefix="parse-", dir=settings.state_dir / "tmp") as temp:
        output = Path(temp) / "document.json"
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "papernas_v2.parsing",
                str(path),
                str(output),
                "1" if settings.use_docling else "0",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            _, stderr = process.communicate(timeout=settings.parse_timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            _, stderr = process.communicate()
            if not output.exists():
                raise NeedsInput("PDF 解析超时，请检查文件或缩小页数", code="parse_timeout")
        if not output.exists():
            raise NeedsInput("PDF 无法解析，请检查文件是否损坏或加密", code="parse_failed")
        data = json.loads(output.read_text())
        data["parser_version"] += "+papernas." + PARSER_REVISION
        if process.returncode:
            data["warnings"].append("Layout parsing interrupted; embedded PDF text is available.")
        doc_id = identifier("d", input_sha, data["parser"], data["parser_version"])
        for ordinal, block in enumerate(data["blocks"]):
            block.update(id=identifier("b", doc_id, ordinal), ordinal=ordinal)
        unique = {}
        for figure in data["figures"]:
            figure["id"] = identifier("f", doc_id, figure["label"])
            unique.setdefault(figure["label"], figure)
        data["figures"] = list(unique.values())
        data["id"] = doc_id
        if not data["blocks"]:
            data["warnings"].append("No embedded text found; this PDF needs OCR before text analysis.")
        return data


def render_pdf_region(path, page, bbox=None):
    with fitz.open(path) as pdf:
        if not 1 <= page <= len(pdf):
            raise NeedsInput("图表页码超出 PDF 范围", code="figure_page_invalid")
        source = pdf[page - 1]
        clip = source.rect
        if bbox:
            requested = fitz.Rect(bbox["x0"], bbox["y0"], bbox["x1"], bbox["y1"])
            clip = requested & source.rect
            if (
                clip.is_empty
                or clip.width < 8
                or clip.height < 8
                or clip.get_area() < requested.get_area() * 0.95
            ):
                raise NeedsInput("图表范围超出页面或尺寸过小", code="figure_bbox_invalid")
        scale = min(2.5, 2600 / max(clip.width, clip.height))
        pixmap = source.get_pixmap(matrix=fitz.Matrix(scale, scale), clip=clip, alpha=False)
        return pixmap.tobytes("png"), {
            "page": page,
            "bbox": {"x0": clip.x0, "y0": clip.y0, "x1": clip.x1, "y1": clip.y1},
            "width": pixmap.width,
            "height": pixmap.height,
        }


def normalize_image(body, media_type):
    if media_type == "image/svg+xml" or body.lstrip().startswith(b"<svg") or b"<svg" in body[:500]:
        from defusedxml import ElementTree

        root = ElementTree.fromstring(body)
        for node in root.iter():
            if node.tag.split("}")[-1] in {"script", "foreignObject"}:
                raise ValueError("Active SVG content")
            if node.tag.split("}")[-1] == "style" and node.text:
                if "@import" in node.text.lower() or re.search(r"url\(\s*['\"]?(?!#)", node.text, re.I):
                    raise ValueError("External SVG style")
            for key, value in node.attrib.items():
                if key.split("}")[-1] in {"href", "src"} and not value.startswith(("#", "data:image/")):
                    raise ValueError("External SVG reference")
                if any(
                    not v.strip(" \"'").startswith("#") for v in re.findall(r"url\(([^)]*)\)", value, re.I)
                ):
                    raise ValueError("External SVG style")
        with fitz.open(stream=body, filetype="svg") as doc:
            page = doc[0]
            pix = page.get_pixmap(
                matrix=fitz.Matrix(
                    min(2, 2600 / max(page.rect.width, page.rect.height)),
                    min(2, 2600 / max(page.rect.width, page.rect.height)),
                ),
                alpha=False,
            )
            body = pix.tobytes("png")
    with Image.open(io.BytesIO(body)) as picture:
        if picture.width * picture.height > 40_000_000 or min(picture.size) < 24:
            raise ValueError("Unusable image dimensions")
        picture.load()
        image = picture.convert("RGB")
        stream = io.BytesIO()
        image.save(stream, format="PNG")
        return stream.getvalue(), {"width": image.width, "height": image.height}


if __name__ == "__main__":
    parse_child(sys.argv[1], sys.argv[2], sys.argv[3] == "1")
