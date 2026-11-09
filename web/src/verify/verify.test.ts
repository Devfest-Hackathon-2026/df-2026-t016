// T06 の10種類で、verifyBundle の結果が expected.json と一致すること（detail は比べない）。
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { decideStatus, estimateLargeChangeMs, readManifest, statusRank, verifyBundle, verifyWholeImages } from "./verify";
import { b64ToBytes, bytesToB64 } from "./crypto";
import type { BundleV1, ProblemKind, VerifyResult } from "./types";

const fixDir = fileURLToPath(new URL("../../public/fixtures/", import.meta.url));
const vectors = JSON.parse(readFileSync(fileURLToPath(new URL("../../../shared/vectors/signing.json", import.meta.url)), "utf-8"));
const testPem = readFileSync(fileURLToPath(new URL("../config/test_public.pem", import.meta.url)), "utf-8");
const index = JSON.parse(readFileSync(join(fixDir, "index.json"), "utf-8")) as { fixtures: { name: string }[] };

function load(name: string) {
  const d = join(fixDir, name);
  // v:1 の試験で chunks を直接さわるので BundleV1 として読む（【T14】v:2 の試験データも verifyBundle にはそのまま渡せる）
  const bundle = JSON.parse(readFileSync(join(d, "bundle.json"), "utf-8")) as BundleV1;
  const expected = JSON.parse(readFileSync(join(d, "expected.json"), "utf-8")) as VerifyResult;
  const fetchFile = async (n: string) => {
    const p = join(d, n);
    return existsSync(p) ? new Uint8Array(readFileSync(p)) : null;
  };
  return { bundle, expected, fetchFile };
}

const strip = (r: VerifyResult) => {
  // 既存の expected.json との比較。Web で換算する大きな変化は個別に試験する。
  const { largeChangeMs: _largeChangeMs, ...reception } = r.reception;
  return {
    ...r,
    reception,
    integrity: { ...r.integrity, problems: r.integrity.problems.map(({ session, seq, kind }) => ({ session, seq, kind })) },
  };
};

