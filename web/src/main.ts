// URL から publicId（または ?fixture=名前）を取り出して、読み込み → 検証 → 表示。
import kmsPem from "./config/kms_public.pem?raw";
import testPem from "./config/test_public.pem?raw";
import "./ui/style.css";
import { render, renderMessage } from "./ui/render";
import { TEXT } from "./ui/text";
import { readManifest, verifyBundle, verifyWholeImages } from "./verify/verify";
import type { Bundle } from "./verify/types";

type Source = { bundleUrl: string; fileUrl: (name: string) => string; pem: string; isFixture: boolean };

function source(): Source | null {
  const params = new URLSearchParams(location.search);
  const fixture = params.get("fixture");
  if (fixture && /^[a-z0-9_]+$/.test(fixture)) {
    const base = `/fixtures/${fixture}`;
    return { bundleUrl: `${base}/bundle.json`, fileUrl: (n) => `${base}/${n}`, pem: testPem, isFixture: true };
  }
  const m = location.pathname.match(/^\/p\/([A-Za-z0-9_-]{16,64})\/?$/);
  if (m) {
    const base = `/v1/p/${m[1]}`;
    return { bundleUrl: base, fileUrl: (n) => `${base}/files/${encodeURIComponent(n)}`, pem: kmsPem, isFixture: false };
  }
  return null;
}

async function main(): Promise<void> {
  const root = document.querySelector<HTMLDivElement>("#app")!;
  document.title = TEXT.pageTitle;
  const src = source();
  if (!src) return renderMessage(root, TEXT.notFound);
  renderMessage(root, TEXT.loading, src.isFixture);

  let bundle: Bundle;
  try {
    const r = await fetch(src.bundleUrl, { headers: { Accept: "application/json" } });
    if (!r.ok) throw new Error(String(r.status));
    bundle = (await r.json()) as Bundle;
  } catch {
    return renderMessage(root, TEXT.notFound, src.isFixture);
  }

  // 画像は1回だけ取り、検証と表示の両方に使う
  const cache = new Map<string, Uint8Array | null>();
  const urls = new Map<string, string>();
  const fetchFile = async (name: string): Promise<Uint8Array | null> => {
    if (cache.has(name)) return cache.get(name)!;
    let data: Uint8Array | null = null;
    try {
      const r = await fetch(src.fileUrl(name));
      if (r.ok && (r.headers.get("content-type") ?? "").startsWith("image/")) data = new Uint8Array(await r.arrayBuffer());
    } catch {
      data = null;
    }
    cache.set(name, data);
    if (data) urls.set(name, URL.createObjectURL(new Blob([data.slice().buffer as ArrayBuffer], { type: "image/jpeg" })));
    return data;
  };

  const status = root.querySelector(".message");
  let result = await verifyBundle(bundle, {
    expectedPem: src.pem,
    fetchFile,
    onProgress: (d, t) => status && (status.textContent = TEXT.verifying(d, t)),
    deferWholeImages: true,
  });
  if (bundle.files.png) await fetchFile(bundle.files.png);
  const manifest = readManifest(bundle);
  document.title = `${manifest.title} — ${TEXT.pageTitle}`;
  const show = () =>
    render(root, {
      bundle,
      manifest,
      result,
      fileUrl: (n) => (n ? (urls.get(n) ?? null) : null),
      isFixture: src.isFixture,
    });
  show();

  // 全体画像は、画面を出した後に進み具合を出しながら確かめ、終わったら整合性の表示を更新する（T13）
  if (result.whole?.shown && result.whole.items.some((x) => x.status === "pending")) {
    result = await verifyWholeImages(bundle, manifest, result, fetchFile, (d, t) => {
      const note = root.querySelector("#process .whole-note");
      if (note) note.setAttribute("data-progress", TEXT.whole.checking(d, t));
    });
    show();
  }
}

void main();
