// 証拠一式の検証（tasks/T09）。DOM に触らない純粋な関数。
// 問題（problems）の決め方は tools/fixtures/README.md と同じ。同じ（seq, kind）は1つにまとめる。

import { b64ToBytes, importDeviceKey, importKmsKey, sha256Hex, verifyDer, verifyRs } from "./crypto";
import type {
  Bundle,
  BundleSession,
  Gap,
  ImageState,
  IntegrityStatus,
  Manifest,
  NormManifest,
  Problem,
  ProblemKind,
  SessionReception,
  StartCert,
  VerifyResult,
  WholeItemState,
} from "./types";
import { UNVERIFIED } from "../ui/text";

export type VerifyOptions = {
  /** 埋め込みの KMS の公開鍵（試験データのときはテスト用の鍵） */
  expectedPem: string;
  /** files のファイル名から画像のバイト列を取る。取れなければ null */
  fetchFile: (name: string) => Promise<Uint8Array | null>;
  /** 進み具合（0〜1） */
  onProgress?: (done: number, total: number) => void;
  /** true なら全体画像の取得は飛ばして pending にする（画面を出した後に verifyWholeImages で確かめる） */
  deferWholeImages?: boolean;
};

const dec = new TextDecoder();

/** kind から状態への対応。抜けがあると型エラーになる（網羅チェック）。 */
export function statusRank(kind: ProblemKind): { rank: number; status: Exclude<IntegrityStatus, "ok"> } {
  switch (kind) {
    case "missing":
      return { rank: 1, status: "incomplete" };
    case "signature":
    case "key":
      return { rank: 2, status: "signature_mismatch" };
    case "hash":
    case "image":
      return { rank: 3, status: "content_mismatch" };
    case "chain":
      return { rank: 4, status: "chain_broken" };
    case "count":
    case "gap":
      return { rank: 5, status: "manifest_mismatch" };
    default: {
      const never: never = kind;
      throw new Error(`unknown kind ${String(never)}`);
    }
  }
}

export function decideStatus(problems: Problem[]): IntegrityStatus {
  if (problems.length === 0) return "ok";
  return problems.map((p) => statusRank(p.kind)).sort((a, b) => a.rank - b.rank)[0].status;
}

function normPem(pem: string): string {
  return pem.replace(/\r\n/g, "\n").trim();
}

function parseJson<T>(bytes: Uint8Array): T | null {
  try {
    return JSON.parse(dec.decode(bytes)) as T;
  } catch {
    return null;
  }
}

/** 受信の空き（30秒超）。秒は小数3桁に丸める。 */
export function computeGaps(times: { seq: number; at: string }[]): Gap[] {
  const out: Gap[] = [];
  for (let i = 1; i < times.length; i++) {
    const sec = (Date.parse(times[i].at) - Date.parse(times[i - 1].at)) / 1000;
    if (sec > 30) out.push({ after: times[i - 1].seq, sec: Math.round(sec * 1000) / 1000 });
  }
  return out;
}

/** v:1 の確定記録を、記録が1回の v:2 の形にする（【T14】）。 */
export function normalizeManifest(m: Manifest): NormManifest {
  if (m.v === 2) return m;
  const { sid, status, chunks, received, ...rest } = m;
  return { ...rest, sessions: [{ sid, status, chunks, received }] };
}

/** 証拠一式の記録（開始証とチャンク）。v:1 は1つ（【T14】）。 */
export function bundleSessions(bundle: Bundle): BundleSession[] {
  return bundle.v === 2 ? bundle.sessions : [{ start: bundle.start, chunks: bundle.chunks }];
}

type HeaderLike = {
  seq?: number;
  prev?: string;
  body?: string;
  bodyLen?: number;
  images?: { whole?: string };
  stats?: { editorMs?: number; activeMs?: number; fps?: number };
};

