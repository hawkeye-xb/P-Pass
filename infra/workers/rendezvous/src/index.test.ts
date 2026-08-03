import { SELF, env, runInDurableObject } from "cloudflare:test";
import { CodeStore } from "./code-store";
import type { Env } from "./code-store";
import { afterEach, describe, expect, it, vi } from "vitest";

// T-060 acceptance: 存取 / 过期 / 5 次销毁 三用例 + 单测绿。
// Every test goes through the real Worker + Durable Object (SELF binding).

const HASH_A = "a".repeat(64); // a stored code
const HASH_B = "b".repeat(64); // another stored code
const WRONG = "c".repeat(64); // never stored → wrong lookup
const SEALED = "eyJub2RlSWQiOiJ0ZXN0LWVudmVsb3BlIn0"; // opaque base64url

async function postCode(hash: string = HASH_A, sealed: string = SEALED): Promise<Response> {
  return SELF.fetch("https://rendezvous.local/code", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code_hash: hash, sealed }),
  });
}

/** Fake only Date — advances the DO's clock without touching timers/I/O. */
function fakeNow(offsetSec: number): () => void {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(Date.now() + offsetSec * 1000));
  return () => vi.useRealTimers();
}

afterEach(() => {
  vi.useRealTimers();
});

describe("rendezvous worker (T-060)", () => {
  it("存取: stores a code and returns the envelope exactly once", async () => {
    const post = await postCode();
    expect(post.status).toBe(201);
    expect(await post.json()).toEqual({ ok: true });

    const got = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(got.status).toBe(200);
    expect(await got.json()).toEqual({ sealed: SEALED });

    // read-once: the second read must be gone
    const again = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(again.status).toBe(410);
  });

  it("存取: distinct hashes are independent", async () => {
    await postCode(HASH_A, SEALED);
    await postCode(HASH_B, "c2Vjb25kLWVudmVsb3Bl");

    const gotB = await SELF.fetch(`https://rendezvous.local/code/${HASH_B}`);
    expect(gotB.status).toBe(200);
    expect(await gotB.json()).toEqual({ sealed: "c2Vjb25kLWVudmVsb3Bl" });

    const gotA = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(gotA.status).toBe(200);
    expect(await gotA.json()).toEqual({ sealed: SEALED });
  });

  it("过期: codes are rejected after the 600 s TTL", async () => {
    const restore = fakeNow(0);
    await postCode();
    // 601 s later the code is expired → 410, and it is gone for good
    fakeNow(601);
    const got = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(got.status).toBe(410);
    const again = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(again.status).toBe(404);
    restore();
  });

  it("5次销毁: five wrong lookups cut the IP off (even for a correct hash)", async () => {
    const restore = fakeNow(120); // fresh rate windows
    await postCode();
    for (let i = 0; i < 5; i++) {
      const r = await SELF.fetch(`https://rendezvous.local/code/${WRONG}`);
      expect(r.status).toBe(404);
    }
    // 6th request: blocked by the wrong-attempt gate before the code is read
    const blocked = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(blocked.status).toBe(429);
    restore();
  });

  it("5次销毁: wrong-window rollover recovers the IP", async () => {
    const restore = fakeNow(180); // fresh windows
    await postCode();
    for (let i = 0; i < 5; i++) {
      const r = await SELF.fetch(`https://rendezvous.local/code/${WRONG}`);
      expect(r.status).toBe(404);
    }
    const blocked = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(blocked.status).toBe(429);
    // Next 60 s window: counters reset, the IP is usable again.
    fakeNow(240); // 180 + 60 → rolls into the next window
    const recovered = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(recovered.status).toBe(200);
    expect(await recovered.json()).toEqual({ sealed: SEALED });
    restore();
  });

  it("限频: POST is limited to 10/min per IP", async () => {
    const restore = fakeNow(240); // fresh rate windows
    for (let i = 0; i < 10; i++) {
      const r = await postCode(`d${i.toString(16)}`.padEnd(64, "0"));
      expect(r.status).toBe(201);
    }
    const eleventh = await postCode(`e`.repeat(64));
    expect(eleventh.status).toBe(429);
    restore();
  });

  it("限频: GET is limited to 30/min per IP", async () => {
    const restore = fakeNow(300); // fresh rate windows
    await postCode();
    for (let i = 0; i < 30; i++) {
      // Alternate reads: 1×200 then 29×410 (read-once) — all count toward the
      // GET budget, none are "wrong" lookups.
      const r = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
      expect([200, 410]).toContain(r.status);
    }
    const thirtyFirst = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(thirtyFirst.status).toBe(429);
    restore();
  });

  it("重复 POST: live unconsumed hash → 409, consumed/expired may be reused", async () => {
    const restore = fakeNow(360); // fresh rate windows
    // First POST lands.
    const first = await postCode(HASH_A, SEALED);
    expect(first.status).toBe(201);
    // Duplicate POST of the same live hash must NOT silently overwrite
    // (cross-family envelope swap hazard) → 409, original preserved.
    const dup = await postCode(HASH_A, "c2Vjb25kLWVudmVsb3Bl");
    expect(dup.status).toBe(409);
    const got = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(got.status).toBe(200);
    expect(await got.json()).toEqual({ sealed: SEALED });
    // Consumed (opened) → hash is free to reuse.
    const again = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(again.status).toBe(410);
    const reopen = await postCode(HASH_A, "c2Vjb25kLWVudmVsb3Bl");
    expect(reopen.status).toBe(201);
    const reopened = await SELF.fetch(`https://rendezvous.local/code/${HASH_A}`);
    expect(reopened.status).toBe(200);
    expect(await reopened.json()).toEqual({ sealed: "c2Vjb25kLWVudmVsb3Bl" });
    restore();
  });

  it("alarm sweep: expired codes are swept and the alarm is re-armed", async () => {
    const store = (env as unknown as Env).CODE_STORE.get(
      (env as unknown as Env).CODE_STORE.idFromName("global"),
    );
    // Directly seed two records with known expiries — no fake-clock coupling
    // (vitest fake timers don't reliably forward into the DO under full-suite
    // runs; seeding + injecting nowSec makes the sweep test deterministic).
    await runInDurableObject(store, async (instance, state) => {
      const now = Math.floor(Date.now() / 1000);
      await state.storage.put(`code:${HASH_A}`, {
        sealed: SEALED,
        expiresAt: now - 1, // already expired
        opened: false,
      });
      await state.storage.put(`code:${HASH_B}`, {
        sealed: "c2Vjb25kLWVudmVsb3Bl",
        expiresAt: now + 300, // still live
        opened: false,
      });
      // Drive the sweep as the runtime would (alarm fires at the earliest
      // expiry). Clock injected explicitly — same seam as the Rust with_clock.
      const inst = instance as unknown as CodeStore;
      await inst.sweep(now);
      const keys = [...(await state.storage.list({ prefix: "code:" })).keys()];
      expect(keys).toContain(`code:${HASH_B}`);
      expect(keys).not.toContain(`code:${HASH_A}`);
      // Re-armed at B's expiry +1s — not pushed forward forever.
      const alarmMs = await state.storage.getAlarm();
      expect(alarmMs).toBe((now + 300 + 1) * 1000);
    });
  });

  it("validation: malformed payloads are rejected with 400", async () => {
    // bad hash
    expect((await postCode("zz")).status).toBe(400);
    // empty sealed
    expect((await postCode(HASH_A, "")).status).toBe(400);
    // oversized sealed
    expect((await postCode(HASH_A, "x".repeat(2049))).status).toBe(400);
    // not JSON at all
    const r = await SELF.fetch("https://rendezvous.local/code", {
      method: "POST",
      body: "not json",
    });
    expect(r.status).toBe(400);
    // bad hash in the URL
    const badUrl = await SELF.fetch("https://rendezvous.local/code/not-hex");
    expect(badUrl.status).toBe(400);
  });

  it("health: GET / answers ok", async () => {
    const r = await SELF.fetch("https://rendezvous.local/");
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, service: "ppass-rendezvous" });
  });
});
