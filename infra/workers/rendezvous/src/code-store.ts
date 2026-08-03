import { DurableObject } from "cloudflare:workers";

/**
 * CodeStore — Durable Object holding short-code → sealed-envelope pairs (T-060).
 *
 * Security model (from the design doc §2.2 / §6) — honest claims (T-060b):
 * - The server stores only `code_hash` (SHA-256 hex of the 6-digit code) and an
 *   opaque `sealed` envelope. It never sees the plaintext code and never parses
 *   the envelope.
 * - **Threat boundary**: this protects the envelope from OUTSIDERS (anyone who
 *   can reach the API or observe transit) — it does NOT protect the envelope
 *   from the operator. The short-code space is only 10^6, so the operator can
 *   dictionary-reverse `code_hash` in milliseconds (precompute a rainbow table
 *   over all 10^6 codes), recover the code, derive the envelope key, and
 *   decrypt. "Server cannot read NodeId" would be false — we do not claim it.
 * - Read-once: a successful GET returns the envelope and deletes it (record
 *   kept as `opened` until the alarm sweep so "read before" is distinguishable
 *   from "never existed"); a second GET for the same hash is 410. Read-once is
 *   an anti-replay property, NOT unlinkability — the operator sees every
 *   request.
 * - Duplicate POST of a live, unconsumed hash → 409. Overwriting an
 *   unconsumed envelope would be decryptable cross-family swap (the envelope
 *   key derives from the code alone, so two families unluckily sharing a code
 *   would swap envelopes); 409 forces the loser to retry with a fresh code.
 * - TTL: 600 s (matching the card's `TTL600s`). Expired codes are rejected with
 *   410 and lazily deleted; an alarm sweep cleans up for hygiene. The alarm is
 *   only (re)set when none exists or the existing one is later than the next
 *   expiry — never pushed forward, so steady traffic cannot starve the sweep.
 * - Abuse ("错 5 次销毁"): per-IP rate limits (POST 10/min, GET 30/min) plus a
 *   wrong-lookup counter — 5 failed lookups from one IP within a minute block
 *   that IP until the window rolls over. Counters are in-memory: the "global"
 *   DO instance is a single process-wide point so they stay consistent, and a
 *   restart only resets abuse counters (acceptable). DO storage TTL was removed
 *   from the platform, so memory also avoids unbounded storage growth. Note a
 *   wrong attempt can only be observed as "hash not found" (the code itself
 *   never leaves the client), so the counter is per-IP, not per-code — TTL +
 *   read-once + rate limits are what actually bound brute force over the 10^6
 *   code space.
 *
 * Layout decision: a single DO instance named "global" holds every code. Volume
 * is one code per pairing attempt; if that ever grows, shard by hash prefix.
 */

export const TTL_SECONDS = 600;
export const MAX_SEALED_BYTES = 2048;
export const CODE_HASH_RE = /^[0-9a-f]{64}$/;

export interface StoredCode {
  sealed: string;
  expiresAt: number; // epoch seconds
  opened: boolean; // consumed by a successful read (read-once)
}

export const RATE_LIMITS = {
  post: { limit: 10, windowSec: 60 },
  get: { limit: 30, windowSec: 60 },
  wrong: { limit: 5, windowSec: 60 },
} as const;

export type RateKind = keyof typeof RATE_LIMITS;

const RATE_WINDOW_SEC = 60;

