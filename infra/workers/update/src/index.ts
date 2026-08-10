// REL-02: 更新通道代理（Cloudflare Worker）——test 通道的 manifest 源。
//
// 为什么客户端不直接打 GitHub API：未认证限流 60 次/小时/IP，客户端
// （Android/桌面壳）直连迟早撞墙。解析「最新 prerelease」的逻辑放
// Worker 端，客户端只 fetch 一个静态 URL（自己域名，无限流）。
//
//   GET /manifest?channel=test    → 最新 prerelease 的 manifest.json
//   GET /manifest?channel=stable  → 代理 GitHub latest 的 manifest.json
//                                    （仅测试对照用；stable 客户端保持
//                                    直连 GitHub 原 URL，一个字节不动）
//
// 反证（卡面）：test 通道包故意不 publish（留 draft）→ Worker 在 GitHub
// API 里找不到 prerelease → 404 → 客户端静默无更新。
//
// 缓存：按 channel 缓存 300s（Cache API）——客户端命中不碰 GitHub；
// GitHub API 每 5 分钟最多打一次/边缘节点，限额绰绰有余。可选 secret
// GH_TOKEN（ppf-ops 生产配置里给）把限额从 60/h 提到 5000/h。
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

    let manifestUrl;
    if (channel === "test") {
      const tag = await latestPrereleaseTag(env);
      if (!tag) return json({ error: "no test release" }, 404);
      manifestUrl = `https://github.com/hawkeye-xb/P-Pass/releases/download/${tag}/manifest.json`;
    } else {
      manifestUrl =
        "https://github.com/hawkeye-xb/P-Pass/releases/latest/download/manifest.json";
    }

    const upstream = await fetch(manifestUrl, {
      headers: { "User-Agent": "ppass-update-worker" },
      redirect: "follow",
    });
    if (!upstream.ok) return json({ error: `upstream ${upstream.status}` }, 502);

    // 原样透传 manifest 字节——签名（tauri signer，manifest 内嵌 per-artifact
    // signature）随字节不变，客户端验签逻辑一根手指都不用动。
    const body = await upstream.arrayBuffer();
    const out = new Response(body, {
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "public, max-age=300",
      },
    });
    ctx.waitUntil(caches.default.put(cacheKey, out.clone()));
    return out;
  },
};

/** GitHub API 里找最新 prerelease 的 tag；没有（留 draft/未 publish）→ null。 */
async function latestPrereleaseTag(env) {
  const headers = { "User-Agent": "ppass-update-worker" };
  if (env.GH_TOKEN) headers.Authorization = `Bearer ${env.GH_TOKEN}`;
  const resp = await fetch(
    "https://api.github.com/repos/hawkeye-xb/P-Pass/releases?per_page=10",
    { headers },
  );
  if (!resp.ok) return null;
  const releases = await resp.json();
  const pre = releases.find((r) => r.prerelease === true);
  return pre?.tag_name ?? null;
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
