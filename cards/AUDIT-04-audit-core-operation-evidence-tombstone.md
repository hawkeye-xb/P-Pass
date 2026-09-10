# AUDIT-04 审计核心重建：操作、对象证据、决定与 tombstone（L2）

> 🟢 状态：代码完成，本地全量 `just ci` 绿；待真机验收 · 协同分支：`audit/audit-04-core-contract`
> 当前节点：四张canonical表（audit_operation/audit_item_evidence/audit_tombstone/audit_decision）+ 全部生产路径接线均已落地，等待真机走查验收标准最后一条
> 级别：L2 · 阻塞：无
> 前置：[AUDIT-03](AUDIT-03-audit-contract-case-matrix.md)（矩阵与可信/保留/访问边界已定）

## 问题

AUDIT-01 只解决了 Android outbox 到 Desktop `audit_event` 的可靠投递；它把 `flow.round.finished`、`device.connected` 等实现事件当长期审计事实，缺少操作身份、对象 receipt 证据、数据离开后的 tombstone、用户决定及因果关联。活动页因而只能显示“连接了 / 一批传输完成”这类无法审查的技术流水账。

## 期望行为

以下是本卡已经定死的审计合同，实施不得重新定义：

1. **`audit_operation`**：一次用户/自动备份操作或安全操作。必须含不可变 `operation_id`、actor ref + 当时名字快照、触发来源、范围 revision/集合摘要、发生与 Desktop 确认时间、终态计数、对象证据集合摘要、因果 ref 与 schema version。
2. **`audit_item_evidence`**：每张进入数据流的照片的稳定 item ref、source version、content hash、receipt ref、asset ref、确认/失败事实。正常成功不逐条投影到活动页，但必须可由 operation 查询到。
3. **`audit_tombstone`**：照片从【本地】离开（外部删除、未来明确产品删除、不可恢复结论）后仍保留 object/evidence 引用、发现者或未知归因、发生时间、恢复状态。删 asset 行不得连带删 tombstone 或审计。
4. **`audit_decision`**：用户/【本地】作出的取消、恢复、放弃恢复、范围或授权决定，必须引用引起决定的 operation/object/tombstone。
5. **监控排除**：`device.connected`、hello、连接、retry、path、性能不写上述任一长期表；presence 只维护设备状态。
6. **身份展示输入**：审计存不可变 actor/target ref 和当时名字快照。UI 投影规则为当前 Desktop `【本地】`；其它设备永远 `名称 · #短指纹`。不要求给本机命名。
7. **本机支持级**：不实现签名/远端锚定/抗本机拥有者篡改；但在正常业务路径内本地事实和 outbox 必须原子、可重放、幂等。
8. **保留**：operation、item evidence、tombstone、decision 随照片库生命周期保留，无自动过期；整库明确删除时才整体删除。
9. **直接切换**：丢弃 AUDIT-01 `audit_event` 的现有测试历史和 schema；不读取/迁移旧泛用事件。保留真实 backup ledger、receipt、asset 事实，不能为重建审计导致重复交付或丢副本。

## 验收标准

- [x] RED：receipt 被 ledger 接受时，`audit_item_evidence` 与对象确认事实同一持久边界生成；崩溃/重放不重复。
- [x] RED：operation 完成时只生成一条 `audit_operation` 终态，且它能关联完整的 item evidence 集合摘要；不能只存 `confirmed=N` 而无对象证据。
- [x] RED：Desktop 外部删除后 asset 主记录可移除，但对应 `audit_tombstone` 与此前 item evidence 仍可查询；去掉 tombstone 写入测试必红。
- [x] RED：取消、恢复、放弃恢复、撤销授权均写 `audit_decision`，并引用 operation/object/tombstone 的因果来源；普通 hello/retry 不会产生长期审计行。
- [x] Android outbox → daemon 接收 → Desktop 新合同表仍具 event-id 幂等；未确认事件重启后继续重放。
- [x] `audit_event` / `device.connected` 旧泛用审计读写、旧 action/detail 投影均不存在；presence/online 语义回归通过。
- [x] Rust/Android focused tests、desktop build、`just ci` 全绿；Android 报告本次 XML 测试计数。
- [ ] 真机：隔离测试图进入【本地】后，有 operation + item evidence；再从【本地】外部删除，资产消失但 tombstone/历史证据仍在。

## 范围

- 只准动：`crates/storage/` 审计 schema/repository/migration/tests；Android Flow ledger/outbox/receipt/reconciliation 及测试；`crates/proto/` 与 daemon audit 接收/对象删除对账/presence 接线及测试；AUDIT-01 已改动的 audit IPC/diagnostic serialization；本卡与任务文档。
- 不准动：Desktop 活动页/详情 UI（后续 AUDIT-05）、NET-04/05、TEL/OBS、备份业务语义、照片库中真实 asset/receipt 的数据内容。

## 阻塞与依赖

无。AUDIT-05 Desktop 活动/详情投影必须等本卡的新合同完成后才能开始，禁止先对旧 `audit_event` 修文案。
