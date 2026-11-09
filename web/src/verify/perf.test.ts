// 5000件のチャンクでも数秒で終わること（tasks/T09）。normal の120件を並べ直して5000件にする。
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import { verifyBundle } from "./verify";
import type { BundleV1 } from "./types";

it("5000件のチャンクを数秒で確かめる", async () => {
  const dir = new URL("../../public/fixtures/normal/", import.meta.url);
  const b = JSON.parse(readFileSync(fileURLToPath(new URL("bundle.json", dir)), "utf-8")) as BundleV1;
  const pem = readFileSync(fileURLToPath(new URL("../config/test_public.pem", import.meta.url)), "utf-8");
  const chunks = Array.from({ length: 5000 }, (_, i) => b.chunks[i % b.chunks.length]);
  const t0 = performance.now();
  const r = await verifyBundle({ ...b, chunks }, { expectedPem: pem, fetchFile: async () => null });
  const sec = (performance.now() - t0) / 1000;
  expect(r.reception.activeChunks).toHaveLength(5000);
  expect(sec).toBeLessThan(8);
}, 30_000);
