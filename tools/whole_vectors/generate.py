"""全体画像の判定の、共通の試験画像を作る（tasks/T13「共通の試験画像」）。

    python tools/whole_vectors/generate.py

shared/vectors/whole_canvas/ に、合成した画面（グレースケールの PNG、1024×768）と expected.json を作る。
Python（server/tests/test_whole.py）と Swift（TraceKitTests）が、同じ画像と expected.json で試験する。
- 画像は JPEG を通さない（言語によって JPEG の復号が少し違うため、画素をそろえる）
- 絵と画面の作り方は tools/prototypes/whole_canvas/demo.py と同じ。ライト表示と参照ウィンドウを足した
- 期待する結果は、設計どおり（下の EXPECT）になることを確かめてから書く。合わなければ止める
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "shared" / "vectors" / "whole_canvas"
sys.path.insert(0, str(ROOT / "server"))

from app.services.whole import compare, detect_canvas_why, load_params  # noqa: E402

P = load_params()
DARK = {"bg": 40, "bar": 28, "side": 70, "icon": 200}
LIGHT = {"bg": 205, "bar": 235, "side": 220, "icon": 90}


def drawing(seed, n, fill=None, w=1600, h=1200):
    """demo.py の drawing と同じ。白いキャンバスに n 本の線を描く。"""
    r = np.random.default_rng(seed)
    lines = []
    for _ in range(400):
        x0, y0 = int(r.integers(100, w - 100)), int(r.integers(100, h - 100))
        lines.append((x0, y0, x0 + int(r.integers(-300, 300)), y0 + int(r.integers(-300, 300)), int(r.integers(2, 10))))
    c = np.full((h, w, 3), 255, np.uint8)
    if fill:
        x, y, fw, fh, col = fill
        cv2.rectangle(c, (x, y), (x + fw, y + fh), col, -1)
    for x0, y0, x1, y1, t in lines[:n]:
        cv2.line(c, (x0, y0), (x1, y1), (30, 30, 30), t)
    return c


def screen(img, scale=0.8, angle=0.0, sw=1024, sh=768, offset=(0, 0), theme=DARK, window=False):
    """demo.py の screen と同じ画面（JPEG は通さない）。window=True で参照ウィンドウを出す。"""
    s = np.full((sh, sw, 3), theme["bg"], np.uint8)
    h, w = img.shape[:2]
    k = min(sw / w, sh / h) * scale
    cw, ch = int(w * k), int(h * k)
    small = cv2.resize(img, (cw, ch), interpolation=cv2.INTER_AREA)
    m = cv2.getRotationMatrix2D((cw / 2, ch / 2), angle, 1.0)
    m[0, 2] += sw // 2 + offset[0] - cw / 2
    m[1, 2] += sh // 2 + offset[1] - ch / 2
    mask = cv2.warpAffine(np.full((ch, cw), 255, np.uint8), m, (sw, sh), flags=cv2.INTER_NEAREST)
    warped = cv2.warpAffine(small, m, (sw, sh))
    s[mask > 0] = warped[mask > 0]
    # 【11/6】バーの大きさは実機の寸法に合わせる（上のバー33px・サイドバーは幅38px まで。T13）
    s[0:33, :] = theme["bar"]
    for i in range(8):
        cv2.rectangle(s, (20 + i * 40, 8), (40 + i * 40, 26), (theme["icon"],) * 3, -1)
    s[int(0.28 * sh) : int(0.66 * sh), 4:38] = theme["side"]
    if window:  # キャンバスの右に浮かぶ参照ウィンドウ（キャンバスには重ならない）
        cv2.rectangle(s, (sw - 140, 260), (sw - 14, 500), (150, 150, 150), -1)
        cv2.rectangle(s, (sw - 134, 284), (sw - 20, 494), (250, 250, 250), -1)
    return cv2.cvtColor(s, cv2.COLOR_BGR2GRAY)


def gray(img):
    return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for f in OUT.glob("*.png"):
        f.unlink()
    base = drawing(1, 60)
    fill = (300, 300, 500, 400, (120, 180, 220))
    steps = [drawing(1, 10), drawing(1, 25), drawing(1, 45), drawing(1, 70), drawing(1, 70, fill), drawing(1, 90, fill)]
    scales = [0.8, 0.85, 0.8, 0.78, 0.84, 0.82]

    screens = {
        # 全体画像になるもの
        "landscape": screen(base, 0.8),
        "portrait": screen(drawing(1, 60, w=1200, h=1600), 0.85),
        "square": screen(drawing(1, 60, w=1400, h=1400), 0.85),
        "light": screen(base, 0.8, theme=LIGHT),
        # ならないもの
        "full": screen(base, 1.0),
        "zoomed": screen(base, 1.6),
        "tilt1": screen(base, 0.8, 1.0),
        "bar_overlap": screen(base, 0.85, offset=(0, -40)),
        "ref_window": screen(base, 0.7, window=True),
        # 比較の組
        **{f"step{i}": screen(st, sc) for i, (st, sc) in enumerate(zip(steps, scales))},
        "other": screen(drawing(2, 45), 0.85),
        "filled": screen(drawing(1, 25, (0, 0, 1600, 1200, (90, 140, 200))), 0.8),
        "rot90": screen(np.ascontiguousarray(np.rot90(steps[2])), 0.85),
    }
    pngs = {"png_final": gray(steps[-1]), "png_other": gray(drawing(5, 90))}

    detect_expect = {
        "landscape": True, "portrait": True, "square": True, "light": True,
        "full": False, "zoomed": False, "tilt1": False, "bar_overlap": False, "ref_window": False,
        **{f"step{i}": True for i in range(6)}, "other": True, "filled": True, "rot90": True,
    }
    detect, canvases = {}, {}
    for name, g in screens.items():
        rect, why = detect_canvas_why(g, P)
        if (rect is not None) != detect_expect[name]:
            raise SystemExit(f"detect {name}: got {rect} ({why}), expected {'a rect' if detect_expect[name] else 'none'}")
        detect[name] = {"file": f"{name}.png", "rect": list(rect) if rect else None, "why": why}
        if rect:
            x, y, w, h = rect
            canvases[name] = g[y : y + h, x : x + w]

    pairs = [
        *[(f"step{i}", f"step{i + 1}", False, "linked") for i in range(5)],
        ("step2", "other", False, "unconfirmed"),
        ("step1", "filled", False, "unconfirmed"),
        ("step2", "rot90", False, "linked"),
        ("step5", "png_final", True, "linked"),
        ("step5", "png_other", True, "unconfirmed"),
    ]
    comps = []
    for a, b, to_png, want in pairs:
        bimg = pngs[b] if to_png else canvases[b]
        r = compare(canvases[a], bimg, P, to_png=to_png)
        if r["result"] != want:
            raise SystemExit(f"compare {a}->{b}: got {r}, expected {want}")
        comps.append({"a": a, "b": b, "bIsPng": to_png, **r})

    for name, g in {**screens, **pngs}.items():
        ok, buf = cv2.imencode(".png", g, [cv2.IMWRITE_PNG_COMPRESSION, 9])  # imwrite は日本語のパスで失敗する
        assert ok
        (OUT / f"{name}.png").write_bytes(buf.tobytes())
    expected = {
        "_note": "detect の rect は [x, y, w, h]（画素）で、±2px まで同じとみなす。compare の a・b は detect の名前（キャンバスを切り出して使う）。bIsPng が true の b は PNG そのもの。kept は参考（小数2桁）、比べるのは result と reason",
        "params": "shared/params/whole_canvas.json",
        "detect": detect,
        "compare": comps,
    }
    (OUT / "expected.json").write_text(json.dumps(expected, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
    total = sum(f.stat().st_size for f in OUT.iterdir() if f.is_file())
    print(f"wrote {len(screens) + len(pngs)} images and expected.json to {OUT} ({total / 1e6:.2f} MB)")
    for c in comps:
        print(f"  {c['a']:>6} -> {c['b']:<10} {c['result']:<11} kept={c['kept']} {c['reason'] or ''}")


if __name__ == "__main__":
    main()
