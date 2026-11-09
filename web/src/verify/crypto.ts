// ブラウザでの検証（設計書6章、tasks/00_共通仕様.md 3章）。
// - 端末の公開鍵: x9.63（65バイト）を importKey("raw")
// - KMS の公開鍵: PEM（SPKI）を importKey("spki")
// - 署名の検証は WebCrypto の ECDSA P-256 / SHA-256。WebCrypto は r‖s を受け取るので、
//   KMS の DER 署名は derToRs で変換してから渡す。

const ECDSA_P256 = { name: "ECDSA", namedCurve: "P-256" } as const;
const ECDSA_SHA256 = { name: "ECDSA", hash: "SHA-256" } as const;

/** WebCrypto に渡すため、Uint8Array を独立した ArrayBuffer にする。 */
function buf(bytes: Uint8Array): ArrayBuffer {
  return bytes.slice().buffer as ArrayBuffer;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", buf(bytes)));
  return Array.from(d, (x) => x.toString(16).padStart(2, "0")).join("");
}

const B64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

/** 標準 base64（パディングあり）を厳密に復号する。 */
export function b64ToBytes(s: string): Uint8Array {
  if (!B64_RE.test(s)) throw new Error("invalid base64");
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

export async function importDeviceKey(x963: Uint8Array): Promise<CryptoKey> {
  if (x963.length !== 65 || x963[0] !== 0x04) {
    throw new Error("device public key must be 65-byte x9.63 (0x04||X||Y)");
  }
  return crypto.subtle.importKey("raw", buf(x963), ECDSA_P256, false, ["verify"]);
}

export async function importKmsKey(pem: string): Promise<CryptoKey> {
  const m = pem.match(/-----BEGIN PUBLIC KEY-----([\s\S]+?)-----END PUBLIC KEY-----/);
  if (!m) throw new Error("not a PEM public key");
  const der = b64ToBytes(m[1].replace(/\s+/g, ""));
  return crypto.subtle.importKey("spki", buf(der), ECDSA_P256, false, ["verify"]);
}

/** r‖s（64バイト）の署名を検証する。長さが違えば false。 */
export async function verifyRs(key: CryptoKey, rs: Uint8Array, msg: Uint8Array): Promise<boolean> {
  if (rs.length !== 64) return false;
  return crypto.subtle.verify(ECDSA_SHA256, key, buf(rs), buf(msg));
}

/** KMS の DER 署名を検証する。DER が壊れていれば false。 */
export async function verifyDer(key: CryptoKey, der: Uint8Array, msg: Uint8Array): Promise<boolean> {
  let rs: Uint8Array;
  try {
    rs = derToRs(der);
  } catch {
    return false;
  }
  return verifyRs(key, rs, msg);
}

/**
 * DER（SEQUENCE { INTEGER r, INTEGER s }）を r‖s の64バイトにする。
 * 整数は先頭に 0x00 が付いた33バイトのことも、32バイト未満のこともある。
 */
export function derToRs(der: Uint8Array): Uint8Array {
  let p = 0;
  const fail = (why: string): never => {
    throw new Error(`invalid DER signature: ${why}`);
  };
  const readLen = (): number => {
    if (p >= der.length) fail("truncated");
    const first = der[p++];
    if (first < 0x80) return first;
    if (first !== 0x81) fail("unsupported length"); // P-256 の署名は 0x81 までで足りる
    if (p >= der.length) fail("truncated");
    const len = der[p++];
    if (len < 0x80) fail("non-minimal length");
    return len;
  };
  const readInt = (): Uint8Array => {
    if (der[p++] !== 0x02) fail("expected INTEGER");
    const len = readLen();
    if (len === 0 || p + len > der.length) fail("bad INTEGER length");
    let v = der.subarray(p, p + len);
    p += len;
    if (v[0] & 0x80) fail("negative INTEGER");
    if (v.length > 1 && v[0] === 0x00) {
      if (!(v[1] & 0x80)) fail("non-minimal INTEGER");
      v = v.subarray(1);
    }
    if (v.length > 32) fail("INTEGER too large");
    const out = new Uint8Array(32);
    out.set(v, 32 - v.length);
    return out;
  };

  if (der[p++] !== 0x30) fail("expected SEQUENCE");
  const seqLen = readLen();
  if (p + seqLen !== der.length) fail("SEQUENCE length mismatch");
  const r = readInt();
  const s = readInt();
  if (p !== der.length) fail("trailing bytes");
  const rs = new Uint8Array(64);
  rs.set(r, 0);
  rs.set(s, 32);
  return rs;
}
