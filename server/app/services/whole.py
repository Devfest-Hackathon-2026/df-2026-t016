"""途中の全体画像のつながり（設計書9章 F9、tasks/T13）。純粋な関数。

手順と値は tasks/T13_全体画像のつながり.md と shared/params/whole_canvas.json が正。
試作（tools/prototypes/whole_canvas/proto.py）を移したもので、端末（Swift の WholeCanvasDetector）と同じ判定をする。
迷う場合は unconfirmed に倒す。「別の絵」とは判定しない。
"""

from __future__ import annotations

import io
import json
import os
from functools import lru_cache
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

SCREEN_LONG = 1024

REASON_NOT_RECEIVED = "画像が届いていない"
REASON_NO_CANVAS = "キャンバスを検出できない"
REASON_ASPECT = "キャンバスの縦横比が違う"
REASON_FEW = "描かれた部分が少なく比べられない"
REASON_CHANGED = "前の全体画像からの変化が大きい"
REASON_CHANGED_PNG = "最後の全体画像と PNG の違いが大きい"


def _params_path() -> Path:
    env = os.environ.get("WHOLE_PARAMS")
    if env:
        return Path(env)
    here = Path(__file__).resolve()
    for base in (here.parents[2], here.parents[3]):  # Docker: /srv、手元: リポジトリのルート
        p = base / "shared" / "params" / "whole_canvas.json"
        if p.exists():
            return p
    raise RuntimeError("shared/params/whole_canvas.json not found; set WHOLE_PARAMS")


@lru_cache(maxsize=1)
def load_params() -> dict:
    return json.loads(_params_path().read_text(encoding="utf-8"))


# ---------------------------------------------------------------- A. キャンバスの検出


def _ignore_mask(h: int, w: int, p: dict) -> np.ndarray:
    """無視する領域（【11/6】長辺1024px のときの画素）。上から topBarPx の行と、左から leftBarPx の列。

    割合（もとの uiMask）だと、縦の真ん中に置かれるサイドバーが横持ちで外れた（T13）。
    """
    m = np.zeros((h, w), bool)
    m[: p["topBarPx"], :] = True
    m[:, : p["leftBarPx"]] = True
    return m


def detect_canvas_why(gray: np.ndarray, p: dict) -> tuple[tuple[int, int, int, int] | None, str]:
    """(x, y, w, h) か None と、外れた理由（試験と調べもの用）を返す。gray は長辺1024px の uint8。"""
    h, w = gray.shape
    ig = _ignore_mask(h, w, p)
    r = p["ringPx"]
    ring = np.zeros((h, w), bool)
    ring[:r, :] = ring[-r:, :] = True
    ring[:, :r] = ring[:, -r:] = True
    ring &= ~ig
    vals = gray[ring]
    if vals.size == 0:
        return None, "ring"
    bg = int(np.bincount(vals, minlength=256).argmax())
    tol = p["bgTol"]
    if np.mean(np.abs(vals.astype(int) - bg) <= tol) < p["ringBgMin"]:
        return None, "ring-not-bg"
    nb = (np.abs(gray.astype(int) - bg) > tol) & ~ig
    # 幅1〜2画素の細い線（Procreate の背景の格子、JPEG の縁）を取り除く。キャンバスの面は残る。
    # 端末は JPEG にする前の画素で判定するので格子が許容の中に収まるが、サーバは JPEG を読むので
    # 格子の線が許容を超え、画面の端まで「キャンバスの行」に数えて余白の検査で外れていた（11/7）
    nb = cv2.morphologyEx(nb.astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8)).astype(bool)
    ry = np.where(nb.sum(1) >= p["lineMin"] * w)[0]
    cx = np.where(nb.sum(0) >= p["lineMin"] * h)[0]
    if ry.size == 0 or cx.size == 0:
        return None, "no-rect"
    y0, y1, x0, x1 = int(ry[0]), int(ry[-1]), int(cx[0]), int(cx[-1])
    rw, rh = x1 - x0 + 1, y1 - y0 + 1
    if rw * rh < p["minAreaFrac"] * w * h:
        return None, "small"
    m = p["marginPx"]
    if x0 < m or y0 < m or w - 1 - x1 < m or h - 1 - y1 < m:
        return None, "margin"
    ex = np.zeros((h, w), bool)
    ex[max(0, y0 - m) : y1 + m + 1, max(0, x0 - m) : x1 + m + 1] = True
    if (ex & ig).any():
        return None, "ui-overlap"
    if nb[y0 : y1 + 1, x0 : x1 + 1].mean() < p["fillMin"]:
        return None, "fill"
    cw = max(2, int(round(rw * p["cornerFrac"])))
    ch = max(2, int(round(rh * p["cornerFrac"])))
    for yy, xx in [(y0, x0), (y0, x1 - cw + 1), (y1 - ch + 1, x0), (y1 - ch + 1, x1 - cw + 1)]:
        if nb[yy : yy + ch, xx : xx + cw].mean() < p["cornerMin"]:
            return None, "tilted"
    out = nb.copy()
    out[y0 : y1 + 1, x0 : x1 + 1] = False
    free = int((~ig).sum()) - rw * rh
    if out.sum() / max(free, 1) > p["outsideMax"]:
        return None, "outside"
    return (x0, y0, rw, rh), "ok"


def detect_canvas(gray: np.ndarray, p: dict) -> tuple[int, int, int, int] | None:
    return detect_canvas_why(gray, p)[0]


# ---------------------------------------------------------------- B. 2枚の比較


def _resize_long(img: np.ndarray, n: int) -> np.ndarray:
    h, w = img.shape
    s = n / max(w, h)
    return cv2.resize(img, (max(1, round(w * s)), max(1, round(h * s))), interpolation=cv2.INTER_AREA)


