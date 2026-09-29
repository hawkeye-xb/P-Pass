// REL-07: update Worker 的错误/缓存语义单测——零依赖，node:test + fetch/caches mock。
//
// 跑法：just workers-update-test（= node --test infra/workers/update/test/）。
// index.ts 本身不含类型注解，Node 内建 type stripping 直接加载；
// CI 用 node 24（ci-workers.yml 的 test job）。
import { beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.ts";

const TEST = "https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/manifest.json";
const LATEST = "https://github.com/hawkeye-xb/P-Pass/releases/latest/download/manifest.json";
const MANIFEST = JSON.stringify({ version: "0.6.0-test.2", platforms: {} });

let routes; // url → () => Response | throws
let calls; // fetched urls
let store; // cache key url → Response
let puts; // cache key urls written

beforeEach(() => {
  routes = new Map();
  calls = [];
  store = new Map();
  puts = [];
  globalThis.fetch = async (input) => {
    const u = typeof input === "string" ? input : input.url;
    calls.push(u);
    const r = routes.get(u);
    if (!r) throw new Error(`unexpected fetch ${u}`);
    return r();
  };
  globalThis.caches = {
    default: {
      async match(req) {
        const r = store.get(req.url);
        return r ? r.clone() : undefined;
      },
      async put(req, resp) {
        puts.push(req.url);
        store.set(req.url, resp.clone());
      },
    },
  };
});

async function call(channel = "test") {
  const pending = [];
  const ctx = { waitUntil: (p) => pending.push(p) };
  const resp = await worker.fetch(
    new Request(`https://update.example/manifest?channel=${channel}`),
    {},
    ctx,
  );
  await Promise.all(pending);
  return resp;
}

describe("test 通道：读滚动 prerelease 的静态文件，不调 GitHub API", () => {
  it("200 → 原样透传 + ACAO，写缓存；只 fetch test-channel 文件", async () => {
    routes.set(TEST, () => new Response(MANIFEST));
    const r = await call();
    assert.equal(r.status, 200);
    assert.equal(await r.text(), MANIFEST);
    assert.equal(r.headers.get("Access-Control-Allow-Origin"), "*");
    assert.deepEqual(calls, [TEST]);
    assert.ok(!calls.some((u) => u.includes("api.github.com")));
    assert.deepEqual(puts, ["https://ppass-update-cache/test"]);
  });

  it("上游 404（指针还不存在）→ 404 no test release，no-store，不写缓存", async () => {
    routes.set(TEST, () => new Response("Not Found", { status: 404 }));
    const r = await call();
    assert.equal(r.status, 404);
    assert.deepEqual(await r.json(), { error: "no test release" });
    assert.equal(r.headers.get("Cache-Control"), "no-store");
    assert.deepEqual(puts, []);
  });

  it("上游 503 带 retry-after → 502 upstream manifest 503 + 透传 Retry-After，不写缓存", async () => {
    routes.set(TEST, () => new Response("", { status: 503, headers: { "retry-after": "30" } }));
    const r = await call();
    assert.equal(r.status, 502);
    assert.deepEqual(await r.json(), { error: "upstream manifest 503" });
    assert.equal(r.headers.get("Retry-After"), "30");
    assert.equal(r.headers.get("Cache-Control"), "no-store");
    assert.deepEqual(puts, []);
  });

  it("上游 403/429（限流不是「没有 release」）→ 502，不写缓存", async () => {
    for (const status of [403, 429]) {
      routes.set(TEST, () => new Response("", { status }));
      const r = await call();
      assert.equal(r.status, 502, `status ${status}`);
    }
    assert.deepEqual(puts, []);
  });

  it("网络异常 → 502，不抛到运行时、不写缓存", async () => {
    routes.set(TEST, () => {
      throw new TypeError("network down");
    });
    const r = await call();
    assert.equal(r.status, 502);
    assert.match((await r.json()).error, /^upstream manifest fetch failed/);
    assert.deepEqual(puts, []);
  });

  it("错误之后上游恢复 → 立即拿到新值（错误没被缓存钉住）", async () => {
    routes.set(TEST, () => new Response("", { status: 500 }));
    assert.equal((await call()).status, 502);
    routes.set(TEST, () => new Response(MANIFEST));
    const r = await call();
    assert.equal(r.status, 200);
    assert.equal(await r.text(), MANIFEST);
  });

  it("fresh 命中不碰上游", async () => {
    routes.set(TEST, () => new Response(MANIFEST));
    await call();
    calls = [];
    assert.equal((await call()).status, 200);
    assert.deepEqual(calls, []);
  });
});

describe("stable 与路由（语义不变）", () => {
  it("stable 代理 latest", async () => {
    routes.set(LATEST, () => new Response(MANIFEST));
    const r = await call("stable");
    assert.equal(r.status, 200);
    assert.deepEqual(calls, [LATEST]);
  });

  it("stable 上游 404 仍是 502（不借用 test 的 no test release）", async () => {
    routes.set(LATEST, () => new Response("", { status: 404 }));
    const r = await call("stable");
    assert.equal(r.status, 502);
    assert.deepEqual(await r.json(), { error: "upstream manifest 404" });
    assert.deepEqual(puts, []);
  });

  it("未知路径 404 / 未知 channel 400", async () => {
    const ctx = { waitUntil() {} };
    assert.equal((await worker.fetch(new Request("https://u.example/x"), {}, ctx)).status, 404);
    assert.equal((await call("nightly")).status, 400);
  });
});
