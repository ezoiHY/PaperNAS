import pytest

from papernas_v2.parsing import merge_picture_regions, normalize_image


def test_caption_attached_only_to_right_panel_keeps_both_panels():
    right = {"x0": 340, "y0": 70, "x1": 470, "y1": 240}
    left = {"x0": 140, "y0": 90, "x1": 270, "y1": 240}
    figure = {
        "label": "Figure 2",
        "page": 4,
        "bbox": right,
        "caption": "Figure 2: (left) scaled attention. (right) multi-head attention.",
        "region_quality": "layout_region",
    }
    pictures = [{"page": 4, "bbox": left, "label": None}, {"page": 4, "bbox": right, "label": "Figure 2"}]
    caption = {"page": 4, "label": "Figure 2", "caption_bbox": {"x0": 72, "y0": 260, "x1": 540, "y1": 300}}
    result = merge_picture_regions([figure], pictures, [caption])[0]
    assert result["bbox"]["x0"] < left["x0"]
    assert result["bbox"]["x1"] > right["x1"]
    assert result["panel_regions"] == 2
    # A missing panel must not silently become a complete cropped figure.
    missing = merge_picture_regions([figure], pictures[1:], [caption])[0]
    assert missing["region_quality"] == "page_fallback"
    assert missing["bbox"] == {}


def test_svg_external_reference_is_rejected():
    with pytest.raises(ValueError, match="External SVG"):
        normalize_image(
            b'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><image href="http://127.0.0.1/private"/></svg>',
            "image/svg+xml",
        )
    with pytest.raises(ValueError, match="External SVG"):
        normalize_image(
            b'<svg xmlns="http://www.w3.org/2000/svg"><style>@import "https://example.org/x.css";</style></svg>',
            "image/svg+xml",
        )


def test_attention_paper_real_detector_boxes_preserve_panel_titles():
    left = {"x0": 174.149, "y0": 93.743, "x1": 239.503, "y1": 219.395}
    right = {"x0": 346.61, "y0": 71.023, "x1": 466.902, "y1": 238.175}
    caption = {"x0": 108, "y0": 274.388, "x1": 503.997, "y1": 295.335}
    item = {
        "label": "Figure 2",
        "page": 4,
        "bbox": right,
        "caption": "Figure 2: (left) Scaled Dot-Product Attention. (right) Multi-Head Attention.",
        "region_quality": "layout_region",
    }
    result = merge_picture_regions(
        [item],
        [{"page": 4, "bbox": left, "label": None}, {"page": 4, "bbox": right, "label": "Figure 2"}],
        [{"page": 4, "label": "Figure 2", "caption_bbox": caption}],
    )[0]
    assert result["panel_regions"] == 2
    assert result["bbox"]["x0"] <= 108 and result["bbox"]["x1"] >= 503.997
    assert result["bbox"]["y1"] >= 266
