/**
 * Telemetry schema + ingestion (T-061 / T-061b).
 *
 * Wire format comes from the Rust client (crates/daemon/src/telemetry.rs,
 * T-035): a JSON ARRAY of flat event objects. Every object carries the common
 * fields `anon_id` / `ver` / `ts` (epoch ms) plus an `event` discriminator and
 * the event-specific fields per 手册 §8. The Worker's job: strict schema
 * validation (zod, unknown fields AND unknown event types rejected — drift
 * between client and server must fail loudly, not silently) → Analytics
 * Engine write.
 *
 * Analytics Engine mapping (documented, queryable):
 * - indexes: [event]            → GROUP BY event type
 * - doubles: FIXED per-event-type columns (T-061b) — double1=ts, then
 *   ms|files|uptime_h, bytes, dur_s; absent optional fields are zero-padded
 *   so columns never shift. See toDataPoint.
 * - blobs:   the full event JSON (self-describing, lossless)
 */

import { z } from "zod";

export const MAX_BATCH_BYTES = 1_048_576; // 1 MiB hard cap ("拒绝超长")
export const MAX_EVENTS_PER_BATCH = 100;

const commonFields = {
  anon_id: z.string().min(8).max(64),
  ver: z.string().min(1).max(32),
  ts: z.number().int().nonnegative(),
};

const connSchema = z
  .object({
    event: z.literal("conn"),
    path: z.enum(["lan", "direct", "relay"]),
    ipver: z.string().min(1).max(8),
    ms: z.number().int().nonnegative(),
    fail_stage: z.string().max(32).nullable().optional(),
    country: z.string().max(8).nullable().optional(),
    isp_hash: z.string().max(64).nullable().optional(),
    ...commonFields,
  })
  .strict();

const backupSessionSchema = z
  .object({
    event: z.literal("backup_session"),
    files: z.number().int().nonnegative(),
    bytes: z.number().int().nonnegative(),
    dur_s: z.number().int().nonnegative(),
    resumed: z.boolean(),
    trigger: z.enum(["periodic", "uidt"]),
    ...commonFields,
  })
  .strict();

const firstByteSchema = z
  .object({
    event: z.literal("first_byte"),
    ms: z.number().int().nonnegative(),
    kind: z.enum(["thumb", "blob"]),
    ...commonFields,
  })
  .strict();

// Note: the client sends a single `ver` (the daemon's CARGO_PKG_VERSION) — the
// Rust code inserts the common `ver` AFTER the event fields, overwriting any
// event-specific one. So no event-level `ver` here; commonFields covers it.
const daemonAliveSchema = z
  .object({
    event: z.literal("daemon_alive"),
    uptime_h: z.number().int().nonnegative(),
    os: z.string().min(1).max(32),
    ...commonFields,
  })
  .strict();

export const batchSchema = z
  .array(
    z.discriminatedUnion("event", [
      connSchema,
      backupSessionSchema,
      firstByteSchema,
      daemonAliveSchema,
    ]),
  )
  .min(1)
  .max(MAX_EVENTS_PER_BATCH);

export type ParsedEvent = z.infer<(typeof batchSchema)["element"]>;

export interface DataPoint {
  indexes?: string[];
  doubles?: number[];
  blobs?: string[];
}

/**
 * Exhaustiveness guard (T-061b-fix): the switch in toDataPoint must cover
 * every event type in batchSchema. If someone adds a new event schema to the
 * discriminated union but forgets the toDataPoint case, `event.event` in the
 * default branch stops being `never` and this call fails to compile — a loud
 * type error instead of a silent `doubles = undefined` in production.
 */
function assertNever(value: never): never {
  throw new Error(`unhandled telemetry event type: ${String(value)}`);
}

/** Lossless, queryable mapping: full event as blob + numerics as doubles.
 *
 * T-061b: doubles use a FIXED per-event-type column layout. The old
 * implementation iterated `Object.entries(event)` in client field order, so
 * an absent optional field shifted every subsequent column (e.g. `conn`
 * without `fail_stage` landed in a different double position) — `double2`
 * had no stable meaning and queries broke silently. Now each event type maps
 * to a fixed double array with zero-padding for absent optional fields:
 *
 *   conn          → [ts, ms]
 *   backup_session→ [ts, files, bytes, dur_s]
 *   first_byte    → [ts, ms]
 *   daemon_alive  → [ts, uptime_h]
 *
 * Column semantics are therefore stable: double1=ts, double2=ms|files|uptime_h,
 * double3=bytes, double4=dur_s. Add new numeric fields at the END of a type's
 * array only.
 */
export function toDataPoint(event: ParsedEvent): DataPoint {
  const t = event.ts;
  let doubles: number[];
  switch (event.event) {
    case "conn":
      doubles = [t, event.ms];
      break;
    case "backup_session":
      doubles = [t, event.files, event.bytes, event.dur_s];
      break;
    case "first_byte":
      doubles = [t, event.ms];
      break;
    case "daemon_alive":
      doubles = [t, event.uptime_h];
      break;
    default:
      return assertNever(event);
  }
  return {
    indexes: [event.event],
    doubles,
    blobs: [JSON.stringify(event)],
  };
}

/** Minimal structural type so tests can inject a recording fake. */
export interface AnalyticsEngineLike {
  writeDataPoint(point: DataPoint): void;
}

export interface IngestResult {
  ok: boolean;
  accepted: number;
}

/**
 * Whole-batch strictness: one invalid event rejects the whole batch with 400
 * (the client drops failed batches anyway — best-effort telemetry, and a loud
 * failure surfaces client/server drift instead of silently losing data).
 */
export function ingest(ae: AnalyticsEngineLike, batch: unknown): IngestResult {
  const parsed = batchSchema.safeParse(batch);
  if (!parsed.success) {
    return { ok: false, accepted: 0 };
  }
  for (const event of parsed.data) {
    ae.writeDataPoint(toDataPoint(event));
  }
  return { ok: true, accepted: parsed.data.length };
}
