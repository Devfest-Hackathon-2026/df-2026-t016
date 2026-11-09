// 画面を組み立てる（設計書10章の順番）。文言は text.ts から取る。
// 【T15】作品 → 要点 → 制作の流れ → 確認の結果 → 作者の申告 → この記録について（開閉） → 注意点・ダウンロード

import { b64ToBytes, sha256Hex } from "../verify/crypto";
import { bundleSessions } from "../verify/verify";
import type { Bundle, BundleChunk, Gap, ImageState, NormManifest, VerifyResult } from "../verify/types";
import { artImage, startEndCanvas, type Canvas } from "./crop";
import { TEXT } from "./text";

export type RenderContext = {
  bundle: Bundle;
  manifest: NormManifest;
  result: VerifyResult;
  fileUrl: (name: string | null) => string | null;
  isFixture: boolean;
};

type Attrs = Record<string, string>;
type Child = Node | string | null | undefined | false;

function el<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Attrs = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    e.append(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return e;
}

function section(id: string, title: string, ...children: Child[]) {
  return el("section", { id, class: "block" }, el("h2", {}, title), ...children);
}

/** 【11/9】見出しの横の「ⓘ」。押すと「用語と説明」の該当する項目を開く */
function info(term: string, back: string, label: string): HTMLElement {
  return el("a", { class: "info", href: `#${term}`, "data-back": back, "aria-label": `${label}の${TEXT.terms.info}`, title: TEXT.terms.info }, "ⓘ");
}

/** 見出しに「ⓘ」を付けた節 */
function sectionWithInfo(id: string, title: string, term: string, ...children: Child[]) {
  return el("section", { id, class: "block" }, el("h2", { class: "with-info" }, title, info(term, id, title)), ...children);
}

function formatReceptionDuration(ms: number | null): string {
  if (ms === null || !Number.isFinite(ms)) return "—";
  const seconds = Math.max(0, Math.round(ms / 1000));
  return `約${Math.floor(seconds / 60)}分${seconds % 60}秒`;
}

function receiptTimes(chunks: BundleChunk[]): number[] {
  const dec = new TextDecoder();
  return chunks.map((c) => {
    try {
      return Date.parse(JSON.parse(dec.decode(b64ToBytes(c.receipt))).receivedAt);
    } catch {
      return NaN;
    }
  });
}

/** 受信区間の長さ（ミリ秒）。記録が複数なら、記録ごとの長さの合計（記録と記録の間は入れない）。 */
export function receivedSpanMs(m: NormManifest): number | null {
  const spans = m.sessions
    .filter((x) => x.received.first && x.received.last)
    .map((x) => Date.parse(x.received.last!) - Date.parse(x.received.first!));
  return spans.length === 0 ? null : spans.reduce((a, b) => a + b, 0);
}

