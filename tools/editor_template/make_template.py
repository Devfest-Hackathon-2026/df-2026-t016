"""編集画面の判定の見本を作る（【11/6】T05）。

Procreate の上のバーの左側（「Gallery」と4つのボタン）を、実機のスクリーンショットから切り出す。
- 画面を長辺1024px のグレースケールにしてから、`regionPx`（左上からの画素）を切り出す
- 見本の画素のうち、バーの地の色（最頻値）より `brightDelta` 以上明るいものを「明るい画素」（文字とアイコン）、
  地の色から `darkBand` 以内のものを「地の画素」とする
- 判定（端末の EditorScreenDetector と同じ）: 明るい画素のうち `brightTol` 以内に収まる割合が `brightMin` 以上、
  かつ地の画素のうち `darkTol` 以内に収まる割合が `darkMin` 以上なら「編集画面」

使い方:
    python tools/editor_template/make_template.py            # 見本の PNG を作り、実機の画面で判定を確かめる
    python tools/editor_template/make_template.py --swift ios/TraceKit/Sources/TraceKit/EditorTemplate.swift

必要なもの: opencv-python-headless, numpy
"""
import argparse
import base64
import json
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
PARAMS = ROOT / "shared/params/editor_screen.json"
TEMPLATE = ROOT / "shared/vectors/editor/bar_left.png"


def gray_1024(path):
    img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise ValueError(f"読めない画像: {path}")
    h, w = img.shape
    s = 1024 / max(w, h)
    return cv2.resize(img, (round(w * s), round(h * s)), interpolation=cv2.INTER_AREA)


def region(gray, p):
    x, y, w, h = p["regionPx"]
    return gray[y:y + h, x:x + w]


def masks(template, p):
    t = template.astype(int)
    bar = int(np.bincount(t.ravel(), minlength=256).argmax())
    return bar, t >= bar + p["brightDelta"], np.abs(t - bar) <= p["darkBand"]


def judge(gray, template, p):
    _, bright, dark = masks(template, p)
    cur = region(gray, p).astype(int)
    t = template.astype(int)
    b = float(np.mean(np.abs(cur[bright] - t[bright]) <= p["brightTol"]))
    d = float(np.mean(np.abs(cur[dark] - t[dark]) <= p["darkTol"]))
    return b, d, b >= p["brightMin"] and d >= p["darkMin"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--swift", help="見本を Swift のソースに書き出す先")
    args = ap.parse_args()
    p = json.loads(PARAMS.read_text(encoding="utf-8"))
    template = region(gray_1024(ROOT / p["source"]), p)
    TEMPLATE.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(TEMPLATE), template)
    bar, bright, dark = masks(template, p)
    print(f"見本: {TEMPLATE.relative_to(ROOT)}（{template.shape[1]}×{template.shape[0]}）、地の色 {bar}、明るい画素 {int(bright.sum())}、地の画素 {int(dark.sum())}")

    real = ROOT / "shared/vectors/whole_canvas/real"
    expected_path = real / "expected.json"
    expected = json.loads(expected_path.read_text(encoding="utf-8")) if expected_path.exists() else {}
    mismatches = 0
    for path in sorted(real.glob("*.jpg")):
        b, d, ok = judge(gray_1024(path), template, p)
        want = expected.get(path.name, {}).get("editor")
        mark = "" if want is None else ("一致" if want == ok else "不一致")
        mismatches += mark == "不一致"
        print(f"  {path.name:40s} 文字・アイコン {b:.2f} 地 {d:.2f} → {'編集画面' if ok else 'ちがう':5s} {mark}")
    print(f"期待（expected.json の editor）との不一致: {mismatches}件")

    if args.swift:
        out = Path(args.swift)
        data = base64.b64encode(template.tobytes()).decode()
        # 文字列を + でつなぐと Swift の型の検査が重くなるので、複数行の文字列にして改行を読み飛ばす
        body = "\n".join(data[i:i + 100] for i in range(0, len(data), 100))
        out.write_text(f'''// このファイルは tools/editor_template/make_template.py が作る。手で直さない。
// 見本の元: {p["source"]}

import Foundation

/// 編集画面の判定の見本（Procreate の上のバーの左側。長辺1024px のときの画素、グレースケール）。
public enum EditorTemplate {{
    public static let width = {template.shape[1]}
    public static let height = {template.shape[0]}
    public static let pixels: [UInt8] = Array(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!)

    private static let base64 = """
{body}
"""
}}
''', encoding="utf-8")
        print(f"Swift の見本: {out}")


if __name__ == "__main__":
    main()
