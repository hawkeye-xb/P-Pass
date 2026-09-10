# AUDIT-01 Flow 审计 v2：持久 outbox 与直接切换（L2）

> ⚪ 状态：冻结（AUDIT-04 已直接替换 `audit_event` 合同）· 协同分支：`main`
> 当前节点：不得做旧 `audit_event` 的 Desktop 文案视觉验收或投影；狗粮周后由 AUDIT-05 只读审查 canonical 四表再决定后续 UI
> 级别：L2 · 阻塞：等待狗粮周真实审计样本

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

- [x] RED：手机 ledger 的一个用户动作或 receipt 接受若不随同一次原子 snapshot 生成 outbox event，合同测试失败；写入后重启仍能取到同一 event id。
- [x] RED：同一 outbox event 投递两次、或同一 Desktop receipt 重放，Desktop 仅有一条 `audit_event`；移除唯一 id/幂等约束后测试变红。
- [x] RED：三项正常确认的同一 `roundId` 只产生一条 `flow.round.finished` 汇总；逐项 `flow.item.confirmed` 或把普通 transport transition 写入长期审计时测试变红。
- [x] 用户动作（pause/continue/cancel/restore/retry）、范围变更、源缺失、`FAILED_NEEDS_USER`、远端缺失裁决、epoch 清退均有固定 kind、最小结构化 payload、关联 `roundId`/epoch，并只从已经持久化的事实生成。
- [x] Desktop SQLite 直接升级到 v2：旧 `audit_log` 不再被读取或暴露；新 `audit_event` schema 含 event id 唯一约束、发生时间、actor、kind、关联 id 与 JSON payload。历史 v1 行不迁移、不伪造为 v2 事实。
- [x] 配对、吊销、外部删除等仍在生产路径的审计写入改为 v2；`audit.list` 返回 v2 结构，Desktop 活动页不再正则解析 `backup.finished` 或读取旧 action/detail。
- [x] Android JVM、Rust focused tests、desktop tests/build、`just ci` 均通过；Android 测试从本次 XML 统计真实测试数。真机验证另列为后续批次，不阻塞本地实现完成。

### 验收记录（2026-09-10）

- Android：`./gradlew :app:testDebugUnitTest` → 328 个测试，0 失败（含新增
  `AUDIT01LedgerOutboxTest` 6 个用例，锁定 ledger↔outbox 原子提交契约）。
- Rust 工作区：`cargo nextest run --all-features` → 346 个测试通过（1 个
  预先存在的 skip），`just ci`（fmt/clippy/arch-check/queue-check/
  md-check/token-check）全绿。
- Desktop：`cargo test --lib`（p-pass-desktop crate）18 个测试通过；
  `vitest run` 57 个测试通过。
- `audit_log` 表随 migration `0005_audit_event_v2.sql` 整表 DROP，未做
  任何读取兼容或历史行迁移；`crates/storage/src/audit_repo.rs` 是唯一
  审计写入/查询入口。
- Desktop 活动页（`App.svelte`）改读 v2 `kind`/`payload` 字段；
  `backup.started`/`backup.finished` 会话级审计（旧 batch 事件矩阵外）
  随 router.rs 一并移除，依赖它的「本周新备份/去重跳过」统计与
  「备份耗时」两处派生 UI 一并下线（不伪造无对应数据源的数字）。
- 真机验证分两层：Flow 数据链与 Desktop 活动文案视觉呈现；前者已通过，后者仍待独立确认。

### 真机数据链验收（2026-09-10）

- 三星测试机更新到本卡 Android debug APK；Desktop 壳与 sidecar daemon 均从当前 `main`
  重启，排除了同版本旧 daemon 继续驻留的假验收。
- 在已选的 `P-Pass` 测试相册生成一张隔离测试图片并发起备份：手机状态由 21/21
  收敛为 22/22，最近成功显示“刚刚”。
- 只读核对手机 ledger：22 项均为 `CONFIRMED`、consumer 为 `IDLE/OPEN`、
  `auditOutbox` 为 0；说明本轮终态已被确认后从 outbox 摘除，而非在发送时丢弃。
- 只读核对 Desktop SQLite：`audit_event` 有本轮 1 条 `flow.round.finished`，资产总数为
  22，`audit_log` 表不存在。证明 Flow ledger → daemon `flow.audit.submit` → v2 审计库
  的真实跨端闭环成立，且正常项未逐张刷审计。
- 未把 Desktop 活动页的实际中文文案说成已验：本轮未取得可读的 Desktop 画面，仍需
  打开活动记录确认它把该 v2 事件渲染为一条轮次汇总，而不是回退或逐项行。

### 补齐记录（2026-09-10，review 后追加）

首轮实现遗漏了实施顺序第 3 步——手机 outbox → daemon 的投递/落库管线
本身；`acknowledgeAuditEvents` 只在单测里被调用，生产代码没有任何调用点
把 `auditOutbox` 发给 daemon。已补齐最小闭环：

- `crates/proto`：新增 `FlowAuditEvent` / `FlowAuditSubmit` /
  `FlowAuditAccepted` 消息类型与 `flow.audit.submit` 方法常量；
  event_id/kind/round_id/occurred_at_ms/payload 与手机 ledger 的
  `AuditOutboxEvent` 字段一一对应，不重塑形状。
- `crates/daemon`：`Router::handle_flow_audit_submit` 接收一批 outbox
  事件，逐条按手机传来的 event_id（不重新生成）调用既有
  `append_audit`（`INSERT OR IGNORE` 天然幂等），返回被接受的
  event_id 列表供手机侧 ack；`flow.` 前缀已覆盖 authz（member+）。
- Android：新增 `AuditOutboxDispatcher`（`FlowAuditTransport` 接口 +
  `DaemonFlowAuditTransport` 生产实现），在每个 Flow 触发点
  （wake/pause/continue/retry/cancel/restore 及原生投递的
  missingSource/permanentFailure/receipt 回调）之后异步 flush 一次；
  daemon 确认的 event_id 才调用 `acknowledgeAuditEvents` 摘除，未确认
  的（网络失败、未配对、daemon 部分失败）留在 outbox 里等下次触发
  重放——不在发送时清空，只在确认落库后清空。
- 端到端合同测试：`crates/daemon/tests/flow_audit_submit.rs`（提交→
  落库→event_id 保留、重放批次幂等、未配对拒绝）；Android
  `AuditOutboxDispatcherTest`（accepted 摘除、部分接受时未确认的留存
  重试、传输失败整批不动、空 outbox/未配对不发起连接）。
- 复测：Rust `cargo nextest run --all-features` 354 passed（较首轮
  346 + 本次新增 8 个用例）1 skipped；`just ci` 全绿；Android
  `./gradlew :app:testDebugUnitTest` 333 passed（较首轮 328 + 本次
  新增 5 个用例），0 failed；desktop `cargo test --lib` 18 passed、
  `vitest run` 57 passed，均未回归。

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
