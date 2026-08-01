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

async function postBatch(batch: unknown): Promise<Response> {
  return SELF.fetch("https://telemetry.local/", {
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

  it("toDataPoint: doubles carry ts + numeric fields only", () => {
    const { ae, calls } = recordingAE();
    ingest(ae, [VALID_BATCH[0]]);
    const doubles = (calls[0] as { doubles?: number[] }).doubles ?? [];
    expect(doubles).toContain(COMMON.ts);
    expect(doubles).toContain(462);
    // strings/bools must NOT leak into doubles
    expect(doubles.some((d) => typeof d !== "number")).toBe(false);
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
    const r = await SELF.fetch("https://telemetry.local/", {
      method: "POST",
      body: "this is not json",
    });
    expect(r.status).toBe(400);
  });

  it("oversized body → 413", async () => {
    const big = "x".repeat(MAX_BATCH_BYTES + 1);
    const r = await SELF.fetch("https://telemetry.local/", {
      method: "POST",
      body: JSON.stringify({ filler: big }),
    });
    expect(r.status).toBe(413);
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
