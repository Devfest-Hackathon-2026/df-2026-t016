// 【T15b】全体画像を表示するときだけ、キャンバスの部分を切り抜く。
// 署名した画像は変えない（ハッシュの確認・ダウンロード・「元の画面」は元の画像のまま）。
// 計算は iPad の CanvasCrop.pixelRect（ios/TraceKit/Sources/TraceKit/WholeCanvas.swift）と同じ。

import type { ManifestWhole, NormManifest } from "../verify/types";

export type Canvas = { x: number; y: number; w: number; h: number };
export type Box = { sx: number; sy: number; sw: number; sh: number };

/**
 * 割合の四角形を、width×height の画像の画素の範囲にする。内側に inset 画素ずつ寄せる（端に背景が残るのを防ぐ）。
 * 四角形が無い・範囲の外・小さすぎる・ほぼ画面全体なら null（元の画像をそのまま出す）。
 */
export function cropBox(c: Canvas | null | undefined, width: number, height: number, inset = 2): Box | null {
  if (!c || !(width > 0) || !(height > 0)) return null;
  const { x, y, w, h } = c;
  if (![x, y, w, h].every(Number.isFinite)) return null;
  const tol = 0.01;
  if (x < -tol || y < -tol || !(w > 0) || !(h > 0) || x + w > 1 + tol || y + h > 1 + tol) return null;
  // 検出の下限（画面の15%）より小さいものは使わない。ほぼ全体なら切り抜く意味がない
  if (w * h < 0.1 || (w >= 0.98 && h >= 0.98)) return null;
  const clamp = (v: number, max: number) => Math.min(Math.max(Math.round(v), 0), max);
  let x0 = clamp(x * width, width);
  let y0 = clamp(y * height, height);
  let x1 = clamp((x + w) * width, width);
  let y1 = clamp((y + h) * height, height);
  if (x1 - x0 > inset * 2 + 16) {
    x0 += inset;
    x1 -= inset;
  }
  if (y1 - y0 > inset * 2 + 16) {
    y0 += inset;
    y1 -= inset;
  }
  if (x1 <= x0 || y1 <= y0) return null;
  return { sx: x0, sy: y0, sw: x1 - x0, sh: y1 - y0 };
}

/** その画像（sha256）のキャンバスの四角形。開始画面・終了画面は、同じハッシュの全体画像のものを使う（【11/6】）。 */
export function canvasOf(whole: ManifestWhole | null | undefined, sha: string | null | undefined): Canvas | null {
  if (!whole || !sha) return null;
  for (let i = whole.items.length - 1; i >= 0; i--) {
    const it = whole.items[i];
    if (it.sha256 === sha && it.canvas) return it.canvas;
  }
  return null;
}

export function startEndCanvas(m: NormManifest): { start: Canvas | null; end: Canvas | null } {
  return { start: canvasOf(m.whole, m.images.start), end: canvasOf(m.whole, m.images.end) };
}

// ---------------------------------------------------------------- 画面（ブラウザだけ）

const cache = new Map<string, string | null>();

async function cropToUrl(url: string, c: Canvas): Promise<string | null> {
  try {
    const blob = await (await fetch(url)).blob();
    const bmp = await createImageBitmap(blob);
    const box = cropBox(c, bmp.width, bmp.height);
    if (!box) return null;
    const cv = document.createElement("canvas");
    cv.width = box.sw;
    cv.height = box.sh;
    cv.getContext("2d")!.drawImage(bmp, box.sx, box.sy, box.sw, box.sh, 0, 0, box.sw, box.sh);
    bmp.close();
    const out = await new Promise<Blob | null>((r) => cv.toBlob(r, "image/jpeg", 0.92));
    return out ? URL.createObjectURL(out) : null;
  } catch {
    return null;
  }
}

/**
 * 画像の要素。四角形があれば、切り抜いた表示用の画像に差し替える（切り抜けなければ元の画像のまま）。
 * 2回目からは切り抜いたものをすぐ使う（全体画像を確かめ終えて画面を出し直すとき）。
 */
export function artImage(url: string, c: Canvas | null, alt: string, cls = ""): HTMLImageElement {
  const img = document.createElement("img");
  img.alt = alt;
  if (cls) img.className = cls;
  if (!c) {
    img.src = url;
    return img;
  }
  const key = `${url}|${c.x},${c.y},${c.w},${c.h}`;
  const hit = cache.get(key);
  if (hit !== undefined) {
    img.src = hit ?? url;
    if (hit) img.classList.add("cropped");
    return img;
  }
  img.classList.add("cropping");
  img.src = url;
  void cropToUrl(url, c).then((u) => {
    cache.set(key, u);
    if (u) {
      img.src = u;
      img.classList.add("cropped");
    }
    img.classList.remove("cropping");
  });
  return img;
}