function windowStart(nowSec: number): number {
  return Math.floor(nowSec / RATE_WINDOW_SEC) * RATE_WINDOW_SEC;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

export class CodeStore extends DurableObject<Env> {
  /** In-memory per-IP rate counters: `${kind}:${ip}:${windowStart}` → count. */
  private readonly rateCounters = new Map<string, number>();

  /** Increment a per-IP counter for `kind`; returns true while under the limit. */
  private bump(ip: string, kind: RateKind, nowSec: number): boolean {
    this.sweepRateCounters(nowSec);
    const { limit } = RATE_LIMITS[kind];
    const key = `${kind}:${ip}:${windowStart(nowSec)}`;
    const count = (this.rateCounters.get(key) ?? 0) + 1;
    if (count > limit) {
      return false;
    }
    this.rateCounters.set(key, count);
    return true;
  }

  private wrongCount(ip: string, nowSec: number): number {
    return this.rateCounters.get(`wrong:${ip}:${windowStart(nowSec)}`) ?? 0;
  }

  /** Bound memory: drop windows older than the previous one once the map grows. */
  private sweepRateCounters(nowSec: number): void {
    if (this.rateCounters.size < 1024) {
      return;
    }
    const cur = windowStart(nowSec);
    for (const key of this.rateCounters.keys()) {
      const win = Number(key.split(":").pop());
      if (win < cur - RATE_WINDOW_SEC) {
        this.rateCounters.delete(key);
      }
    }
  }

  /** POST /code — store a sealed envelope keyed by code_hash. */
  async post(hash: string, sealed: string, ip: string): Promise<Response> {
    const nowSec = Math.floor(Date.now() / 1000);
    if (!this.bump(ip, "post", nowSec)) {
      return json({ error: "rate_limited" }, 429);
    }
    // Duplicate POST of a live, unconsumed hash is a cross-family swap hazard
    // (the envelope key derives from the code alone) → refuse loudly instead of
    // silently overwriting. Consumed (opened) or expired records are free to
    // reuse — they hold no value to anyone.
    const existing = await this.ctx.storage.get<StoredCode>(`code:${hash}`);
    if (existing && !existing.opened && existing.expiresAt > nowSec) {
      return json({ error: "duplicate" }, 409);
    }
    const code: StoredCode = { sealed, expiresAt: nowSec + TTL_SECONDS, opened: false };
    await this.ctx.storage.put(`code:${hash}`, code);
    // Hygiene sweep for this code's expiry — but never push an existing alarm
    // later than it already is (steady traffic would keep postponing the sweep
    // and consumed envelopes would linger forever).
    const nextAlarmMs = (nowSec + TTL_SECONDS + 1) * 1000;
    const pending = await this.ctx.storage.getAlarm();
    if (pending === null || pending > nextAlarmMs) {
      await this.ctx.storage.setAlarm(nextAlarmMs);
    }
    return json({ ok: true }, 201);
  }

  /** GET /code/:hash — read-once retrieval of the sealed envelope. */
  async get(hash: string, ip: string): Promise<Response> {
    const nowSec = Math.floor(Date.now() / 1000);
    if (!this.bump(ip, "get", nowSec)) {
      return json({ error: "rate_limited" }, 429);
    }
    // Wrong-attempt gate: 5 failed lookups in a window cut the IP off.
    if (this.wrongCount(ip, nowSec) >= RATE_LIMITS.wrong.limit) {
      return json({ error: "rate_limited" }, 429);
    }
    const code = await this.ctx.storage.get<StoredCode>(`code:${hash}`);
    if (!code) {
      this.bump(ip, "wrong", nowSec);
      return json({ error: "not_found" }, 404);
    }
    if (code.expiresAt <= nowSec) {
      await this.ctx.storage.delete(`code:${hash}`);
      return json({ error: "gone" }, 410);
    }
    // Read-once: an already-consumed code is 410 (record kept until the alarm
    // sweep so "read before" is distinguishable from "never existed").
    if (code.opened) {
      return json({ error: "gone" }, 410);
    }
    code.opened = true;
    await this.ctx.storage.put(`code:${hash}`, code);
    return json({ sealed: code.sealed });
  }

  /**
   * Alarm: sweep expired codes and re-arm at the next earliest expiry.
   * Framework hook — the runtime calls `alarm()` with no useful arg; the
   * clock is read from the wall by default.
   */
  async alarm(): Promise<void> {
    await this.sweep(Math.floor(Date.now() / 1000));
  }

  /**
   * Sweep implementation. `nowSec` is injectable for tests (vitest's
   * runInDurableObject does not forward fake timers to the DO, so the sweep
   * test pins the clock explicitly — same seam as the Rust `with_clock`).
   */
  async sweep(nowSec: number): Promise<void> {
    const list = await this.ctx.storage.list<StoredCode>({ prefix: "code:" });
    let nextExpiryMs: number | null = null;
    for (const [key, value] of list) {
      if (value.expiresAt <= nowSec) {
        await this.ctx.storage.delete(key);
      } else if (nextExpiryMs === null || value.expiresAt * 1000 < nextExpiryMs) {
        nextExpiryMs = value.expiresAt * 1000;
      }
    }
    // Re-arm at the next earliest expiry so later codes don't linger forever
    // (a sweep consumed only the earliest; the rest need a future pass).
    if (nextExpiryMs !== null) {
      await this.ctx.storage.setAlarm(nextExpiryMs + 1000);
    }
  }
}

export interface Env {
  CODE_STORE: DurableObjectNamespace<CodeStore>;
}
