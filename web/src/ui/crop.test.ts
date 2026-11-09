import { describe, expect, it } from "vitest";
import { canvasOf, cropBox } from "./crop";
import type { ManifestWhole } from "../verify/types";

// 【T15b】iPad の WholeCanvasTests.testCropPixelRect / testCropFallsBackToWholeImage と同じ値
describe("cropBox（表示のときの切り抜き）", () => {
  it("割合を画素にし、内側に2画素寄せる", () => {
    expect(cropBox({ x: 0.1, y: 0.1, w: 0.8, h: 0.8 }, 1000, 750)).toEqual({ sx: 102, sy: 77, sw: 796, sh: 596 });
    expect(cropBox({ x: 0.1461, y: 0.1816, w: 0.7065, h: 0.6934 }, 712, 1024, 0)).toEqual({ sx: 104, sy: 186, sw: 503, sh: 710 });
  });

  it("誤差で少しはみ出すのは、画像の端で止める", () => {
    expect(cropBox({ x: -0.002, y: 0.2, w: 0.5, h: 0.805 }, 1000, 1000, 0)).toEqual({ sx: 0, sy: 200, sw: 498, sh: 800 });
  });

  it("使えない四角形なら null（元の画像のまま）", () => {
    expect(cropBox(null, 1024, 768)).toBeNull();
    expect(cropBox(undefined, 1024, 768)).toBeNull();
    expect(cropBox({ x: 0.5, y: 0.5, w: 0.8, h: 0.8 }, 1024, 768)).toBeNull();
    expect(cropBox({ x: 0.1, y: 0.1, w: 0, h: 0.5 }, 1024, 768)).toBeNull();
    expect(cropBox({ x: 0.1, y: 0.1, w: Number.NaN, h: 0.5 }, 1024, 768)).toBeNull();
    expect(cropBox({ x: 0.4, y: 0.4, w: 0.2, h: 0.2 }, 1024, 768)).toBeNull();
    expect(cropBox({ x: 0, y: 0, w: 1, h: 1 }, 1024, 768)).toBeNull();
    expect(cropBox({ x: 0.1, y: 0.1, w: 0.8, h: 0.8 }, 0, 768)).toBeNull();
  });
});

describe("canvasOf（開始画面・終了画面の四角形）", () => {
  const whole: ManifestWhole = {
    shown: true,
    items: [
      { seq: 1, sha256: "a", received: true, canvas: { x: 0.1, y: 0.1, w: 0.8, h: 0.8 } },
      { seq: 5, sha256: "b", received: true, canvas: null },
      { seq: 9, sha256: "c", received: true, canvas: { x: 0.2, y: 0.1, w: 0.6, h: 0.8 } },
    ],
    links: [],
    toPng: null,
  };
  it("同じハッシュの全体画像の四角形を使う", () => {
    expect(canvasOf(whole, "a")).toEqual({ x: 0.1, y: 0.1, w: 0.8, h: 0.8 });
    expect(canvasOf(whole, "c")).toEqual({ x: 0.2, y: 0.1, w: 0.6, h: 0.8 });
  });
  it("見つからない・検出できなかった・全体画像がないときは null", () => {
    expect(canvasOf(whole, "b")).toBeNull();
    expect(canvasOf(whole, "z")).toBeNull();
    expect(canvasOf(whole, null)).toBeNull();
    expect(canvasOf(null, "a")).toBeNull();
  });
});
