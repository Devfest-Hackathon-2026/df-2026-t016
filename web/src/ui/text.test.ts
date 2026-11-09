// 検証ページの文言が公開仕様と一致することを確かめる。
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { TEXT } from "./text";

const spec = readFileSync(fileURLToPath(new URL("../../../docs/verification.md", import.meta.url)), "utf-8");

function bullets(heading: string): string[] {
  const start = spec.indexOf(heading);
  const rest = spec.slice(start).split("\n").slice(1);
  const out: string[] = [];
  for (const line of rest) {
    if (line.startsWith("- ")) out.push(line.slice(2).trim());
    else if (out.length > 0 && line.trim() !== "") break;
  }
  return out;
}

function allStrings(v: unknown): string[] {
  if (typeof v === "string") return [v];
  if (typeof v === "function") return [];
  if (Array.isArray(v)) return v.flatMap(allStrings);
  if (v && typeof v === "object") return Object.values(v).flatMap(allStrings);
  return [];
}

describe("text.ts", () => {
  it("確認できないことは公開仕様と同じ", () => {
    expect([...TEXT.cannot]).toEqual(bullets("## 確認できないこと"));
  });
  it("記録が2回以上のときに足す1行は公開仕様と同じ（T14）", () => {
    expect(spec).toContain(`記録が2回以上のときは「${TEXT.cannotBetween}」も示す`);
  });
  it("初版では見分けられない例は公開仕様と同じ", () => {
    expect([...TEXT.cannotTell]).toEqual(bullets("## 初版では見分けられない例"));
  });
  it("見出しと主文は公開仕様と同じ（【11/8】一行の説明はやめ、タイトルと制作者をラベル付きで出す）", () => {
    expect(spec).toContain(`**${TEXT.eyebrow}**の見出しの下に「${TEXT.titleLabel}」「${TEXT.artistLabel}」をラベル付きで出す`);
    expect(spec).toContain(`**${TEXT.declarationLabel}**`);
    expect(spec).toContain(TEXT.declarationNote);
    expect(spec).toContain(TEXT.receptionNoteShort);
  });
  it("全体画像の説明は公開仕様と同じ", () => {
    expect(spec).toContain(TEXT.whole.about);
    expect(spec).toContain(TEXT.whole.limits);
    expect(spec).toContain(`「${TEXT.whole.hidden.replace(/。$/, "")}」`);
  });
  it("「改ざん」「不正」「描いた時間」「✓」を使わない", () => {
    for (const s of allStrings(TEXT)) {
      expect(s).not.toMatch(/改ざん|不正|描いた時間|✓/);
    }
  });
});
