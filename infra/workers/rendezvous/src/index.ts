/**
 * P-Pass rendezvous Worker (T-060) — short-code one-time envelope exchange.
 *
 * Routes:
 *   POST /code          body {code_hash, sealed} → 201 | 400 | 409 (hash already live) | 429
 *   GET  /code/:hash    → 200 {sealed} (read-once) | 404 | 410 | 400 | 429
 *   GET  /              health check
 *
 * `code_hash` is the SHA-256 hex (64 chars) of the 6-digit code string
 * (UTF-8, zero-padded). `sealed` is an opaque base64url envelope — the server
 * stores and returns it verbatim and never parses it.
 *
 * Cross-language contract: clients (Kotlin / Rust daemon) MUST use the same
 * hash + envelope conventions — this file is the server-side source of truth.
 */

import { CodeStore, CODE_HASH_RE, MAX_SEALED_BYTES } from "./code-store";
import type { Env } from "./code-store";

// The Durable Object must be exported from the entry so the runtime can find
// it (vitest pool pins its export type via additionalExports in vitest.config).
export { CodeStore } from "./code-store";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

const GLOBAL_DO = "global";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    // Cloudflare sets CF-Connecting-IP at the edge; "unknown" only when absent.
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";

    if (url.pathname === "/" && request.method === "GET") {
      return json({ ok: true, service: "ppass-rendezvous" });
    }

    const store = env.CODE_STORE.get(env.CODE_STORE.idFromName(GLOBAL_DO));

    if (url.pathname === "/code" && request.method === "POST") {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid_json" }, 400);
      }
      const b = body as { code_hash?: unknown; sealed?: unknown };
      if (typeof b.code_hash !== "string" || !CODE_HASH_RE.test(b.code_hash)) {
        return json({ error: "bad_code_hash" }, 400);
      }
      if (
        typeof b.sealed !== "string" ||
        b.sealed.length === 0 ||
        b.sealed.length > MAX_SEALED_BYTES
      ) {
        return json({ error: "bad_sealed" }, 400);
      }
      return store.post(b.code_hash, b.sealed, ip);
    }

    if (url.pathname.startsWith("/code/") && request.method === "GET") {
      const codeHash = url.pathname.slice("/code/".length);
      if (!CODE_HASH_RE.test(codeHash)) {
        return json({ error: "bad_code_hash" }, 400);
      }
      return store.get(codeHash, ip);
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
