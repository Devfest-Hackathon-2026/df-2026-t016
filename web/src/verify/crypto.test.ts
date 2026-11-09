// shared/vectors/signing.json の全項目を、ブラウザと同じ WebCrypto で検証する。
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  b64ToBytes,
  bytesToB64,
  derToRs,
  importDeviceKey,
  importKmsKey,
  sha256Hex,
  verifyDer,
  verifyRs,
} from "./crypto";

const vecUrl = new URL("../../../shared/vectors/signing.json", import.meta.url);
const V = JSON.parse(readFileSync(fileURLToPath(vecUrl), "utf-8"));
const swiftPath = fileURLToPath(new URL("../../../shared/vectors/swift_signature.json", import.meta.url));

const enc = new TextEncoder();

/** Python の json.dumps(sort_keys, separators=(",",":"), ensure_ascii=False) と同じ並び。 */
function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (v !== null && typeof v === "object") {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(v);
}

describe("base64 と SHA-256", () => {
  it("往復する", () => {
    for (const b of [new Uint8Array([]), new Uint8Array([0]), new Uint8Array([255, 254, 253])]) {
      expect(b64ToBytes(bytesToB64(b))).toEqual(b);
    }
    const big = new Uint8Array(100_000).map((_, i) => i & 0xff);
    expect(b64ToBytes(bytesToB64(big))).toEqual(big);
  });

  it("不正な base64 を弾く", () => {
    expect(() => b64ToBytes("abc")).toThrow();
    expect(() => b64ToBytes("ab-_")).toThrow();
  });

  it("ベクタのハッシュと一致する", async () => {
    for (const k of ["startCert", "body", "header"]) {
      expect(await sha256Hex(b64ToBytes(V[k].bytes))).toBe(V[k].sha256);
    }
  });

  it("ベクタのバイト列は正準 JSON", () => {
    const dec = new TextDecoder();
    for (const k of ["canonical", "startCert", "body", "header", "receipt"]) {
      expect(dec.decode(b64ToBytes(V[k].bytes))).toBe(canonical(V[k].obj));
    }
  });

  it("タイルのビットの並び", () => {
    const t = b64ToBytes(V.body.obj.tiles);
    expect(t.length).toBe(96);
    const on: number[] = [];
    for (let i = 0; i < 768; i++) if ((t[i >> 3] >> (7 - (i % 8))) & 1) on.push(i);
    expect(on).toEqual(V.body.tilesSet);
  });
});

describe("端末署名（r‖s）", () => {
  it("ヘッダの署名が通る", async () => {
    const key = await importDeviceKey(b64ToBytes(V.deviceKey.publicX963));
    const header = b64ToBytes(V.header.bytes);
    const sig = b64ToBytes(V.deviceSig.sig);
    expect(await verifyRs(key, sig, header)).toBe(true);
    expect(await verifyRs(key, sig, enc.encode("tampered"))).toBe(false);
    const flipped = sig.slice();
    flipped[10] ^= 1;
    expect(await verifyRs(key, flipped, header)).toBe(false);
    expect(await verifyRs(key, sig.subarray(0, 63), header)).toBe(false);
  });

  it("画像の署名が通る", async () => {
    const key = await importDeviceKey(b64ToBytes(V.deviceKey.publicX963));
    expect(V.imageSig.message).toMatch(new RegExp(`^image:${V.header.obj.sid}:[0-9a-f]{64}$`));
    expect(await verifyRs(key, b64ToBytes(V.imageSig.sig), enc.encode(V.imageSig.message))).toBe(true);
  });

  it("x9.63 でない公開鍵を弾く", async () => {
    const raw = b64ToBytes(V.deviceKey.publicX963);
    await expect(importDeviceKey(raw.subarray(0, 33))).rejects.toThrow();
  });
});

describe("KMS 署名（DER）", () => {
  it("開始証と受領証の署名が通る", async () => {
    const key = await importKmsKey(V.kmsKey.publicPem);
    for (const k of ["startCert", "receipt"]) {
      const msg = b64ToBytes(V[k].bytes);
      const der = b64ToBytes(V[k].sig);
      expect(await verifyDer(key, der, msg)).toBe(true);
      expect(await verifyDer(key, der, enc.encode("x"))).toBe(false);
    }
  });

  it("壊れた DER は false", async () => {
    const key = await importKmsKey(V.kmsKey.publicPem);
    const der = b64ToBytes(V.startCert.sig);
    expect(await verifyDer(key, der.subarray(0, der.length - 1), b64ToBytes(V.startCert.bytes))).toBe(false);
  });

  it("PEM でないものを弾く", async () => {
    await expect(importKmsKey("hello")).rejects.toThrow();
  });
});

describe("derToRs", () => {
  for (const c of V.derToRs) {
    it(c.note, () => {
      const rs = derToRs(b64ToBytes(c.der));
      expect(rs.length).toBe(64);
      expect(bytesToB64(rs)).toBe(c.rs);
    });
  }

  it("末尾の余分なバイトを弾く", () => {
    const der = b64ToBytes(V.derToRs[0].der);
    const extra = new Uint8Array([...der, 0]);
    expect(() => derToRs(extra)).toThrow();
  });
});

describe.skipIf(!existsSync(swiftPath))("Swift の署名（T03 で置く）", () => {
  it("Swift で作ったヘッダの署名が通る", async () => {
    const s = JSON.parse(readFileSync(swiftPath, "utf-8"));
    const key = await importDeviceKey(b64ToBytes(s.publicX963));
    const header = b64ToBytes(s.header ?? V.header.bytes);
    expect(await verifyRs(key, b64ToBytes(s.sig), header)).toBe(true);
  });
});
