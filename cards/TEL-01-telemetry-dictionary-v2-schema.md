# TEL-01 遥测字典 v2 schema（破坏性变更，L1）

> ⬜ 状态：未开工 · 级别：**L1** · 阻塞：无（OBS-02 裁决已定案）

**目标**：把 `crates/daemon/src/telemetry.rs` 与
`infra/workers/telemetry/src/schema.ts` 同步改成 OBS-02 裁决的字典 v2，
两端字段逐一对齐；旧字段/旧事件名彻底删除，不做兼容层。

## 字典 v2（来自 OBS-02 裁决，照抄即可，不再讨论）

| 事件 | 字段 |
|---|---|
| `daemon_alive` | uptime_h, os, ver（不变） |
| `conn` | path(lan/direct/relay), ms, fail_stage?（去掉 ipver/country/isp_hash） |
| `flow_item`（新名，替代 `backup_session`） | bytes, dur_s, resumed（去掉 files/trigger） |
| `first_byte` | ms, kind（不变，字段留着，本卡不接线） |
| `error`（新增） | code, stage（只报错误码+阶段，禁止堆栈/路径/hash） |

公共字段 anon_id/ver/ts 不变。

## 范围

- `crates/daemon/src/telemetry.rs`：`Event` enum 改字段、`into_value` 改
  序列化、已有单测同步改（`every_event_carries_the_common_fields` 等）。
- `crates/daemon/tests/telemetry_flow.rs`：mock server 测试同步改字段。
- `infra/workers/telemetry/src/schema.ts`：zod schema 同步改
  （`connSchema`/`backupSessionSchema`→`flowItemSchema`/新增
  `errorSchema`），`toDataPoint` 的 doubles 固定列位表同步改（README 表
  也要改）、`assertNever` 穷尽性保留。
- `infra/workers/telemetry/src/index.test.ts` 同步改字段。
- `infra/workers/telemetry/README.md` 的字段表同步改。

**不准动**：`main.rs` 里 `daemon_alive` 心跳的调用点（不变）；
`conn`/`flow_item` 的生产调用点（那是 TEL-02 的范围）。

## 可执行验收

- `cargo test -p daemon telemetry` → 全绿，字段名与 v2 一致
- `cd infra/workers/telemetry && npm test` → 全绿（12+ tests，具体数量
  以改动后为准，不能减少现有 case 覆盖）
- `npm run typecheck` → 绿
- grep 全仓确认 `ipver`/`ISP_HASH`/`isp_hash`/`country`/`trigger`/
  `"files"`（telemetry 上下文）字段已从 telemetry 相关文件清除

**证据要求**：报绿附命令 + 输出摘要（测试计数）。

## 阻塞与依赖

- 无阻塞，可立即开工。
- TEL-02（接线）依赖本卡先落地新 `Event` 变体。
