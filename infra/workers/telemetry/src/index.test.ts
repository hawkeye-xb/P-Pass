import { SELF } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import { ingest, MAX_BATCH_BYTES, toDataPoint, type AnalyticsEngineLike } from "./schema";

// T-061 acceptance: 合法四事件入库调用、非法载荷 400。
// - ingest() is unit-tested with a recording fake AE (asserts the writes).
// - The HTTP layer is integration-tested via SELF against the real Worker.

const COMMON = { anon_id: "a".repeat(32), ver: "0.1.0", ts: 1_800_000_000_000 };

const VALID_BATCH = [
  { event: "conn", path: "relay", ipver: "v4", ms: 462, fail_stage: null, country: null, isp_hash: null, ...COMMON },
  { event: "backup_session", files: 12, bytes: 34_567_890, dur_s: 45, resumed: false, trigger: "periodic", ...COMMON },
  { event: "first_byte", ms: 210, kind: "thumb", ...COMMON },
  { event: "daemon_alive", uptime_h: 72, os: "macos", ...COMMON },
];

function recordingAE(): { ae: AnalyticsEngineLike; calls: unknown[] } {
  const calls: unknown[] = [];
  const ae: AnalyticsEngineLike = {
    writeDataPoint(point) {
      calls.push(point);
    },
  };
  return { ae, calls };
}

async function postBatch(batch: unknown, path = "/ingest"): Promise<Response> {
  return SELF.fetch(`https://telemetry.local${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(batch),
  });
}

describe("schema + ingest (unit)", () => {
  it("合法四事件: one Analytics Engine write per event, lossless", () => {
    const { ae, calls } = recordingAE();
    const result = ingest(ae, VALID_BATCH);
    expect(result).toEqual({ ok: true, accepted: 4 });
    expect(calls).toHaveLength(4);
    // indexes = [event type] for GROUP BY; blob = full event JSON
    expect(calls.map((c) => (c as { indexes?: string[] }).indexes)).toEqual([
      ["conn"],
      ["backup_session"],
      ["first_byte"],
      ["daemon_alive"],
    ]);
    for (const c of calls) {
      const blob = (c as { blobs?: string[] }).blobs?.[0];
      expect(JSON.parse(blob ?? "")).toBeTruthy();
      expect((c as { doubles?: number[] }).doubles?.length).toBeGreaterThan(0);
    }
  });

  it("toDataPoint: doubles use FIXED per-event columns (T-061b)", () => {
    // full backup_session: [ts, files, bytes, dur_s]
    const { ae, calls } = recordingAE();
    ingest(ae, [VALID_BATCH[1]]);
    expect((calls[0] as { doubles?: number[] }).doubles).toEqual([
      COMMON.ts,
      12,
      34_567_890,
      45,
    ]);
    // conn: [ts, ms]
    const { ae: ae2, calls: calls2 } = recordingAE();
    ingest(ae2, [VALID_BATCH[0]]);
    expect((calls2[0] as { doubles?: number[] }).doubles).toEqual([
      COMMON.ts,
      462,
    ]);
    // daemon_alive: [ts, uptime_h]
    const { ae: ae3, calls: calls3 } = recordingAE();
    ingest(ae3, [VALID_BATCH[3]]);
    expect((calls3[0] as { doubles?: number[] }).doubles).toEqual([
      COMMON.ts,
      72,
    ]);
    // strings/bools must NOT leak into doubles
    for (const c of [...calls, ...calls2, ...calls3]) {
      expect((c as { doubles?: number[] }).doubles?.every((d) => typeof d === "number")).toBe(true);
    }
  });

  it("toDataPoint: absent optional fields do NOT shift columns (T-061b)", () => {
    // conn WITHOUT fail_stage/country/isp_hash (all optional) must still be
    // [ts, ms] — old Object.entries order would drop columns on absence.
    const sparse = {
      event: "conn",
      path: "lan",
      ipver: "v6",
      ms: 99,
      ...COMMON,
    };
    const { ae, calls } = recordingAE();
    ingest(ae, [sparse]);
    expect((calls[0] as { doubles?: number[] }).doubles).toEqual([
      COMMON.ts,
      99,
    ]);
  });

  it("unknown event type is rejected", () => {
    const { ae, calls } = recordingAE();
    const result = ingest(ae, [{ event: "spy_me", ...COMMON }]);
    expect(result.ok).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("unknown extra field is rejected (strict schemas catch client drift)", () => {
    const { ae, calls } = recordingAE();
    const result = ingest(ae, [{ ...VALID_BATCH[0], surprise: 1 }]);
    expect(result.ok).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("wrong field type is rejected", () => {
    const { ae, calls } = recordingAE();
    const result = ingest(ae, [{ ...VALID_BATCH[1], files: "twelve" }]);
    expect(result.ok).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("empty batch is rejected", () => {
    const { ae, calls } = recordingAE();
    expect(ingest(ae, []).ok).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("oversized batch (over 100 events) is rejected", () => {
    const { ae, calls } = recordingAE();
    const batch = Array.from({ length: 101 }, () => VALID_BATCH[0]);
    expect(ingest(ae, batch).ok).toBe(false);
    expect(calls).toHaveLength(0);
  });
});

describe("HTTP layer (integration via SELF)", () => {
  it("valid batch → 200 {accepted: 4}", async () => {
    const r = await postBatch(VALID_BATCH);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ accepted: 4 });
  });

  it("invalid payload → 400", async () => {
    expect((await postBatch({ not: "an array" })).status).toBe(400);
    expect((await postBatch([{ event: "nope", ...COMMON }])).status).toBe(400);
  });

  it("non-JSON body → 400", async () => {
    const r = await SELF.fetch("https://telemetry.local/ingest", {
      method: "POST",
      body: "this is not json",
    });
    expect(r.status).toBe(400);
  });

  it("oversized body → 413", async () => {
    const big = "x".repeat(MAX_BATCH_BYTES + 1);
    const r = await SELF.fetch("https://telemetry.local/ingest", {
      method: "POST",
      body: JSON.stringify({ filler: big }),
    });
    expect(r.status).toBe(413);
  });

  it("POST to non-/ingest path → 404 (T-061b)", async () => {
    // old behaviour: any path accepted the batch; a typo'd URL silently
    // swallowed events. Now only /ingest accepts POSTs.
    expect((await postBatch(VALID_BATCH, "/")).status).toBe(404);
    expect((await postBatch(VALID_BATCH, "/other")).status).toBe(404);
  });

  it("GET / → health", async () => {
    const r = await SELF.fetch("https://telemetry.local/");
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, service: "ppass-telemetry" });
  });
});

// silence unused import warning in some configs
void toDataPoint;
void vi;