/** 録画拡張と同じ境目（32×24マスのうち231以上）。チャンクに保存された処理頻度で換算する。 */
export function estimateLargeChangeMs(frames: number[] | null, fps: number | undefined): number | null {
  if (frames === null || (fps !== 1 && fps !== 2)) return null;
  if (!frames.every((count) => Number.isInteger(count) && count >= 0 && count <= 768)) return null;
  return frames.filter((count) => count >= 231).length * (1000 / fps);
}

export async function verifyBundle(bundle: Bundle, opts: VerifyOptions): Promise<VerifyResult> {
  const multi = bundle.v === 2; // 【T14】v:2 だけ、問題・受信・全体画像に記録の番号を付ける
  const problems: Problem[] = [];
  const add = (kind: ProblemKind, detail: string, seq?: number, session?: number) => {
    const sess = multi ? session : undefined;
    if (problems.some((p) => p.kind === kind && p.seq === seq && p.session === sess)) return;
    const p: Problem = { kind, detail };
    if (sess !== undefined) p.session = sess;
    if (seq !== undefined) p.seq = seq;
    problems.push(p);
  };

  // 1. 公開鍵
  if (normPem(bundle.kms.publicKeyPem) !== normPem(opts.expectedPem)) add("key", "公開鍵が一致しない");
  const kmsKey = await importKmsKey(opts.expectedPem);

  // 2. 確定記録の署名
  const mb = b64ToBytes(bundle.manifest.bytes);
  if (!(await verifyDer(kmsKey, b64ToBytes(bundle.manifest.sig), mb))) add("signature", "確定記録の署名が合わない");
  const raw = parseJson<Manifest>(mb);
  if (!raw) throw new Error("確定記録を読めません");
  const manifest = normalizeManifest(raw);
  const sessions = bundleSessions(bundle);
  if (multi && sessions.length !== manifest.sessions.length) {
    add("count", `記録の数が確定記録と合わない（${sessions.length}回、確定記録は${manifest.sessions.length}回）`);
  }

  // 3〜6. 記録ごとに、開始証・チャンク・件数・受信の空き
  const total = sessions.reduce((a, s) => a + s.chunks.length, 0);
  let doneBefore = 0;
  const receptions: SessionReception[] = [];
  const largeChangeTimes: number[] = [];
  const wholeFromHeaders: { session: number; seq: number; sha: string }[] = [];
  const timesBySession: { seq: number; at: string }[][] = [];
  for (let si = 0; si < sessions.length; si++) {
    const bs = sessions[si];
    const ms = manifest.sessions[si];
    const sb = b64ToBytes(bs.start.bytes);
    if (!(await verifyDer(kmsKey, b64ToBytes(bs.start.sig), sb))) add("signature", "開始証の署名が合わない", undefined, si);
    const start = parseJson<StartCert>(sb);
    if (!start) throw new Error("開始証を読めません");
    if (multi && ms && start.sid !== ms.sid) add("count", "記録の開始証が確定記録の記録と合わない", undefined, si);
    let deviceKey: CryptoKey | null = null;
    try {
      deviceKey = await importDeviceKey(b64ToBytes(start.devicePubKey));
    } catch {
      add("signature", "開始証の端末の公開鍵を読めない", undefined, si);
    }

    // チャンク。署名とハッシュの計算は並列にまとめて行い、判定は先頭から順に行う
    const n = bs.chunks.length;
    const BATCH = 256;
    type Pre = { hb: Uint8Array; body: Uint8Array; rb: Uint8Array; h: string; bodyHash: string; devOk: boolean; recOk: boolean };
    const pre: Pre[] = new Array(n);
    for (let from = 0; from < n; from += BATCH) {
      const part = bs.chunks.slice(from, from + BATCH);
      const done = await Promise.all(
        part.map(async (ch): Promise<Pre> => {
          const hb = b64ToBytes(ch.header);
          const body = b64ToBytes(ch.body);
          const rb = b64ToBytes(ch.receipt);
          const [h, bodyHash, devOk, recOk] = await Promise.all([
            sha256Hex(hb),
            sha256Hex(body),
            deviceKey ? verifyRs(deviceKey, b64ToBytes(ch.sig), hb) : Promise.resolve(false),
            verifyDer(kmsKey, b64ToBytes(ch.receiptSig), rb),
          ]);
          return { hb, body, rb, h, bodyHash, devOk, recOk };
        }),
      );
      done.forEach((p, j) => (pre[from + j] = p));
      opts.onProgress?.(doneBefore + Math.min(from + BATCH, n), total);
    }
    doneBefore += n;

    let prev = await sha256Hex(sb);
    let prevSeq = -1;
    const times: { seq: number; at: string }[] = [];
    const active: boolean[] = [];
    let editorMs: number | null = null;
    let activeMs: number | null = null;
    let largeChangeMs: number | null = n === 0 ? null : 0;
    const headHashes: string[] = [];
    for (let i = 0; i < n; i++) {
      const { hb, body, rb, h, bodyHash, devOk, recOk } = pre[i];
      const header = parseJson<HeaderLike>(hb) ?? {};
      const receipt = parseJson<{ seq: number; header: string; receivedAt: string }>(rb);
      const seq = typeof header.seq === "number" ? header.seq : (receipt?.seq ?? prevSeq + 1);

      if (!devOk) add("signature", "端末署名が合わない", seq, si);
      if (!receipt || !recOk) {
        add("signature", "受領証の署名が合わない", seq, si);
      } else if (receipt.header !== h) {
        add("signature", "受領証が保証するヘッダと合わない", seq, si);
      }
      if (receipt?.seq !== seq || header.prev !== prev || seq !== prevSeq + 1) {
        add("chain", seq !== prevSeq + 1 ? `前のチャンクとつながらない（チャンク${prevSeq + 1}がない）` : "前のチャンクのヘッダとつながらない", seq, si);
      }
      if (bodyHash !== header.body || body.length !== header.bodyLen) {
        add("hash", "本文のハッシュがヘッダと合わない", seq, si);
      }

      const rawFrames = parseJson<{ frames?: number[] }>(body)?.frames;
      const frames = Array.isArray(rawFrames) ? rawFrames : null;
      active.push((frames ?? []).reduce((a, b) => a + b, 0) > 0);
      // 【11/6】編集画面だった時間と、小さな変化があった時間（項目のあるヘッダだけを足す）
      const { editorMs: editor, activeMs: small, fps } = header.stats ?? {};
      if (typeof editor === "number") editorMs = (editorMs ?? 0) + editor;
      if (typeof small === "number") activeMs = (activeMs ?? 0) + small;
      if (largeChangeMs !== null) {
        // 編集画面の時間を記録する版のチャンクだけを対象にする。
        const hasTimes = Number.isSafeInteger(editor) && (editor ?? -1) >= 0 &&
          Number.isSafeInteger(small) && (small ?? -1) >= 0;
        const estimate = hasTimes ? estimateLargeChangeMs(frames, fps) : null;
        largeChangeMs = estimate === null ? null : largeChangeMs + estimate;
      }
      if (receipt) times.push({ seq, at: receipt.receivedAt });
      if (typeof header.images?.whole === "string") wholeFromHeaders.push({ session: si, seq, sha: header.images.whole });
      headHashes.push(h);
      prev = h;
      prevSeq = seq;
    }
    timesBySession.push(times);

    if (!ms) {
      add("count", "確定記録にない記録がある", undefined, si);
      continue;
    }
    // 件数・先頭・末尾
    const mc = ms.chunks;
    if (
      headHashes.length !== mc.count ||
      (headHashes.length > 0 && (headHashes[0] !== mc.first || headHashes[headHashes.length - 1] !== mc.last))
    ) {
      add("count", `件数か先頭・末尾が確定記録と合わない（${headHashes.length}件、確定記録は${mc.count}件）`, undefined, si);
    }
    // 受信の空き
    const gaps = computeGaps(times);
    const mg = ms.received.gaps;
    if (gaps.length !== mg.length || gaps.some((g, i) => g.after !== mg[i].after || g.sec !== mg[i].sec)) {
      add("gap", "受信の空きが確定記録と合わない", undefined, si);
    }
    if (largeChangeMs !== null && !problems.some((p) => p.session === undefined || p.session === si)) {
      largeChangeTimes.push(largeChangeMs);
    }
    receptions.push({
      sid: ms.sid,
      status: ms.status,
      first: ms.received.first,
      last: ms.received.last,
      gaps: ms.received.gaps,
      activeChunks: active,
      editorMs,
      activeMs,
    });
  }

  // 7. 画像（開始画面は1回目の記録、終了画面は最後の記録のもの）
  const unverified: string[] = [];
  const checkImage = async (k: "start" | "end"): Promise<ImageState> => {
    const want = manifest.images[k];
    if (want === null) {
      unverified.push(k === "start" ? UNVERIFIED.noStart : UNVERIFIED.noEnd);
      return "none";
    }
    const name = bundle.files[k];
    const data = name ? await opts.fetchFile(name) : null;
    if (!data) {
      add("missing", k === "start" ? "開始画面を取得できない" : "終了画面を取得できない");
      return "missing";
    }
    if ((await sha256Hex(data)) !== want) {
      add("image", k === "start" ? "開始画面のハッシュが合わない" : "終了画面のハッシュが合わない");
      return "mismatch";
    }
    return "ok";
  };
  const images = { start: await checkImage("start"), end: await checkImage("end") };
  if (manifest.png === null) unverified.push(UNVERIFIED.noPng);

  // 8. 途中の全体画像（T13）: 一覧がヘッダの並びと合うか（【T14】記録の順・seq の順）
  const mw = manifest.whole ?? null;
  const listed = mw ? mw.items.map((it) => `${it.session ?? 0}:${it.seq}:${it.sha256}`) : [];
  const fromHeaders = wholeFromHeaders.map((w) => `${w.session}:${w.seq}:${w.sha}`);
  if (listed.join(",") !== fromHeaders.join(",")) add("count", "全体画像の一覧が記録と一致しない");
  let whole: VerifyResult["whole"] = null;
  if (mw) {
    const minutes = (session: number, seq: number) => {
      const firstAt = Date.parse(manifest.sessions[session]?.received.first ?? "");
      const t = timesBySession[session]?.find((x) => x.seq === seq);
      return t === undefined || !Number.isFinite(firstAt) ? 0 : Math.round((Date.parse(t.at) - firstAt) / 60000);
    };
    whole = {
      shown: mw.shown,
      items: mw.items.map((it) => {
        const status: WholeItemState = !mw.shown ? "hidden" : !it.received ? "none" : "pending";
        const base = { seq: it.seq, minutes: minutes(it.session ?? 0, it.seq), status };
        return multi ? { session: it.session ?? 0, ...base } : base;
      }),
      links: mw.links,
      toPng: mw.toPng,
    };
    const notReceived = mw.items.filter((it) => !it.received).length;
    if (notReceived > 0) unverified.push(UNVERIFIED.wholeNotReceived(notReceived));
    if (!mw.shown) unverified.push(UNVERIFIED.wholeHidden);
  }

  // 受信状況。v:1 はこれまでと同じ形。v:2 は全記録をまとめ、記録ごとの値を sessions に入れる
  const sum = (xs: (number | null)[]) => (xs.every((x) => x === null) ? null : xs.reduce<number>((a, x) => a + (x ?? 0), 0));
  const largeChangeMs = largeChangeTimes.length === manifest.sessions.length && largeChangeTimes.length === sessions.length
    ? sum(largeChangeTimes)
    : null;
  const firstOf = manifest.sessions.map((x) => x.received.first).find((x) => x !== null) ?? null;
  const lastOf = [...manifest.sessions].reverse().map((x) => x.received.last).find((x) => x !== null) ?? null;
  const reception: VerifyResult["reception"] = multi
    ? {
        status: manifest.sessions.every((x) => x.status === "completed") ? "completed" : "aborted",
        first: firstOf,
        last: lastOf,
        gaps: manifest.sessions.flatMap((x, i) => x.received.gaps.map((g) => ({ session: i, after: g.after, sec: g.sec }))),
        activeChunks: receptions.flatMap((x) => x.activeChunks),
        editorMs: sum(receptions.map((x) => x.editorMs)),
        activeMs: sum(receptions.map((x) => x.activeMs)),
        largeChangeMs,
        sessions: receptions,
      }
    : {
        status: manifest.sessions[0].status,
        first: manifest.sessions[0].received.first,
        last: manifest.sessions[0].received.last,
        gaps: manifest.sessions[0].received.gaps,
        activeChunks: receptions[0]?.activeChunks ?? [],
        editorMs: receptions[0]?.editorMs ?? null,
        activeMs: receptions[0]?.activeMs ?? null,
        largeChangeMs,
      };

  const result: VerifyResult = {
    integrity: { status: decideStatus(problems), problems },
    reception,
    images,
    match: manifest.match,
    declaration: { text: manifest.declaration.text, acceptedAt: manifest.declaration.acceptedAt },
    unverified,
    whole,
  };
  if (opts.deferWholeImages) return result;
  return verifyWholeImages(bundle, manifest, result, opts.fetchFile);
}

