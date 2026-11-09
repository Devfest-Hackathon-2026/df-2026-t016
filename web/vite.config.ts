/// <reference types="vitest/config" />
import { defineConfig } from "vite";

export default defineConfig({
  // 手元で本物の記録を開くときは、/v1 を受付API に転送する（本番は Firebase Hosting の転送）
  server: {
    port: 5173,
    strictPort: true,
    proxy: { "/v1": { target: process.env.API_BASE_URL ?? "https://trace-api-x6vza4wesa-an.a.run.app", changeOrigin: true } },
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
  },
});
