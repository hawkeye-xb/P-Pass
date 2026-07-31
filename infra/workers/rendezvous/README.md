# infra/workers/rendezvous

Short-code rendezvous (T-060): a Cloudflare Worker + Durable Object that
exchanges one-time sealed envelopes for **remote pairing** (family members who
can't scan a QR). Part of the "everything self-hostable" cloud layer — the
official instance is free-tier CF; self-hosters run their own via
`infra/selfhost` (T-063).

短码会合服务（T-060）：Cloudflare Worker + Durable Object，为**异地配对**（扫不了
二维码的家人）做一次性信封交换。云端组件全部可自建——官方实例跑 CF 免费档，自建者
用 `infra/selfhost`（T-063）跑自己的。

## API

| Route | Method | Body / param | Responses |
|---|---|---|---|
| `/code` | POST | `{code_hash, sealed}` | 201 created · 400 bad payload · 429 rate limited |
| `/code/:hash` | GET | — | 200 `{sealed}` (read-once) · 404 never existed · 410 already consumed / expired · 400 · 429 |
| `/` | GET | — | 200 health `{ok, service}` |

- `code_hash` — SHA-256 hex (64 chars) of the 6-digit code string (UTF-8,
  zero-padded). **Cross-language contract**: Kotlin and Rust clients must hash
  exactly this way.
- `sealed` — opaque base64url envelope (≤ 2048 bytes). The server stores and
  returns it verbatim and never parses it: the NodeId inside is protected
  client-side (envelope encrypted with a key derived from the code).
- TTL 600 s. Read-once (second read → 410). Wrong-lookup gate: 5 failed lookups
  from one IP per minute block that IP (429) until the window rolls over.
  Rate limits: POST 10/min/IP, GET 30/min/IP.

`code_hash` 为 6 位短码字符串（UTF-8，前置补零）的 SHA-256 十六进制（64 字符）。
**跨语言契约**：Kotlin 与 Rust 客户端必须按此方式哈希。`sealed` 为不透明 base64url
信封（≤2048 字节），服务器原样存取、从不解析——信封内的 NodeId 由客户端保护
（用短码派生密钥加密）。TTL 600 秒；一次性读取（二次读 → 410）；错误查询闸门：
同一 IP 一分钟内 5 次失败查询即封禁该 IP 至窗口翻转（429）。限频：POST 10/min/IP，
GET 30/min/IP。

## Client flow (remote pairing)

1. Desktop (owner) generates a 6-digit code, encrypts its NodeId into a sealed
   envelope with a key derived from the code, and `POST /code`.
2. The remote phone receives the code out-of-band (voice/SMS), hashes it, and
   `GET /code/<hash>` → gets the envelope → decrypts → NodeId → proceeds with
   the normal `pair.request` flow.
3. The server can never link the envelope to a pairing attempt (read-once) nor
   read the NodeId (client-side encryption); TTL + rate limits bound brute force
   over the 10^6 code space.

客户端流程（异地配对）：桌面端生成 6 位短码 → 用短码派生密钥把 NodeId 加密成信封 →
`POST /code`；异地家人通过语音/短信拿到短码 → 哈希 → `GET /code/<hash>` 取信封 →
解密得 NodeId → 走常规 `pair.request` 配对。服务器既无法把信封关联到某次配对
（一次性读取），也无法读取 NodeId（客户端加密）；TTL + 限频封住 10^6 空间的爆破。

## Local dev & test

```bash
npm install
npm test          # vitest: real Worker + DO in Miniflare (7 tests)
npm run typecheck
npm run dev       # wrangler dev
```

`wrangler.toml` is a committed placeholder (no real account) — `wrangler dev`
and vitest never need one. Production deploy config (account_id, routes, staging
vs prod) lives in the private ops repo (`ppf-ops/deploy/workers.prod.toml`),
per the isolation plan §2. Public-repo CI never touches production.

`wrangler.toml` 为占位配置（无真实 account_id）——`wrangler dev` 与 vitest 均无需。
生产部署配置（真实 account_id、路由、staging/prod）位于私有仓 `ppf-ops/deploy/`
，按隔离方案 §2：公开仓 CI 永不接触生产。

## Layout / scale notes

Single DO instance (`idFromName("global")`) holds all codes — one code per
pairing attempt, trivially within free-tier limits. Rate-limit counters are
in-memory: a single global instance keeps them consistent, and a restart only
resets abuse counters (acceptable). DO storage TTL was removed from the CF
platform, so codes rely on explicit expiry checks + an alarm sweep instead.

单 DO 实例（`idFromName("global")`）承载全部短码——每次配对一个，免费档绰绰有余。
限频计数在内存中：单实例保证一致性，重启仅重置滥用计数（可接受）。CF 平台已移除
DO 存储 TTL，短码靠显式过期检查 + alarm 清扫。
