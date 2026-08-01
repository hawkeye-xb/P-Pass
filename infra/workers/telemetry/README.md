# infra/workers/telemetry

Telemetry intake (T-061): strict zod validation per the 手册 §8 event
dictionary → Cloudflare Analytics Engine. The Rust client
(`crates/daemon/src/telemetry.rs`, T-035) POSTs a JSON **array** of flat event
objects; this Worker validates every event against a strict schema and writes
the batch to Analytics Engine.

遥测入口（T-061）：按手册 §8 事件字典做严格 zod 校验 → Cloudflare Analytics
Engine。Rust 客户端（`crates/daemon/src/telemetry.rs`，T-035）POST 一个 JSON
**数组**（扁平事件对象）；本 Worker 对每个事件做严格 schema 校验，通过后整批
写入 Analytics Engine。

## API

| Route | Method | Body | Responses |
|---|---|---|---|
| `/` | POST | JSON array of events | 200 `{accepted}` · 400 invalid batch / bad JSON · 413 too large · 405 |
| `/` | GET | — | 200 health `{ok, service}` |

- Hard caps: body ≤ 1 MiB (413), batch ≤ 100 events (400).
- **Whole-batch strictness**: one invalid event rejects the whole batch with
  400 — the client drops failed batches anyway (best-effort telemetry), and a
  loud failure surfaces client/server drift instead of silently losing data.
- Unknown event types AND unknown extra fields are rejected (`.strict()`).
  The Rust client's wire format is the source of truth (schema mirrors it
  field-for-field, including the client's behavior of a single `ver`).

- 硬上限：请求体 ≤ 1 MiB（413）、单批 ≤ 100 事件（400）。
- **整批严格**：一个非法事件拒绝整批（400）——客户端反正会丢弃失败批次
  （尽力而为的遥测），响亮失败能暴露客户端/服务端漂移，而不是悄悄丢数据。
- 未知事件类型与未知多余字段均拒绝（`.strict()`）。Rust 客户端的线格式是唯一
  事实来源（schema 逐字段对齐，包括客户端只发一个 `ver` 的行为）。

## Analytics Engine mapping / 写入映射

Per event, one data point:

- `indexes: [event]` — GROUP BY event type (`conn` / `backup_session` /
  `first_byte` / `daemon_alive`)
- `doubles: [ts, ...numeric fields]` — ms / files / bytes / dur_s / uptime_h
- `blobs: [full event JSON]` — self-describing, lossless

每个事件一个数据点：`indexes: [event]`（按事件类型分组）；`doubles: [ts,
...数值字段]`（ms/files/bytes/dur_s/uptime_h）；`blobs: [完整事件 JSON]`
（自描述、无损）。

## Local dev & test

```bash
npm install
npm test          # vitest: 12 tests — unit (schema/ingest with fake AE) + HTTP via SELF
npm run typecheck
npm run dev       # wrangler dev
```

`wrangler.toml` declares the `TELEMETRY` Analytics Engine binding (dataset
`ppass_telemetry`) and is safe to commit — no credentials. Production deploy
config (account_id, routes, real dataset names) lives in the private ops repo
(`ppf-ops/deploy/workers.prod.toml`), per the isolation plan §2.

`wrangler.toml` 声明 `TELEMETRY` Analytics Engine 绑定（数据集
`ppass_telemetry`），无凭据可安全提交。生产部署配置（account_id、路由、真实
数据集名）在私有仓 `ppf-ops/deploy/`（隔离方案 §2）。
