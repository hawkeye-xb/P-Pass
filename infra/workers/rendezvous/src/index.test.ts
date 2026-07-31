import { SELF } from "cloudflare:test";
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
