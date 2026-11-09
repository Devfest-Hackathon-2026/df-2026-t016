"""全体画像の判定（T13）。共通の試験画像（shared/vectors/whole_canvas）と judge_whole。"""

from __future__ import annotations

import json
from pathlib import Path

import cv2
import numpy as np
import pytest

from app.services import whole as W

ROOT = Path(__file__).resolve().parents[2]
VEC = ROOT / "shared/vectors/whole_canvas"
EXP = json.loads((VEC / "expected.json").read_text(encoding="utf-8"))
P = W.load_params()


def read(name: str) -> np.ndarray:
    return cv2.imdecode(np.frombuffer((VEC / f"{name}.png").read_bytes(), np.uint8), cv2.IMREAD_GRAYSCALE)


def canvas(name: str) -> np.ndarray:
    x, y, w, h = W.detect_canvas(read(name), P)
    return read(name)[y : y + h, x : x + w]


def jpeg_of(name: str, quality: int = 70) -> bytes:
    ok, buf = cv2.imencode(".jpg", read(name), [cv2.IMWRITE_JPEG_QUALITY, quality])
    assert ok
    return buf.tobytes()


def png_of(name: str) -> bytes:
    ok, buf = cv2.imencode(".png", read(name))
    return buf.tobytes()


@pytest.mark.parametrize("name", list(EXP["detect"]))
def test_detect_matches_expected(name):
    want = EXP["detect"][name]["rect"]
    got = W.detect_canvas(read(name), P)
    if want is None:
        assert got is None
    else:
        assert got is not None and all(abs(a - b) <= 2 for a, b in zip(got, want))


@pytest.mark.parametrize("case", EXP["compare"], ids=[f"{c['a']}-{c['b']}" for c in EXP["compare"]])
def test_compare_matches_expected(case):
    b = read(case["b"]) if case["bIsPng"] else canvas(case["b"])
    r = W.compare(canvas(case["a"]), b, P, to_png=case["bIsPng"])
    assert (r["result"], r["reason"]) == (case["result"], case["reason"])


def test_detect_survives_jpeg():
    # サーバは JPEG で受け取るので、JPEG を通しても同じ四角形になること
    for name in ("landscape", "portrait", "light", "step3"):
        g = W.screen_gray(jpeg_of(name, 60))
        assert all(abs(a - b) <= 2 for a, b in zip(W.detect_canvas(g, P), EXP["detect"][name]["rect"]))


def test_judge_whole_all_linked():
    items = [{"seq": 10 * i, "sha256": f"{i:064x}", "jpeg": jpeg_of(f"step{i}")} for i in range(6)]
    r = W.judge_whole(items, png_of("png_final"), shown=True)
    assert r["shown"] is True and len(r["items"]) == 6 and len(r["links"]) == 5
    assert all(it["received"] and it["canvas"] for it in r["items"])
    assert all(l["result"] == "linked" for l in r["links"])
    assert [(l["from"], l["to"]) for l in r["links"]] == [(i, i + 1) for i in range(5)]
    assert r["toPng"]["result"] == "linked"
    c = r["items"][0]["canvas"]
    assert set(c) == {"x", "y", "w", "h"} and all(0 <= v <= 1 for v in c.values())


def test_judge_whole_missing_and_undetected():
    items = [
        {"seq": 1, "sha256": "a" * 64, "jpeg": jpeg_of("step0")},
        {"seq": 2, "sha256": "b" * 64, "jpeg": None},  # 届いていない
        {"seq": 3, "sha256": "c" * 64, "jpeg": jpeg_of("step2")},
        {"seq": 4, "sha256": "d" * 64, "jpeg": jpeg_of("full")},  # 検出できない
        {"seq": 5, "sha256": "e" * 64, "jpeg": jpeg_of("step4")},
    ]
    r = W.judge_whole(items, png_of("png_final"), shown=False)
    assert [it["received"] for it in r["items"]] == [True, False, True, True, True]
    assert r["items"][3]["canvas"] is None
    reasons = [(l["result"], l["reason"]) for l in r["links"]]
    assert reasons[0] == reasons[1] == ("unconfirmed", W.REASON_NOT_RECEIVED)
    assert reasons[2] == reasons[3] == ("unconfirmed", W.REASON_NO_CANVAS)
    assert all(l["kept"] is None for l in r["links"])
    assert r["shown"] is False


def test_judge_whole_png_cases():
    one = [{"seq": 0, "sha256": "a" * 64, "jpeg": jpeg_of("step5")}]
    assert W.judge_whole(one, None, True)["toPng"] is None
    assert W.judge_whole(one, None, True)["links"] == []
    gone = [{"seq": 0, "sha256": "a" * 64, "jpeg": None}]
    assert W.judge_whole(gone, png_of("png_final"), True)["toPng"]["reason"] == W.REASON_NOT_RECEIVED
    assert W.judge_whole([], png_of("png_final"), True) is None


def test_params_are_shared():
    assert P["version"] == 1 and P["keptMin"] == 0.30 and P["grid"] == 16


# ---------------------------------------------------------------- 実機の画面（T13a、Nさんが 11/6 に撮った）

REAL = VEC / "real"
REAL_EXP = json.loads((REAL / "expected.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("name", list(REAL_EXP))
def test_real_screens(name):
    g = W.screen_gray((REAL / name).read_bytes())
    rect, why = W.detect_canvas_why(g, P)
    assert (rect is not None) == REAL_EXP[name]["whole"], why


def test_ignore_mask_uses_pixels():
    m = W._ignore_mask(768, 1024, P)
    assert m[: P["topBarPx"], :].all() and m[:, : P["leftBarPx"]].all()
    assert not m[P["topBarPx"] :, P["leftBarPx"] :].any()
