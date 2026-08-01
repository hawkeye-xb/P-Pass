/**
 * P-Pass telemetry intake Worker (T-061).
 *
 * POST  /  body: JSON array of telemetry events (client wire format,
 *              crates/daemon/src/telemetry.rs) → 200 {accepted} | 400 | 413
 * GET   /  health check
 *
 * Strict zod validation per 手册 §8 dictionary; unknown event types or fields
 * are rejected (400). Oversized bodies are rejected (413). Valid batches are
 * written to Analytics Engine (`TELEMETRY` binding), indexed by event type.
 */

import { AnalyticsEngineDataset } from "@cloudflare/workers-types";
import { ingest, MAX_BATCH_BYTES } from "./schema";

export interface Env {
  TELEMETRY: AnalyticsEngineDataset;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/" && request.method === "GET") {
      return json({ ok: true, service: "ppass-telemetry" });
    }

    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }

    // Size gate first: never buffer an unbounded body.
    const declared = Number(request.headers.get("content-length") ?? 0);
    if (declared > MAX_BATCH_BYTES) {
      return json({ error: "too_large" }, 413);
    }
    const body = await request.arrayBuffer();
    if (body.byteLength > MAX_BATCH_BYTES) {
      return json({ error: "too_large" }, 413);
    }

    let batch: unknown;
    try {
      batch = JSON.parse(new TextDecoder().decode(body));
    } catch {
      return json({ error: "invalid_json" }, 400);
    }

    const result = ingest(env.TELEMETRY, batch);
    if (!result.ok) {
      return json({ error: "invalid_batch" }, 400);
    }
    return json({ accepted: result.accepted });
  },
} satisfies ExportedHandler<Env>;
