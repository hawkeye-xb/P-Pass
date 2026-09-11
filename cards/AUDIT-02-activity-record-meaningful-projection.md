# AUDIT-02 活动记录只展示用户有意义的结果（L2）

> 🟡 状态：进行中 · 协同分支：`work/audit-02-activity-ui`
> 当前节点：确认 `audit.list` 缺少可信 evidence summary；先为只读 IPC/投影写失败用例
> 下一步：将既有 canonical evidence summary 暴露给活动页，改为用户结果文案并跑 focused + desktop + `just ci`
> 级别：L2 · 阻塞：无

## 问题

AUDIT-04 已将真实 Flow 结果落到 `audit_operation` / `audit_item_evidence` / `audit_tombstone` / `audit_decision`，但 Desktop 活动记录仍把 `flow.round.finished` 直接翻译为「一批传输完成」。这既是内部窗口术语，也没有使用 daemon 从对象证据重算的真实结果；用户无法知道自己的照片发生了什么、是否需要处理。活动页也不应再显示连接、重试、路径等诊断流水账。

## 期望行为

活动记录只回答两件事：**用户数据发生了什么**、**用户现在需要做什么**。它不是连接/重试/状态机的流水账。

- 正常 Flow 终态按 `audit_operation.evidence_summary`（daemon 由 `audit_item_evidence` 重算，不能相信手机自报 `final_counts`）显示数据结果：`已备份 N 张照片`；有非零异常时同一行追加 `；M 项需要处理`、`；K 张已跳过`。不得出现「一批」「round」「传输」等内部词，也不得逐照片刷行。
- 配对/撤销、外部删除、需要用户处理的项、对账裁决仍可显示，因为它们影响数据安全或需要用户决策。
- `device.connected` 不再写长期审计，更不显示在活动记录；在线状态只由现有 `last_seen`/presence 设备状态承担。活动页对遗留/未知的连接、重试、路径与性能事件也必须过滤，不能因为旧库记录而复活诊断噪音。
- 暂停/继续/retry、范围修改、epoch 清退可留作结构化审计事实，但默认不出现在活动记录；用户刚执行的控制操作或内部恢复不应把真正的数据结果淹没。身份按 AUDIT-04：本机显示【本地】，其它设备显示名称与短指纹。

## 验收标准

- [ ] RED：daemon `audit.list` 为 `flow.round.finished` 返回 `evidenceSummary`；构造手机自报 `confirmed=5`、实际只存 1 条 confirmed evidence 的 operation，返回值必须是 confirmed=1，证明 UI 无法采用伪造计数。
- [ ] RED：给 `flow.round.finished` 的 `evidenceSummary={confirmed: 1}` → 活动页文案严格为 `已备份 1 张照片`；改回「一批传输完成」测试必须失败。
- [ ] RED：非零 `failed`/`remote_missing`/`source_missing` 只在同一条汇总表达用户后果；不得创建或显示逐项成功行。
- [ ] 活动记录只投影数据结果、数据风险与安全事实；控制/连接/内部 epoch 事件不在默认列表里。未知 kind 显示为不泄露机器字段的通用未分类记录，并保留在诊断导出中。
- [ ] 当前 main 的隔离 Flow 测试轮在 Desktop 活动记录中显示一条 `已备份 1 张照片`，不是「一批传输完成」或「连接了」。
- [ ] 相关 Rust、desktop tests/build、`just ci` 全绿；真机重新生成一张隔离测试图并核对活动记录。

## 范围

- 只准动：`apps/desktop/src/App.svelte` 与对应 desktop 测试；`crates/storage/src/audit_repo.rs` 和 `crates/daemon/src/ipc.rs` 及 focused tests（只将既有 canonical operation 的证据摘要/身份快照读出给 `audit.list`，不改 schema 或写入路径）；本卡、`docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md`。
- 不准动：Android Flow 状态机/outbox/proto、审计 schema/迁移/写入语义、NET-04/05、TEL/OBS 遥测、配对/外部删除的审计事实。

## 阻塞与依赖

AUDIT-03 与 AUDIT-04 已完成，旧 `audit_event` 模型已被淘汰。本卡只消费 AUDIT-04 的 canonical 读模型；AUDIT-05 的狗粮周复核用于验证样本覆盖与预设，不构成 UI 前置或阻塞。