const dayFmt = new Intl.DateTimeFormat("ja-JP", { month: "numeric", day: "numeric" });
const yearDayFmt = new Intl.DateTimeFormat("ja-JP", { year: "numeric", month: "numeric", day: "numeric" });
const dateTime = new Intl.DateTimeFormat("ja-JP", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
const timeFmt = new Intl.DateTimeFormat("ja-JP", { hour: "2-digit", minute: "2-digit" });
const timeWithSeconds = new Intl.DateTimeFormat("ja-JP", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const dayLabelFmt = new Intl.DateTimeFormat("ja-JP", { month: "long", day: "numeric", weekday: "short" });

/** 【11/8】経過時間を「12分」「1時間5分」「2日3時間」のように。1分未満は null */
export function formatElapsed(ms: number): string | null {
  const min = Math.round(ms / 60000);
  if (min < 1) return null;
  if (min < 60) return `${min}分`;
  const h = Math.floor(min / 60);
  const m = min % 60;
  if (h < 24) return m ? `${h}時間${m}分` : `${h}時間`;
  const d = Math.floor(h / 24);
  const hh = h % 24;
  return hh ? `${d}日${hh}時間` : `${d}日`;
}

/** 日付を分ける鍵（その端末の時刻での年月日） */
function dayKey(t: number): string {
  const d = new Date(t);
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

/** 【T15】記録した日（受信の最初の日〜最後の日）。同じ日なら1つ。 */
export function recordDays(m: NormManifest): string | null {
  const firsts = m.sessions.map((x) => Date.parse(x.received.first ?? "")).filter(Number.isFinite);
  const lasts = m.sessions.map((x) => Date.parse(x.received.last ?? "")).filter(Number.isFinite);
  if (firsts.length === 0) return null;
  const a = new Date(Math.min(...firsts));
  const b = new Date(Math.max(...lasts, ...firsts));
  if (dayFmt.format(a) === dayFmt.format(b) && a.getFullYear() === b.getFullYear()) return yearDayFmt.format(a);
  return `${yearDayFmt.format(a)} – ${a.getFullYear() === b.getFullYear() ? dayFmt.format(b) : yearDayFmt.format(b)}`;
}

/** 【T15】全体画像のつながりの数（PNG へのつながりを含む） */
function wholeCounts(r: VerifyResult): { linked: number; unconfirmed: number } | null {
  if (!r.whole) return null;
  const all = [...r.whole.links, ...(r.whole.toPng ? [r.whole.toPng] : [])];
  const linked = all.filter((l) => l.result === "linked").length;
  return { linked, unconfirmed: all.length - linked };
}

// ---------------------------------------------------------------- 上の帯と作品

function topBar(isFixture: boolean): HTMLElement {
  return el(
    "header",
    { class: "top" },
    el("p", { class: "brand" }, el("img", { src: "/brand.png", alt: "", width: "30", height: "30" }), TEXT.brand),
    isFixture ? el("p", { class: "fixture" }, TEXT.fixtureBanner) : null,
  );
}

/** 作品の画像: 提出画像（PNG の縮小）。無ければ終了画面か最後の全体画像を、絵の部分だけにして出す */
function workImage(ctx: RenderContext): HTMLElement | null {
  const f = ctx.bundle.files;
  const m = ctx.manifest;
  const png = ctx.fileUrl(f.png);
  if (png) return el("img", { src: png, alt: m.title });
  const end = ctx.fileUrl(f.end);
  if (end && ctx.result.images.end === "ok") return artImage(end, startEndCanvas(m).end, m.title);
  const names = f.whole ?? [];
  const items = ctx.result.whole?.items ?? [];
  for (let i = items.length - 1; i >= 0; i--) {
    const url = ctx.fileUrl(names[i] ?? null);
    if (url && items[i].status === "ok") return artImage(url, m.whole?.items[i]?.canvas ?? null, m.title);
  }
  return null;
}

function workPart(ctx: RenderContext): HTMLElement {
  const m = ctx.manifest;
  const img = workImage(ctx);
  // 【11/8】タイトルと制作者をラベル付きで出す（一行の説明はやめた）
  return el(
    "section",
    { class: "work" },
    img ? el("figure", { class: "work-art" }, img) : null,
    el(
      "div",
      { class: "work-meta" },
      el("p", { class: "eyebrow" }, TEXT.eyebrow),
      el(
        "dl",
        { class: "work-info" },
        el("div", {}, el("dt", {}, TEXT.titleLabel), el("dd", {}, el("h1", {}, m.title))),
        el("div", {}, el("dt", {}, TEXT.artistLabel), el("dd", { class: "artist" }, m.displayName)),
      ),
    ),
  );
}

function factsPart(ctx: RenderContext): HTMLElement {
  const F = TEXT.facts;
  const { manifest: m, result: r } = ctx;
  const fact = (label: string, value: string, tone = "") =>
    el("div", { class: `fact${tone ? ` tone-${tone}` : ""}` }, el("dt", {}, label), el("dd", {}, value));
  const match = r.match.result === "match" ? F.match : r.match.result === "mismatch" ? F.mismatch : F.unverified;
  const days = recordDays(m);
  const issue = r.integrity.status !== "ok";
  return el(
    "section",
    { class: "facts", "aria-label": TEXT.eyebrow },
    issue ? el("p", { class: "issue" }, el("span", { class: "dot dot-warn", "aria-hidden": "true" }), F.integrityIssue, el("a", { href: "#checks" }, F.toChecks)) : null,
    el(
      "dl",
      {},
      fact(F.records, F.recordsValue(m.sessions.length)),
      days ? fact(F.days, days) : null,
      fact(F.whole, r.whole ? F.wholeValue(r.whole.items.length) : F.wholeNone),
      fact(F.png, match, r.match.result === "mismatch" ? "warn" : ""),
    ),
  );
}

// ---------------------------------------------------------------- 制作の流れ

function linkText(l: { result: "linked" | "unconfirmed"; kept: number | null; reason: string | null }): HTMLElement {
  const W = TEXT.whole;
  // 【11/8】つながりを確認できたときは「◯%の変更」と短く。確認できないときは理由を別の行に
  if (l.result === "linked") return el("p", { class: "link tone-ok", title: W.changedTitle }, W.changed(l.kept));
  return el("p", { class: "link tone-warn" }, W.unconfirmed, l.reason ? el("span", { class: "link-reason" }, l.reason) : null);
}

/** 【11/8】隣どうしの間: 上に経過時間、下に「◯%の変更」 */
function connector(elapsedMs: number | null, link: Child, hasAiNote = false): HTMLElement {
  const W = TEXT.whole;
  const e = elapsedMs === null ? null : formatElapsed(elapsedMs);
  return el(
    "div",
    { class: "connector" },
    elapsedMs === null ? el("p", { class: "elapsed" }, "\u00a0") : el("p", { class: "elapsed" }, e ? W.elapsed(e) : W.elapsedUnder),
    el("div", { class: "connector-line", "aria-hidden": "true" }),
    link,
    hasAiNote ? el("a", { class: "ai-marker", href: "#explanation" }, TEXT.explanation.marker) : null,
  );
}

/** 【11/8】全体画像の時刻: その画像を含むチャンクを運営が受け取った時刻（記録の番号と seq で引く）。読めなければ null */
function wholeTimes(ctx: RenderContext): (number | null)[] {
  const dec = new TextDecoder();
  const bySession = bundleSessions(ctx.bundle).map((x) => {
    const at = new Map<number, number>();
    for (const c of x.chunks) {
      try {
        const r = JSON.parse(dec.decode(b64ToBytes(c.receipt)));
        const t = Date.parse(r.receivedAt);
        if (Number.isFinite(t)) at.set(r.seq, t);
      } catch {
        /* 読めない受領証は飛ばす */
      }
    }
    return at;
  });
  return (ctx.result.whole?.items ?? []).map((it) => bySession[it.session ?? 0]?.get(it.seq) ?? null);
}

/** 画像1枚。押すと元の画面（署名した画像そのもの）を開く */
function shot(url: string | null, canvas: Canvas | null, alt: string, caption: Child, empty: string): HTMLElement {
  const body = url
    ? el("a", { href: url, target: "_blank", rel: "noopener", title: TEXT.whole.open }, canvas ? artImage(url, canvas, alt) : el("img", { src: url, alt, loading: "lazy" }))
    : el("div", { class: "shot-empty" }, empty);
  return el("figure", { class: "shot" }, body, el("figcaption", {}, caption));
}

function processPart(ctx: RenderContext, times: (number | null)[]): HTMLElement {
  const W = TEXT.whole;
  const w = ctx.result.whole;
  const m = ctx.manifest;
  const f = ctx.bundle.files;

  if (!w) {
    // 全体画像が無い記録: 開始画面 → 終了画面 → 提出画像
    const I = TEXT.images;
    const crop = startEndCanvas(m);
    const empty = (s: ImageState, label: string) => (s === "none" ? I.none : s === "missing" ? I.missing : s === "mismatch" ? I.mismatch : label);
    const url = (name: string | null, s: ImageState) => (s === "ok" ? ctx.fileUrl(name) : null);
    const { start, end } = ctx.result.images;
    return section(
      "process",
      TEXT.sections.process,
      el(
        "div",
        { class: "strip" },
        shot(url(f.start, start), crop.start, I.start, I.start, empty(start, I.start)),
        el("div", { class: "connector connector-arrow", "aria-hidden": "true" }),
        shot(url(f.end, end), crop.end, I.end, I.end, empty(end, I.end)),
        el("div", { class: "connector connector-arrow", "aria-hidden": "true" }),
        shot(ctx.fileUrl(f.png), null, W.png, W.png, I.none),
      ),
      el("p", { class: "note whole-note" }, W.none),
    );
  }

  const multi = m.sessions.length > 1;
  const sessionOf = (i: number) => w.items[i].session ?? 0;
  const linkTo = (i: number) => w.links.find((l) => l.to === i);
  // 【11/8】画像の時刻（分まで）と、前の画像からの経過時間
  const days = new Set(times.filter((t): t is number => t !== null).map(dayKey));
  const clock = (i: number) => {
    const t = times[i];
    if (t === null || t === undefined) return W.timeUnknown;
    return days.size > 1 ? dateTime.format(new Date(t)) : timeFmt.format(new Date(t));
  };
  const elapsed = (i: number) => {
    const a = times[i - 1];
    const b = times[i];
    return a === null || a === undefined || b === null || b === undefined ? null : Math.max(0, b - a);
  };

  if (!w.shown) {
    // 載せない設定: 画像は出さず、つながりの結果だけ
    const when = (i: number) => (multi ? `${sessionOf(i) + 1}回目・${clock(i)}` : clock(i));
    const rows: HTMLElement[] = w.links.map((l) =>
      el("li", {}, `${multi && sessionOf(l.from) !== sessionOf(l.to) ? `${W.between}: ` : ""}${W.item(l.from)}（${when(l.from)}）→ ${W.item(l.to)}（${when(l.to)}）`, linkText(l)),
    );
    if (w.toPng) rows.push(el("li", {}, `${W.item(w.items.length - 1)} → ${W.png}`, linkText(w.toPng)));
    return sectionWithInfo("process", TEXT.sections.process, "term-whole", el("p", { class: "quiet" }, W.hidden), el("ul", { class: "link-list" }, ...rows));
  }

  // 記録または日付が変わるたびに行を分け、行ごとに横にスクロールする。
  const names = f.whole ?? [];
  const canvases = m.whole?.items ?? [];
  const aiLinks = ctx.bundle.explanation?.text.trim() ? ctx.bundle.explanation.links : undefined;
  const rows = el("div", { class: "day-rows" });
  const strips: HTMLElement[] = [];
  let currentDay: string | null = null;
  const newRow = (t: number | null) => {
    const label = t === null ? W.timeUnknown : dayLabelFmt.format(new Date(t));
    const strip = el("div", { class: "strip", role: "list" });
    strips.push(strip);
    rows.append(el("div", { class: "day-row" }, el("p", { class: "day-label" }, label), strip));
  };
  w.items.forEach((it, i) => {
    const t = times[i] ?? null;
    const session = sessionOf(i);
    const startsSession = i === 0 || session !== sessionOf(i - 1);
    const key = t === null ? (startsSession ? null : currentDay) : dayKey(t);
    if (startsSession || key !== currentDay) {
      newRow(t);
      currentDay = key;
    }
    const s = strips[strips.length - 1];
    const link = i > 0 ? linkTo(i) : undefined;
    if (multi && startsSession) {
      // 【T14】記録の切れ目に「◯回目の記録」。記録をまたぐつながりは、その下に出す
      const from = m.sessions[session]?.received.first;
      const e = i > 0 ? elapsed(i) : null;
      const eText = e === null ? null : formatElapsed(e);
      s.append(
        el(
          "div",
          { class: "session-mark", role: "listitem" },
          el("strong", {}, TEXT.reception.sessionTitleNoTime(session)),
          from ? el("span", { class: "when" }, timeFmt.format(new Date(from))) : null,
          link ? el("span", { class: "between" }, W.between) : null,
          link && e !== null ? el("span", { class: "elapsed" }, eText ? W.elapsed(eText) : W.elapsedUnder) : null,
          link ? linkText(link) : null,
        ),
      );
    } else if (link) {
      const hasAiNote = Array.isArray(aiLinks) && aiLinks.some((pair) => pair?.from === link.from && pair?.to === link.to);
      s.append(connector(elapsed(i), linkText(link), hasAiNote));
    }
    const state = it.status === "none" ? W.notReceived : it.status === "mismatch" ? W.mismatch : it.status === "missing" ? W.missing : it.status === "pending" ? W.pending : null;
    const url = it.status === "ok" ? ctx.fileUrl(names[i] ?? null) : null;
    const caption = el("span", {}, t === null ? W.timeUnknown : timeFmt.format(new Date(t)), state ? el("span", { class: "warn-text" }, ` — ${state}`) : null);
    const fig = shot(url, canvases[i]?.canvas ?? null, `${W.item(i)}（${clock(i)}）`, caption, state ?? "");
    fig.setAttribute("role", "listitem");
    s.append(fig);
  });
  if (w.toPng && strips.length > 0) {
    const s = strips[strips.length - 1];
    s.append(connector(null, linkText(w.toPng)));
    const png = shot(ctx.fileUrl(f.png), null, W.png, W.png, W.png);
    png.classList.add("shot-final");
    s.append(png);
  }
  return sectionWithInfo("process", TEXT.sections.process, "term-whole", rows);
}

// ---------------------------------------------------------------- 確認の結果

type Tone = "ok" | "warn" | "plain";

function checkRow(id: string, label: string, tone: Tone, value: string, line: Child, details: Child[] = []): HTMLElement {
  const more = details.filter(Boolean);
  return el(
    "div",
    { class: "check", id },
    el(
      "div",
      { class: "check-head" },
      el("span", { class: `dot dot-${tone}`, "aria-hidden": "true" }),
      el("span", { class: "check-label" }, label),
      el("strong", { class: `check-value tone-${tone}` }, value),
    ),
    line ? el("div", { class: "check-line" }, line) : null,
    more.length > 0 ? el("details", {}, el("summary", {}, TEXT.checks.more), el("div", { class: "check-more" }, ...more)) : null,
  );
}

type BarInput = { chunks: BundleChunk[]; first: string | null; last: string | null; active: boolean[]; gaps: Gap[]; snapshots: number[] };

function receptionScale(first: number, last: number, snapshots: number[], pct: (t: number) => string): HTMLElement {
  const R = TEXT.reception;
  const formatter = dayKey(first) !== dayKey(last) ? dateTime : last - first < 120_000 ? timeWithSeconds : timeFmt;
  const label = (t: number, cls: string, title: string) =>
    el("time", { class: `bar-time ${cls}`, datetime: new Date(t).toISOString(), title }, formatter.format(t));
  const points = [...new Set(snapshots.filter((t) => t >= first && t <= last))].sort((a, b) => a - b);
  const spacedLabels = (fraction: number) => {
    const gap = (last - first) * fraction;
    // 両端の時刻は帯の内側にそろうので、途中のラベルより広めに余白を取る。
    let next = first + gap * 1.5;
    const used = new Set([formatter.format(first), formatter.format(last)]);
    return new Set(points.filter((t) => {
      if (t < next || t > last - gap * 1.5) return false;
      const clock = formatter.format(t);
      if (used.has(clock)) return false;
      used.add(clock);
      next = t + gap;
      return true;
    }));
  };
  const compact = spacedLabels(0.23);
  const wide = spacedLabels(0.13);
  const scale = el("div", { class: "bar-scale", role: "group", "aria-label": R.barTimes }, label(first, "bar-time-start", R.barStart));
  for (const t of points) {
    const title = `${R.barSnapshot} ${dateTime.format(t)}`;
    const tick = el("span", { class: "bar-tick", title, "aria-hidden": "true" });
    tick.style.left = pct(t);
    scale.append(tick);
    const classes = [compact.has(t) ? "bar-time-compact" : "", wide.has(t) ? "bar-time-wide" : ""].filter(Boolean);
    if (classes.length === 0) continue;
    const time = label(t, classes.join(" "), title);
    time.style.left = pct(t);
    scale.append(time);
  }
  scale.append(label(last, "bar-time-end", R.barEnd));
  return scale;
}

function receptionBar(x: BarInput): HTMLElement {
  const times = receiptTimes(x.chunks);
  const first = Date.parse(x.first ?? "");
  const last = Date.parse(x.last ?? "");
  const bar = el("div", { class: "bar", role: "img", "aria-label": TEXT.reception.barReceived });
  if (!Number.isFinite(first) || !Number.isFinite(last) || last <= first) return bar;
  const pct = (t: number) => `${(((t - first) / (last - first)) * 100).toFixed(3)}%`;
  const seg = (cls: string, a: number, b: number) => {
    const d = el("div", { class: cls });
    d.style.left = pct(a);
    d.style.width = `${(((b - a) / (last - first)) * 100).toFixed(3)}%`;
    bar.append(d);
  };
  // 画面に変化があった区間（隣どうしのチャンクはまとめる）
  const act = x.active;
  let runStart: number | null = null;
  for (let i = 0; i < times.length; i++) {
    const from = i === 0 ? first : times[i - 1];
    if (act[i] && runStart === null) runStart = from;
    if ((!act[i] || i === times.length - 1) && runStart !== null) {
      seg("bar-active", runStart, act[i] ? times[i] : from);
      runStart = null;
    }
  }
  // 受信の空き
  const seqIndex = new Map<number, number>();
  const dec = new TextDecoder();
  x.chunks.forEach((c, i) => {
    try {
      seqIndex.set(JSON.parse(dec.decode(b64ToBytes(c.receipt))).seq, i);
    } catch {
      /* 読めない受領証は飛ばす */
    }
  });
  for (const g of x.gaps) {
    const i = seqIndex.get(g.after);
    if (i !== undefined && i + 1 < times.length) seg("bar-gap", times[i], times[i + 1]);
  }
  return el("div", { class: "reception-timeline" }, bar, receptionScale(first, last, x.snapshots, pct));
}

function legend(): HTMLElement {
  const S = TEXT.short;
  return el(
    "ul",
    { class: "legend" },
    el("li", {}, el("span", { class: "sw sw-received" }), S.barReceived),
    el("li", {}, el("span", { class: "sw sw-gap" }), S.barGap),
    el("li", {}, el("span", { class: "sw sw-active" }), S.barActive),
  );
}

function editorPart(ctx: RenderContext): HTMLElement | null {
  const S = TEXT.short;
  const { editorMs, activeMs, largeChangeMs } = ctx.result.reception;
  if (editorMs === null && activeMs === null) return null;
  const row = (label: string, ms: number | null) =>
    el("p", { class: "span" }, el("span", { class: "span-label" }, label), el("strong", {}, formatReceptionDuration(ms)));
  const rows: HTMLElement[] = [];
  if (editorMs !== null && activeMs !== null && largeChangeMs !== null) {
    const remaining = editorMs - activeMs - largeChangeMs;
    rows.push(
      row(S.largeChange, largeChangeMs),
      row(S.active, activeMs),
      row(S.remainingChange, remaining >= 0 ? remaining : null),
    );
  } else {
    if (editorMs !== null) rows.push(row(S.editor, editorMs));
    if (activeMs !== null) rows.push(row(S.active, activeMs));
  }
  return el(
    "div",
    { class: "editor-time detail-head" },
    el("div", {}, ...rows),
    info("term-editor", "check-reception", TEXT.reception.editorTermTitle),
  );
}

/** 【11/9】受信状況の「詳しく」: 記録ごとに、終わり方・録画が続いた時間・帯・受信の空きだけ。説明は「用語と説明」 */
function receptionDetails(ctx: RenderContext, imageTimes: (number | null)[]): Child[] {
  const R = TEXT.reception;
  const S = TEXT.short;
  const C = TEXT.checks;
  const m = ctx.manifest;
  const multi = m.sessions.length > 1;
  const chunksOf = bundleSessions(ctx.bundle).map((x) => x.chunks);
  const snapshotsBySession = m.sessions.map((): number[] => []);
  const whole = ctx.result.whole;
  if (whole?.shown) {
    whole.items.forEach((it, i) => {
      const time = imageTimes[i];
      if (time != null && (it.status === "ok" || it.status === "pending")) {
        snapshotsBySession[it.session ?? 0]?.push(time);
      }
    });
  }
  const perSession = ctx.result.reception.sessions ?? [];
  const blocks = m.sessions.map((ms, i) => {
    const from = ms.received.first ? dateTime.format(new Date(ms.received.first)) : null;
    const span = formatReceptionDuration(Date.parse(ms.received.last ?? "") - Date.parse(ms.received.first ?? ""));
    const gaps = ms.received.gaps;
    const active = multi ? (perSession[i]?.activeChunks ?? []) : ctx.result.reception.activeChunks;
    return el(
      "div",
      { class: "session" },
      multi ? el("h3", {}, from ? `${i + 1}回目の記録　${from}` : R.sessionTitleNoTime(i)) : null,
      el("p", { class: "span" }, el("span", { class: "span-label" }, S.span), el("strong", {}, span), ms.status === "completed" ? null : el("span", { class: "warn-text" }, C.aborted)),
      receptionBar({ chunks: chunksOf[i] ?? [], first: ms.received.first, last: ms.received.last, active, gaps, snapshots: snapshotsBySession[i] }),
      gaps.length > 0
        ? el("div", { class: "gaps-block" }, el("p", { class: "span-label" }, `${S.gaps} ${gaps.length}か所`), el("ul", { class: "gaps" }, ...gaps.map((g) => el("li", {}, S.gapItem(g.after, formatReceptionDuration(g.sec * 1000))))))
        : null,
    );
  });
  return [el("div", { class: "detail-head" }, legend(), info("term-reception", "check-reception", TEXT.checks.reception)), ...blocks, editorPart(ctx)];
}

function pngDrop(ctx: RenderContext): HTMLElement {
  const I = TEXT.images;
  const out = el("p", { class: "drop-result", "aria-live": "polite" });
  const input = el("input", { type: "file", accept: "image/png", id: "png-input", class: "visually-hidden" });
  const zone = el("div", { class: "drop", tabindex: "0" }, el("p", {}, TEXT.short.drop), el("label", { for: "png-input", class: "button button-quiet" }, I.dropButton), input);
  const check = async (f: File) => {
    const want = ctx.manifest.png?.sha256;
    if (!want) {
      out.textContent = I.dropNoPng;
      return;
    }
    const got = await sha256Hex(new Uint8Array(await f.arrayBuffer()));
    out.textContent = got === want ? I.dropSame : I.dropDiff;
    out.className = `drop-result tone-${got === want ? "ok" : "warn"}`;
  };
  input.addEventListener("change", () => input.files?.[0] && check(input.files[0]));
  zone.addEventListener("dragover", (e) => {
    e.preventDefault();
    zone.classList.add("over");
  });
  zone.addEventListener("dragleave", () => zone.classList.remove("over"));
  zone.addEventListener("drop", (e) => {
    e.preventDefault();
    zone.classList.remove("over");
    const f = e.dataTransfer?.files?.[0];
    if (f) void check(f);
  });
  return el("div", { class: "drop-wrap" }, el("h3", {}, I.dropTitle), zone, out);
}

function imageFigure(label: string, url: string | null, state: ImageState | "plain", canvas: Canvas | null = null): HTMLElement {
  const I = TEXT.images;
  const caption = state === "none" ? I.none : state === "missing" ? I.missing : state === "mismatch" ? I.mismatch : null;
  const shown = url && state !== "none" && state !== "missing" ? url : null;
  return shot(shown, canvas, label, el("span", {}, label, caption && shown ? el("span", { class: "warn-text" }, ` — ${caption}`) : null), caption ?? "");
}

function imagesDetails(ctx: RenderContext): Child[] {
  const I = TEXT.images;
  const { match, images } = ctx.result;
  const f = ctx.bundle.files;
  const crop = startEndCanvas(ctx.manifest);
  return [
    el(
      "div",
      { class: "shots" },
      imageFigure(I.start, ctx.fileUrl(f.start), images.start, crop.start),
      imageFigure(I.end, ctx.fileUrl(f.end), images.end, crop.end),
      imageFigure(I.png, ctx.fileUrl(f.png), ctx.manifest.png ? "plain" : "none"),
    ),
    match.score !== null ? el("p", { class: "span" }, el("span", { class: "span-label" }, TEXT.short.score(match.score))) : null,
    pngDrop(ctx),
  ];
}

function checksPart(ctx: RenderContext, imageTimes: (number | null)[]): HTMLElement {
  const C = TEXT.checks;
  const I = TEXT.integrity;
  const { manifest: m, result: r } = ctx;

  // 記録の整合性
  const { status, problems } = r.integrity;
  const problemList = problems.length > 0 ? el("ul", { class: "problems" }, ...problems.map((p) => el("li", {}, `${I.where(p.seq, p.session)}: ${p.detail}`))) : null;
  const integrity = checkRow("check-integrity", C.integrity, status === "ok" ? "ok" : "warn", I.statusName[status], status === "ok" ? null : I[status], [problemList]);

  // 受信状況
  const n = m.sessions.length;
  const aborted = m.sessions.filter((x) => x.status === "aborted").length;
  const gaps = m.sessions.reduce((a, x) => a + x.received.gaps.length, 0);
  const state = n > 1 ? (aborted === 0 ? C.allCompleted(n) : C.someAborted(aborted)) : aborted === 0 ? C.completed : C.aborted;
  const reception = checkRow(
    "check-reception",
    C.reception,
    aborted > 0 ? "warn" : gaps > 0 ? "plain" : "ok",
    `${state}・${gaps === 0 ? C.gapsNone : C.gaps(gaps)}`,
    null,
    receptionDetails(ctx, imageTimes),
  );

  // 全体画像のつながり（画像は「制作の流れ」）
  const counts = wholeCounts(r);
  const whole =
    r.whole && counts
      ? checkRow("check-whole", C.whole, counts.unconfirmed === 0 ? "ok" : "plain", C.wholeValue(counts.linked, counts.unconfirmed), r.whole.shown ? null : C.wholeHiddenLine)
      : null;

  // 提出画像との対応
  const mr = r.match.result;
  const I2 = TEXT.images;
  const images = checkRow(
    "check-images",
    C.images,
    mr === "match" ? "ok" : mr === "mismatch" ? "warn" : "plain",
    mr === "match" ? C.match : mr === "mismatch" ? C.mismatch : C.unverifiedMatch,
    mr === "match" ? null : `${mr === "mismatch" ? I2.mismatch_ : I2.unverified}${r.match.reason ? ` ${I2.reason(r.match.reason)}` : ""}`,
    imagesDetails(ctx),
  );

  // 未確認事項（ある場合だけ）
  const unverified =
    r.unverified.length > 0
      ? checkRow("check-unverified", C.unverified, "plain", C.unverifiedCount(r.unverified.length), el("ul", { class: "unverified" }, ...r.unverified.map((t) => el("li", {}, t))))
      : null;

  return sectionWithInfo("checks", TEXT.sections.checks, "term-integrity", el("div", { class: "check-list" }, integrity, reception, whole, images, unverified));
}

// ---------------------------------------------------------------- 申告・この記録について・補足・ダウンロード

function declarationPart(ctx: RenderContext): HTMLElement {
  const d = ctx.manifest.declaration;
  const text = ctx.result.declaration?.text ?? d.text;
  // 【11/8】版2では、作者が書いた詳細も出す（文字として出す。改行はそのまま）
  const detail = d.version === 2 && typeof d.detail === "string" && d.detail.trim() !== "" ? d.detail : null;
  return sectionWithInfo(
    "declaration",
    TEXT.sections.declaration,
    "term-declaration",
    el(
      "blockquote",
      { class: "declaration" },
      el("p", { class: "declaration-text" }, text),
      detail ? el("div", { class: "declaration-detail" }, el("p", { class: "declaration-detail-label" }, TEXT.declarationDetail), el("p", { class: "declaration-detail-body" }, detail)) : null,
    ),
    el("p", { class: "note" }, TEXT.declarationNote),
  );
}

function list(items: readonly string[], attrs: Attrs = {}): HTMLElement {
  return el("ul", attrs, ...items.map((t) => el("li", {}, t)));
}

/** 【11/9】記録の画面の一番下: 「用語と説明」（確認できないことを含む）への入口 */
function termsLink(): HTMLElement {
  return el("section", { id: "about", class: "block terms-link" }, el("a", { href: "#term-cannot", "data-back": "about", class: "terms-open" }, TEXT.terms.open, " →"));
}

type Term = { id: string; title: string; reading?: readonly string[]; body: readonly string[] };

/** 【11/9】注釈をすべて並べた「用語と説明」の画面（設計書0章の「確認できないこと」もここに載せる） */
function termsView(ctx: RenderContext, openTerms: ReadonlySet<string>): HTMLElement {
  const W = TEXT.whole;
  const R = TEXT.reception;
  const I = TEXT.images;
  const S = TEXT.sections;
  const { reading } = TEXT.terms;
  const cannot = ctx.manifest.sessions.length > 1 ? [...TEXT.cannot, TEXT.cannotBetween] : TEXT.cannot;
  const terms: Term[] = [
    { id: "term-cannot", title: S.cannot, body: cannot },
    { id: "term-cannot-tell", title: S.cannotTell, body: TEXT.cannotTell },
    { id: "term-can", title: S.can, body: TEXT.can },
    { id: "term-whole", title: S.wholeAbout, reading: reading.whole, body: [W.about, W.limits] },
    { id: "term-integrity", title: TEXT.checks.integrity, reading: reading.integrity, body: ["端末の署名、記録どうしのつながり（ハッシュ）、件数を、確定記録と照らして、このページを開いたブラウザの中で確かめた結果です。合わない箇所があれば、その場所を「詳しく」に出します。", TEXT.downloadNote] },
    {
      id: "term-reception",
      title: TEXT.checks.reception,
      reading: reading.reception,
      body: [
        "「正常に終了」は、録画の最後の記録（最終チャンク）が届いていることです。届いていなければ「正常に終わっていない」と出します。",
        "「録画が続いた時間」は、運営が最初の記録を受け取ってから最後の記録を受け取るまでの時間（受信区間）です。録画が続いた時間で、この絵の制作時間ではありません。",
        R.betweenNote,
        "「受信の空き」は、記録が30秒を超えて届かなかった所です。「チャンク12の後 約0分45秒」は、12番目の記録の後に約45秒あいたことを表します。理由（通信の切れ・端末の停止など）は記録からは分かりません。",
        "帯の「受信」は録画が続いた時間、「受信の空き」は記録が届かなかった間です。",
        `帯の「画面の変化」は、${R.barActive}`,
        R.barTimesNote,
      ],
    },
    { id: "term-editor", title: R.editorTermTitle, reading: reading.editor, body: R.editorNotes },
    { id: "term-match", title: TEXT.checks.images, reading: reading.match, body: ["提出画像（PNG）が、記録の終了画面と外観で一致するかを、決まったルールの画像照合で確かめた結果です。", "「一致の度合い」は、位置を合わせた後の似ている度合い（SSIM、0〜1）です。", "手元の PNG を落とすと、そのファイルのハッシュが、確定記録の提出画像と同じかを照合します。", I.hashNote] },
    { id: "term-declaration", title: TEXT.declarationLabel, body: [TEXT.declarationNote] },
    { id: "term-explanation", title: S.explanation, reading: [TEXT.explanation.note], body: TEXT.explanation.details },
    { id: "term-download", title: S.download, body: [...TEXT.downloadAbout, TEXT.keyVersion(ctx.bundle.kms.keyVersion)] },
  ];
  const back = el("a", { href: "#", class: "terms-back" }, "← ", TEXT.terms.back);
  return el(
    "section",
    { class: "terms", id: "terms" },
    back,
    el("h1", { class: "terms-title" }, TEXT.terms.title),
    ...terms.map((t) => {
      const term = el("div", { class: "term", id: t.id }, el("h2", {}, t.title));
      const body = list(t.body);
      if (t.reading) {
        const details = el("details", { class: "term-details" }, el("summary", {}, TEXT.terms.details), body);
        details.open = openTerms.has(t.id);
        term.append(list(t.reading, { class: "term-reading" }), details);
      } else {
        term.append(body);
      }
      return term;
    }),
  );
}

function explanationPart(ctx: RenderContext): HTMLElement | null {
  const ex = ctx.bundle.explanation;
  if (!ex) return null;
  const text = ex.text.trim();
  const s = sectionWithInfo(
    "explanation", TEXT.sections.explanation, "term-explanation",
    el(text ? "blockquote" : "p", { class: "ai-result" }, text || TEXT.explanation.empty),
    el("p", { class: "note" }, TEXT.explanation.note),
  );
  s.classList.add("ai");
  return s;
}

function downloadPart(ctx: RenderContext): HTMLElement {
  const btn = el("button", { type: "button", class: "button button-quiet" }, TEXT.downloadButton);
  btn.addEventListener("click", () => {
    const blob = new Blob([JSON.stringify(ctx.bundle, null, 1)], { type: "application/json" });
    const a = el("a", { href: URL.createObjectURL(blob), download: "bundle.json" });
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  });
  // 【11/9】何に使うものか・鍵の版は「用語と説明」に置く
  return sectionWithInfo("download", TEXT.sections.download, "term-download", btn);
}

/** 【11/9】URL の # が term- で始まる間は「用語と説明」の画面を出す。戻るときは来た節へ */
let backTo = "";
function applyView(root: HTMLElement): void {
  const h = decodeURIComponent(location.hash.slice(1));
  const terms = h.startsWith("term-");
  root.classList.toggle("show-terms", terms);
  const target = h ? document.getElementById(h) : null;
  if (terms) {
    const back = root.querySelector<HTMLAnchorElement>(".terms-back");
    if (back) back.href = `#${backTo}`;
  }
  if (target) target.scrollIntoView({ block: "start" });
  else if (!terms) window.scrollTo({ top: 0 });
}
let viewBound = false;
function bindView(root: HTMLElement): void {
  if (viewBound) return;
  viewBound = true;
  root.addEventListener("click", (e) => {
    const a = (e.target as HTMLElement).closest<HTMLAnchorElement>("a[data-back]");
    if (a) backTo = a.dataset.back ?? "";
  });
  window.addEventListener("hashchange", () => applyView(root));
}

export function render(root: HTMLElement, ctx: RenderContext): void {
  const imageTimes = ctx.result.whole ? wholeTimes(ctx) : [];
  const openTerms = new Set(Array.from(root.querySelectorAll(".term-details[open]"), (detail) => detail.parentElement?.id ?? ""));
  root.replaceChildren(
    topBar(ctx.isFixture),
    el(
      "main",
      {},
      workPart(ctx),
      factsPart(ctx),
      processPart(ctx, imageTimes),
      checksPart(ctx, imageTimes),
      declarationPart(ctx),
      explanationPart(ctx),
      downloadPart(ctx),
      termsLink(),
    ),
    termsView(ctx, openTerms),
    el("footer", { class: "foot" }, el("p", {}, TEXT.footer)),
  );
  bindView(root);
  if (location.hash.startsWith("#term-")) applyView(root);
}

export function renderMessage(root: HTMLElement, message: string, isFixture = false): void {
  root.replaceChildren(
    topBar(isFixture),
    el("main", {}, el("section", { class: "work" }, el("div", { class: "work-meta" }, el("p", { class: "eyebrow" }, TEXT.eyebrow), el("p", { class: "message" }, message)))),
  );
}
