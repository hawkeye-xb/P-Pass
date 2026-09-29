// REL-02: 更新通道代理（Cloudflare Worker）——test 通道的 manifest 源。
//
//   GET /manifest?channel=test    → 滚动 prerelease `test-channel` 的 manifest.json
//   GET /manifest?channel=stable  → 代理 GitHub latest 的 manifest.json
//                                    （仅测试对照用；stable 客户端保持
//                                    直连 GitHub 原 URL，一个字节不动）
//
// REL-07：test 通道不再调 GitHub API。release.yml 每次 test 发布后把
// 已签名的 manifest.json 覆盖进固定的滚动 prerelease `test-channel`；本
// Worker 只下载这一个静态文件——没有 API 匿名限流（60/h/IP），也不需要
// GH_TOKEN。此前 latestPrereleaseTag() 在 API 限流（403/429）时返回 null，
// 被报成 404「没有 test release」，客户端静默当作无更新。
//
// 现在的角色：**旧版客户端兼容层**。新版 Android 直读
// releases/download/test-channel/manifest.json；桌面壳仍经本 Worker
// （webview 跨域 fetch 需要 Access-Control-Allow-Origin，GitHub 下载
// 链接不带）。退役条件：桌面壳改走原生 HTTP（或不再需要 CORS），且指向
// 本 Worker 的旧 Android 构建已全部升级。
//
// 响应语义：
//   200 — manifest 字节原样透传（签名随字节不变，客户端验签零改动）。
//   404 {"error":"no test release"} — 上游明确 404：test-channel 指针还不存在
//         （首次 test 发布前），或 test tag 留 draft 未 publish（指针不动）。
//   502 {"error":"upstream manifest <status>"|"upstream manifest fetch failed: …"}
//         — 其它非 2xx / 网络异常；上游给了 Retry-After 就透传。
//   错误响应一律 Cache-Control: no-store，绝不写进 Cache API。
//
// 缓存：成功响应按 channel 缓存 300s（Cache API），客户端命中不碰上游。
const REPO = "hawkeye-xb/P-Pass";
const TEST_CHANNEL_MANIFEST_URL = `https://github.com/${REPO}/releases/download/test-channel/manifest.json`;
const STABLE_MANIFEST_URL = `https://github.com/${REPO}/releases/latest/download/manifest.json`;
const FRESH_TTL_S = 300;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname !== "/manifest") {
      return json({ error: "not found" }, 404);
    }
    const channel = url.searchParams.get("channel") ?? "stable";
    if (channel !== "stable" && channel !== "test") {
      return json({ error: "bad channel" }, 400);
    }

    // 按 channel 缓存：客户端命中直接返回，不碰上游。
    const cacheKey = new Request(`https://ppass-update-cache/${channel}`, { method: "GET" });
    const cached = await caches.default.match(cacheKey);
    if (cached) return cached;

    const manifestUrl = channel === "test" ? TEST_CHANNEL_MANIFEST_URL : STABLE_MANIFEST_URL;
    let upstream;
    try {
      upstream = await fetch(manifestUrl, {
        headers: { "User-Agent": "ppass-update-worker" },
        redirect: "follow",
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return json({ error: `upstream manifest fetch failed: ${msg}` }, 502);
    }
    if (!upstream.ok) {
      if (channel === "test" && upstream.status === 404) {
        return json({ error: "no test release" }, 404);
      }
      const extra = {};
      const ra = upstream.headers.get("retry-after");
      if (ra) extra["Retry-After"] = ra;
      return json({ error: `upstream manifest ${upstream.status}` }, 502, extra);
    }

    const out = new Response(await upstream.arrayBuffer(), {
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": `public, max-age=${FRESH_TTL_S}`,
        ...CORS,
      },
    });
    ctx.waitUntil(caches.default.put(cacheKey, out.clone()));
    return out;
  },
};

// 桌面壳（Tauri webview）跨域 fetch 本 Worker：不带 ACAO 时 fetch 直接
// reject，连状态码都读不到。内容是公开 JSON，放开 * 无风险。
const CORS = { "Access-Control-Allow-Origin": "*" };

function json(obj, status, extra = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...CORS, ...extra },
  });
}
