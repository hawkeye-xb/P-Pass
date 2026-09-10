# AUDIT-01 Flow 审计 v2：持久 outbox 与直接切换（L2）

> 🟠 状态：进行中 · 协同分支：`audit/audit-01-flow-v2` · 当前节点：定义并实现新的唯一审计事实链
> 级别：L2 · 阻塞：无（NET-04/05 的路径观测明确不作为前置）

## 问题

ARCH-01 的生产 Flow 已将发现、单项传输、receipt、范围和取消等事实持久化在手机 `DiscoveryLedger` 与 Desktop `flow_delivery` 中；但用户活动仍读取旧批处理时代的 `audit_log` 自由文本。新 Flow 的用户操作和终态无法形成可靠审计。若在状态提交后“顺手 append”一行审计，手机账本与 Desktop SQLite 不在同一原子事务中：崩溃、断网、receipt 重放都可造成漏记或重复记。

现有 `audit_log` 的 `action + detail` 也已不足以承载 Flow 的轮次、相关性、幂等身份和结构化终态，Desktop 以正则解析 `backup.finished` 属于旧批处理投影，不能继续扩张。

## 期望行为

- `audit_event` v2 成为唯一的长期审计事实源；移除 `audit_log` 及其旧 UI/IPC 文本投影，不读取、不迁移、不兼容历史旧行。
- 手机每次应审计的 Flow 状态变更，连同唯一事件 id 原子写进 ledger outbox；发送失败可在下次可达时重放，绝不因崩溃而出现“状态已成真但审计永久缺失”。
- Desktop 按事件 id 幂等落库；同一 receipt 重放、outbox 重传均不产生第二条审计。
- 正常文件不逐张写长期审计；一个有持久 `roundId` 的 Flow 窗口只写一条终态汇总。用户操作、范围变化、需要用户处理的终态、对账裁决、pairing epoch 使旧项失效等数据/权限事实才写审计。
- 连接、握手、重试、direct/relay 路径只进入短期诊断面；不进长期审计、不参与计费。relay 计费的唯一权威仍是服务端。
- 现有仍在生产中的配对、吊销、外部删除等事实改写为 v2 事件；旧 batch `backup.*` 不再作为任何活动页或统计来源。

## 验收标准

- [ ] RED：手机 ledger 的一个用户动作或 receipt 接受若不随同一次原子 snapshot 生成 outbox event，合同测试失败；写入后重启仍能取到同一 event id。
- [ ] RED：同一 outbox event 投递两次、或同一 Desktop receipt 重放，Desktop 仅有一条 `audit_event`；移除唯一 id/幂等约束后测试变红。
- [ ] RED：三项正常确认的同一 `roundId` 只产生一条 `flow.round.finished` 汇总；逐项 `flow.item.confirmed` 或把普通 transport transition 写入长期审计时测试变红。
- [ ] 用户动作（pause/continue/cancel/restore/retry）、范围变更、源缺失、`FAILED_NEEDS_USER`、远端缺失裁决、epoch 清退均有固定 kind、最小结构化 payload、关联 `roundId`/epoch，并只从已经持久化的事实生成。
- [ ] Desktop SQLite 直接升级到 v2：旧 `audit_log` 不再被读取或暴露；新 `audit_event` schema 含 event id 唯一约束、发生时间、actor、kind、关联 id 与 JSON payload。历史 v1 行不迁移、不伪造为 v2 事实。
- [ ] 配对、吊销、外部删除等仍在生产路径的审计写入改为 v2；`audit.list` 返回 v2 结构，Desktop 活动页不再正则解析 `backup.finished` 或读取旧 action/detail。
- [ ] Android JVM、Rust focused tests、desktop tests/build、`just ci` 均通过；Android 测试从本次 XML 统计真实测试数。真机验证另列为后续批次，不阻塞本地实现完成。

## 范围

- 只准动：Android Flow ledger/runner/consumer/completion/cancellation/reconciliation 的持久 `roundId`、outbox 与投递装配及 Android Flow 合同测试；`crates/proto` 的 v2 审计投递消息和方法；daemon authz/router 接线；`crates/storage` 审计 schema migration、v2 repository 与测试；daemon/core-index 中仍在生产路径的审计写入点及对应 Rust tests；Desktop `audit.list` IPC、活动页 v2 投影、诊断包审计导出及对应 tests；本卡和任务文档。
- 不准动：`backup.*` 旧批处理流程、`BackupWorker` 或旧 batch 行为来“兼容”新 Flow；NET-04/NET-05 连接缓存、路径状态、`flow_connection` 语义；OBS-01/OBS-02 的外发 telemetry、隐私开关、Cloudflare worker schema。

## 阻塞与依赖

无。`App.svelte` 当前被未合并的 MOB-47 分支修改；实现分支先完成无 UI 文件的 RED→GREEN，进入活动页投影前必须 fetch/rebase 并保留上游视频查看器改动，不得在共享文件上并行覆盖。

---

## 已定事件矩阵 v2

| 持久事实 | 长期审计 kind | 短期诊断 | 对账 | 不记录 |
|---|---|---|---|---|
| 暂停/继续、取消/恢复、retry | `flow.round.controlled` | — | ledger | — |
| 范围变更、epoch 令旧项失效 | `flow.scope.changed` / `flow.epoch.invalidated` | — | ledger | — |
| 普通发现页、开始传输、正常单项 receipt | — | queue depth / age / latency | ledger ↔ receipt | 长期活动逐项行 |
| 窗口全终态 | `flow.round.finished`（按终态聚合） | duration / attempts | ledger + receipts | — |
| source missing / terminal failed / remote missing 裁决 | `flow.item.attention` / `flow.reconciliation.resolved` | error reason | ledger ↔ assets / source | — |
| pairing / revoke / external delete | 对应 v2 security/data kind | — | device / filesystem | — |
| 连接/握手/路径切换 | — | reuse/path/flap | — | 长期审计 |

## 实施顺序

1. 用失败的 ledger/outbox 合同测试锁定“事实与 event 同提交”和 round 聚合；新增 `roundId` 仅以一次性 v2 ledger 升级建立，不保留旧 schema fallback。
2. 用失败的 Rust migration/repository/IPC 测试锁定 v2 schema 与 event-id 幂等；删除旧审计表的读取路径并迁移仍有效的 security/data writer。
3. 接 Android 投递/重放与 daemon 授权接收；先通过手机 ledger → daemon v2 event 的垂直 slice，再扩展全部事件类别。
4. 最后切 Desktop 活动页和诊断包到 v2；在此步骤前 rebase 并保留 MOB-47 的 `App.svelte` 上游改动。
5. 本地全量验证后提交一个完整批次；真机只验证新活动文案与 Flow 真实终态，不拿 NET-04/05 路径显示充当审计证据。