def _kept(a: np.ndarray, b: np.ndarray, p: dict) -> tuple[int, int]:
    a = cv2.GaussianBlur(a, (3, 3), 0.8).astype(np.float32)
    b = cv2.GaussianBlur(b, (3, 3), 0.8).astype(np.float32)
    paper = int(np.bincount(a.astype(np.uint8).ravel(), minlength=256).argmax())
    g = p["grid"]
    h, w = a.shape
    ys = np.linspace(0, h, g + 1).astype(int)
    xs = np.linspace(0, w, g + 1).astype(int)
    drawn = kept = 0
    for i in range(g):
        for j in range(g):
            ca = a[ys[i] : ys[i + 1], xs[j] : xs[j + 1]]
            cb = b[ys[i] : ys[i + 1], xs[j] : xs[j + 1]]
            if ca.size == 0:
                continue
            sa, sb, ma, mb = ca.std(), cb.std(), ca.mean(), cb.mean()
            if sa >= p["drawnStd"]:
                drawn += 1
                if sb >= p["drawnStd"] / 2 and abs(ma - mb) <= p["meanDiff"]:
                    if float(((ca - ma) * (cb - mb)).mean() / (sa * sb)) >= p["corrMin"]:
                        kept += 1
            elif abs(ma - paper) >= p["paperDiff"]:
                drawn += 1
                if sb < p["drawnStd"] and abs(ma - mb) <= p["keptDiff"]:
                    kept += 1
    return drawn, kept


def compare(a: np.ndarray, b: np.ndarray, p: dict, to_png: bool = False) -> dict:
    """a は前のキャンバス、b は次のキャンバス（または PNG）。どちらもグレースケール。"""
    a = _resize_long(a, p["norm"])
    ar = a.shape[1] / a.shape[0]
    best = None
    for k in range(4):
        bb = np.ascontiguousarray(np.rot90(b, k))
        if abs(ar / (bb.shape[1] / bb.shape[0]) - 1) > p["aspectTol"]:
            continue
        bb = cv2.resize(bb, (a.shape[1], a.shape[0]), interpolation=cv2.INTER_AREA)
        d, kk = _kept(a, bb, p)
        ratio = kk / d if d else -1.0
        if best is None or ratio > best[2]:
            best = (d, kk, ratio)
    if best is None:
        return {"result": "unconfirmed", "kept": None, "reason": REASON_ASPECT}
    d, kk, _ = best
    if d < p["minDrawn"]:
        return {"result": "unconfirmed", "kept": None, "reason": REASON_FEW}
    kept = round(kk / d, 2)
    if kept >= p["keptMin"]:
        return {"result": "linked", "kept": kept, "reason": None}
    return {"result": "unconfirmed", "kept": kept, "reason": REASON_CHANGED_PNG if to_png else REASON_CHANGED}


# ---------------------------------------------------------------- 確定で使う


def screen_gray(jpeg: bytes) -> np.ndarray | None:
    """JPEG をグレースケールで読み、長辺1024px でなければそろえる。"""
    g = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_GRAYSCALE)
    if g is None:
        return None
    if max(g.shape) != SCREEN_LONG:
        g = _resize_long(g, SCREEN_LONG)
    return g


def png_gray(png: bytes) -> np.ndarray:
    im = Image.open(io.BytesIO(png))
    im.load()
    if im.mode in ("RGBA", "LA", "P"):
        rgba = im.convert("RGBA")
        bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        im = Image.alpha_composite(bg, rgba)
    return np.asarray(im.convert("L"), dtype=np.uint8)


def _unconfirmed(reason: str) -> dict:
    return {"result": "unconfirmed", "kept": None, "reason": reason}


def judge_whole(items: list[dict], png_bytes: bytes | None, shown: bool, p: dict | None = None) -> dict | None:
    """items は [{"seq","sha256","jpeg": bytes | None}]（seq の順）。0件なら None。

    【T14】items に "session"（記録の番号）があれば結果にも入れる。記録をまたぐ隣どうしも同じルールで比べる。
    """
    if not items:
        return None
    p = p or load_params()
    out_items, canvases = [], []
    for it in items:
        cv = None
        rect = None
        if it.get("jpeg") is not None:
            g = screen_gray(it["jpeg"])
            if g is not None:
                rect = detect_canvas(g, p)
                if rect is not None:
                    x, y, w, h = rect
                    cv = g[y : y + h, x : x + w]
                    H, W = g.shape
                    rect = {"x": round(x / W, 3), "y": round(y / H, 3), "w": round(w / W, 3), "h": round(h / H, 3)}
        canvases.append(cv)
        item = {"seq": it["seq"], "sha256": it["sha256"], "received": it.get("jpeg") is not None, "canvas": rect}
        if "session" in it:
            item = {"session": it["session"], **item}  # 【T14】記録の番号（確定記録 v:2）
        out_items.append(item)

    links = []
    for i in range(len(items) - 1):
        a, b = out_items[i], out_items[i + 1]
        if not a["received"] or not b["received"]:
            r = _unconfirmed(REASON_NOT_RECEIVED)
        elif canvases[i] is None or canvases[i + 1] is None:
            r = _unconfirmed(REASON_NO_CANVAS)
        else:
            r = compare(canvases[i], canvases[i + 1], p)
        links.append({"from": i, "to": i + 1, **r})

    if png_bytes is None:
        to_png = None
    elif not out_items[-1]["received"]:
        to_png = _unconfirmed(REASON_NOT_RECEIVED)
    elif canvases[-1] is None:
        to_png = _unconfirmed(REASON_NO_CANVAS)
    else:
        to_png = compare(canvases[-1], png_gray(png_bytes), p, to_png=True)

    return {"shown": bool(shown), "items": out_items, "links": links, "toPng": to_png}
