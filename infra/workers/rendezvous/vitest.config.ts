import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      // CodeStore is exported from the entry; pin its export type so the pool
      // exposes it as a Durable Object (not a plain WorkerEntrypoint).
      additionalExports: { CodeStore: "DurableObject" },
    }),
  ],
});