describe("試験データ（T06）", () => {
  it("17種類がある（T06 の10種類と T13 の4種類、T14 の2種類、【11/8】申告の版2の1種類）", () => {
    expect(index.fixtures.map((f) => f.name)).toHaveLength(17);
    expect(readdirSync(fixDir).filter((n) => !n.includes("."))).toHaveLength(17);
  });

  it("【T14】記録が複数の証拠一式（v:2）: 記録ごとの受信と、記録をまたぐ全体画像", async () => {
    const { bundle, fetchFile } = load("multi_session");
    const r = await verifyBundle(bundle, { expectedPem: testPem, fetchFile });
    expect(r.integrity.status).toBe("ok");
    expect(r.reception.sessions!.map((x) => x.status)).toEqual(["completed", "aborted", "completed"]);
    expect(r.reception.status).toBe("aborted");
    expect(r.reception.largeChangeMs).toBe(0);
    expect(r.reception.gaps).toEqual([{ session: 1, after: 15, sec: r.reception.gaps[0].sec }]);
    expect(r.whole!.items.map((x) => x.session)).toEqual([0, 0, 1, 1, 2, 2]);
    expect(readManifest(bundle).sessions).toHaveLength(3);
  });

  it("【T14】v:1 の証拠一式は記録が1回として読む", () => {
    const { bundle } = load("normal");
    const m = readManifest(bundle);
    expect(m.sessions).toHaveLength(1);
    expect(m.sessions[0].chunks.count).toBe(bundle.chunks.length);
  });

  it("全体画像の取得を後回しにすると pending になり、後で確かめると同じ結果になる", async () => {
    const { bundle, expected, fetchFile } = load("whole_tampered");
    const first = await verifyBundle(bundle, { expectedPem: testPem, fetchFile, deferWholeImages: true });
    expect(first.whole!.items.every((x) => x.status === "pending")).toBe(true);
    expect(first.integrity.status).toBe("ok");
    const seen: number[] = [];
    const after = await verifyWholeImages(bundle, readManifest(bundle), first, fetchFile, (d) => seen.push(d));
    expect(strip(after)).toEqual(strip(expected));
    expect(seen.at(-1)).toBe(6);
  });

  it("テスト用の公開鍵は signing.json と同じ", () => {
    const lf = (x: string) => x.replace(/\r\n/g, "\n").trim();
    expect(lf(testPem)).toBe(lf(vectors.kmsKey.publicPem));
  });

  for (const { name } of index.fixtures) {
    it(`${name} の結果が expected.json と一致する`, async () => {
      const { bundle, expected, fetchFile } = load(name);
      const got = await verifyBundle(bundle, { expectedPem: testPem, fetchFile });
      expect(strip(got)).toEqual(strip(expected));
    });
  }

  it("埋め込みと違う公開鍵だと署名の不一致", async () => {
    const { bundle, fetchFile } = load("normal");
    const other = readFileSync(fileURLToPath(new URL("../config/kms_public.pem", import.meta.url)), "utf-8");
    const got = await verifyBundle(bundle, { expectedPem: other, fetchFile });
    expect(got.integrity.status).toBe("signature_mismatch");
    expect(got.integrity.problems[0].kind).toBe("key");
  });

  it("画像が取れないと資料不足、違うと内容の不一致", async () => {
    const { bundle, fetchFile } = load("normal");
    const missing = await verifyBundle(bundle, { expectedPem: testPem, fetchFile: async (n) => (n === "end.jpg" ? null : fetchFile(n)) });
    expect(missing.integrity.status).toBe("incomplete");
    expect(missing.images.end).toBe("missing");
    const wrong = await verifyBundle(bundle, { expectedPem: testPem, fetchFile: async (n) => (n === "start.jpg" ? new Uint8Array([1]) : fetchFile(n)) });
    expect(wrong.integrity.status).toBe("content_mismatch");
    expect(wrong.images.start).toBe("mismatch");
  });

  it("編集画面の時間はヘッダの stats の合計。項目の無い記録では null", async () => {
    const { bundle, fetchFile } = load("normal");
    const r = await verifyBundle(bundle, { expectedPem: testPem, fetchFile });
    expect(r.reception.editorMs).toBe(600000);
    expect(r.reception.largeChangeMs).toBe(0);
    const old = { ...bundle, chunks: bundle.chunks.map((ch) => {
      const h = JSON.parse(new TextDecoder().decode(b64ToBytes(ch.header)));
      delete h.stats.editorMs;
      delete h.stats.activeMs;
      return { ...ch, header: bytesToB64(new TextEncoder().encode(JSON.stringify(h))) };
    }) };
    const r2 = await verifyBundle(old, { expectedPem: testPem, fetchFile });
    expect(r2.reception.editorMs).toBeNull();
    expect(r2.reception.activeMs).toBeNull();
    expect(r2.reception.largeChangeMs).toBeNull();
  });

  it("進み具合を知らせる", async () => {
    const { bundle, fetchFile } = load("normal");
    const seen: number[] = [];
    await verifyBundle(bundle, { expectedPem: testPem, fetchFile, onProgress: (d) => seen.push(d) });
    expect(seen.at(-1)).toBe(bundle.chunks.length);
  });
});

it("大きな画面変化は231マス以上のコマだけを処理頻度で換算する", () => {
  expect(estimateLargeChangeMs([0, 230, 231, 768], 2)).toBe(1000);
  expect(estimateLargeChangeMs([230, 231], 1)).toBe(1000);
  expect(estimateLargeChangeMs([], 2)).toBe(0);
  expect(estimateLargeChangeMs(null, 2)).toBeNull();
  expect(estimateLargeChangeMs([231], undefined)).toBeNull();
  expect(estimateLargeChangeMs([769], 2)).toBeNull();
});

describe("kind から状態への対応", () => {
  const all: ProblemKind[] = ["signature", "chain", "hash", "count", "key", "gap", "image", "missing"];
  const want = {
    missing: "incomplete",
    signature: "signature_mismatch",
    key: "signature_mismatch",
    hash: "content_mismatch",
    image: "content_mismatch",
    chain: "chain_broken",
    count: "manifest_mismatch",
    gap: "manifest_mismatch",
  } as const;
  it("すべての kind が状態に結びつく", () => {
    for (const k of all) expect(statusRank(k).status).toBe(want[k]);
  });
  it("上の順に先に当てはまったものを採る", () => {
    expect(decideStatus([])).toBe("ok");
    expect(decideStatus([{ kind: "count", detail: "" }, { kind: "chain", detail: "" }])).toBe("chain_broken");
    expect(decideStatus([{ kind: "hash", detail: "" }, { kind: "missing", detail: "" }])).toBe("incomplete");
    expect(decideStatus([{ kind: "gap", detail: "" }, { kind: "key", detail: "" }])).toBe("signature_mismatch");
  });
});