/**
 * 載せる設定の全体画像を取得してハッシュを確かめ、result を更新して返す（T13）。
 * 枚数が多いので、ほかの検証の後に進み具合を出しながら行う。
 */
export async function verifyWholeImages(
  bundle: Bundle,
  manifest: NormManifest,
  result: VerifyResult,
  fetchFile: (name: string) => Promise<Uint8Array | null>,
  onProgress?: (done: number, total: number) => void,
): Promise<VerifyResult> {
  const mw = manifest.whole;
  if (!mw || !result.whole || !mw.shown) return result;
  const problems = [...result.integrity.problems];
  const multi = bundle.v === 2;
  const add = (kind: ProblemKind, detail: string, seq: number, session: number) => {
    const sess = multi ? session : undefined;
    if (problems.some((p) => p.kind === kind && p.seq === seq && p.session === sess)) return;
    problems.push(sess === undefined ? { seq, kind, detail } : { session: sess, seq, kind, detail });
  };
  const items = result.whole.items.map((x) => ({ ...x }));
  const names = bundle.files.whole ?? [];
  const todo = mw.items.map((it, i) => ({ it, i })).filter(({ it }) => it.received);
  let done = 0;
  for (const { it, i } of todo) {
    const name = names[i] ?? null;
    const data = name ? await fetchFile(name) : null;
    if (!data) {
      items[i].status = "missing";
      add("missing", "全体画像を取得できない", it.seq, it.session ?? 0);
    } else if ((await sha256Hex(data)) !== it.sha256) {
      items[i].status = "mismatch";
      add("image", "全体画像のハッシュが合わない", it.seq, it.session ?? 0);
    } else {
      items[i].status = "ok";
    }
    onProgress?.(++done, todo.length);
  }
  return {
    ...result,
    integrity: { status: decideStatus(problems), problems },
    whole: { ...result.whole, items },
  };
}

/** 確定記録を読む。v:1 は記録が1回の v:2 の形にして返す（【T14】）。 */
export function readManifest(bundle: Bundle): NormManifest {
  return normalizeManifest(JSON.parse(dec.decode(b64ToBytes(bundle.manifest.bytes))) as Manifest);
}
