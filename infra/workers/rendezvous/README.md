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
| `/code` | POST | `{code_hash, sealed}` | 201 created · 400 bad payload · 409 hash already live (unconsumed & unexpired — client picks a new code) · 429 rate limited |
| `/code/:hash` | GET | — | 200 `{sealed}` (read-once) · 404 never existed · 410 already consumed / expired · 400 · 429 |
| `/` | GET | — | 200 health `{ok, service}` |

- `code_hash` — SHA-256 hex (64 chars) of the 6-digit code string (UTF-8,
  zero-padded). **Cross-language contract**: Kotlin and Rust clients must hash
  exactly this way.
- `sealed` — opaque base64url envelope (≤ 2048 bytes). The server stores and
  returns it verbatim and never parses it: the NodeId inside is encrypted
  client-side with a key derived from the code.
- TTL 600 s. Read-once (second read → 410). Wrong-lookup gate: 5 failed lookups
  from one IP per minute block that IP (429) until the window rolls over.
  Rate limits: POST 10/min/IP, GET 30/min/IP.
- **Honest threat model (T-060b)**: the code space is only 10^6, so the server
  *operator* can dictionary-reverse `code_hash` in milliseconds and decrypt any
  envelope. This design protects the envelope from **outsiders** (network
  observers, API clients), not from the operator. Read-once is an anti-replay
  property, not unlinkability — the operator sees every request. Do not claim
  otherwise in docs or client code.

`code_hash` 为 6 位短码字符串（UTF-8，前置补零）的 SHA-256 十六进制（64 字符）。
**跨语言契约**：Kotlin 与 Rust 客户端必须按此方式哈希。`sealed` 为不透明 base64url
信封（≤2048 字节），服务器原样存取、从不解析——信封内的 NodeId 由客户端保护
（用短码派生密钥加密）。TTL 600 秒；一次性读取（二次读 → 410）；错误查询闸门：
同一 IP 一分钟内 5 次失败查询即封禁该 IP 至窗口翻转（429）。限频：POST 10/min/IP，
GET 30/min/IP。**诚实的威胁模型（T-060b）**：短码空间仅 10^6，服务器**运营方**
可在毫秒级对 `code_hash` 做字典反查并解密任意信封——本设计保护的是**外部人员**
（网络观察者、API 客户端），不防运营方。一次性读取是防重放属性，不是不可关联性
——运营方可见每一次请求。文档与客户端代码不得声称更高的保证。

## Client flow (remote pairing)

1. Desktop (owner) generates a 6-digit code, encrypts its NodeId into a sealed
   envelope with a key derived from the code, and `POST /code`.
2. The remote phone receives the code out-of-band (voice/SMS), hashes it, and
   `GET /code/<hash>` → gets the envelope → decrypts → NodeId → proceeds with
   the normal `pair.request` flow.
3. On `409` (hash already live) the desktop MUST pick a fresh code and
   re-POST — never treat 409 as success.
4. The server never parses the envelope, and read-once blocks replay; TTL +
   rate limits bound brute force over the 10^6 code space. These protect
   against outsiders — **not** against the operator (see threat model above).

客户端流程（异地配对）：桌面端生成 6 位短码 → 用短码派生密钥把 NodeId 加密成信封 →
`POST /code`；异地家人通过语音/短信拿到短码 → 哈希 → `GET /code/<hash>` 取信封 →
解密得 NodeId → 走常规 `pair.request` 配对。桌面端收到 `409`（短码撞车且对方信封
仍存活）必须换新码重发，绝不能当成功处理。服务器从不解析信封，一次性读取防重放；
TTL + 限频封住 10^6 空间的爆破。以上保护对象是**外部人员**——不防运营方
（威胁模型见上文）。

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
