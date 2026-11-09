"""外観照合（match_images）。画像は T06 と同じ作り方で合成する。"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "fixtures"))

import generate as g  # noqa: E402

from app.services.match import match_images  # noqa: E402

LINES = g.strokes(seed=7, n=26)
CANVAS = g.canvas(LINES)
PNG = g.png(CANVAS)


def end_of(cv: Image.Image) -> bytes:
    """g.screen と同じ枠に、縦横比を保って縮小して置く。"""
    im = Image.new("RGB", g.SCREEN, (72, 72, 76))
    area = (g.SCREEN[0] - g.BAR_LEFT - 24, g.SCREEN[1] - g.BAR_TOP - 24)
    scale = min(area[0] / cv.width, area[1] / cv.height)
    small = cv.resize((round(cv.width * scale), round(cv.height * scale)), Image.LANCZOS)
    im.paste(small, (g.BAR_LEFT + (area[0] - small.width) // 2 + 12, g.BAR_TOP + (area[1] - small.height) // 2 + 12))
    return g.jpeg(im)


def test_same_drawing_matches():
    r = match_images(end_of(CANVAS), PNG)
    assert r["result"] == "match", r


def test_rotated_15_degrees_matches():
    # キャンバスを15°回した画面。隅には暗い背景が入るが、マスクの外なので混ざらない
    rotated = CANVAS.rotate(15, resample=Image.BICUBIC, expand=True, fillcolor=(72, 72, 76))
    r = match_images(end_of(rotated), PNG)
    assert r["result"] == "match", r


def test_other_drawing_is_not_match():
    other = g.canvas(g.strokes(seed=99, n=18))
    r = match_images(end_of(other), PNG)
    assert r["result"] in ("mismatch", "unverified"), r


def test_no_end_image():
    assert match_images(None, PNG) == {"result": "unverified", "score": None, "reason": "終了画面がない"}
    assert match_images(end_of(CANVAS), None)["reason"] == "PNG がない"


def test_zoomed_part_is_unverified():
    # 絵の一部（左上の 1/3）だけを大きく拡大した画面
    w, h = g.CANVAS
    part = CANVAS.crop((0, 0, w // 3, h // 3))
    r = match_images(end_of(part), PNG)
    assert r["result"] == "unverified", r


def test_few_more_lines_still_match():
    similar = g.png(g.canvas(LINES + g.strokes(seed=11, n=3)))
    assert similar != PNG  # ハッシュは違う
    r = match_images(end_of(CANVAS), similar)
    assert r["result"] == "match", r


def test_transparent_png_is_white():
    rgba = CANVAS.convert("RGBA")
    px = rgba.load()
    for x in range(0, 200):
        for y in range(0, 200):
            if px[x, y][:3] == (255, 255, 255):
                px[x, y] = (0, 0, 0, 0)
    import io

    b = io.BytesIO()
    rgba.save(b, "PNG")
    r = match_images(end_of(CANVAS), b.getvalue())
    assert r["result"] == "match", r
