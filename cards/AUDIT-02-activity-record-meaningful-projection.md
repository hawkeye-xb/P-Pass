# AUDIT-02 活动记录只展示用户有意义的结果（L2）

> ⬜ 状态：冻结，未编码 · 当前节点：被 AUDIT-03 的审计合同重定义取代；保留本卡作为错误“先修 UI 投影”方向的记录
> 级别：L2 · 阻塞：AUDIT-03 的可信等级、保留和详情权限裁决

## 问题

AUDIT-01 的真实 Flow 已正确写入 `flow.round.finished`，但 Desktop 活动记录把它直接翻译为「一批传输完成」，同时仍显示「连接了」。前者是内部窗口术语，后者只是 heartbeat/presence；用户无法从中知道自己的照片发生了什么、是否需要处理。把所有审计事实原样投影到活动页，等于把技术日志伪装成用户历史。

## 期望行为

活动记录只回答两件事：**用户数据发生了什么**、**用户现在需要做什么**。它不是连接/重试/状态机的流水账。

- 正常 Flow 终态按已有结构化 payload 显示数据结果：`已备份 N 张照片`；有非零异常时同一行追加 `；M 张需处理`、`；K 张已跳过` 或 `；L 张已取消`。不得出现「一批」「round」「传输」等内部词，也不得逐照片刷行。
- 配对/撤销、外部删除、需要用户处理的项、对账裁决仍可显示，因为它们影响数据安全或需要用户决策。
- `device.connected` 不再写长期审计、更不显示在活动记录；在线状态只由现有 `last_seen`/presence 设备状态承担。删除该审计依赖后不得破坏在线状态。
- 暂停/继续/retry、范围修改、epoch 清退仍可留作结构化审计事实，但默认不出现在活动记录；用户刚执行的控制操作或内部恢复不应把真正的数据结果淹没。

## 验收标准

- [ ] RED：给 `flow.round.finished` 的 `{confirmed: "1", failed: "0", cancelled: "0", skippedSourceMissing: "0"}` → 活动页文案严格为 `已备份 1 张照片`；改回「一批传输完成」测试必须失败。
- [ ] RED：非零结果只在同一条汇总里表达对应数据后果；不得创建或显示逐项成功行。
- [ ] RED：正常 hello/presence 后，`audit_event` 中没有 `device.connected`；设备在线状态测试仍通过，证明不是靠写审计维持 presence。
- [ ] 活动记录只投影数据结果、数据风险与安全事实；控制/连接/内部 epoch 事件不在默认列表里。未知 kind 仍保留安全兜底，不静默吞事件。
- [ ] AUDIT-01 的真实测试轮在 Desktop 活动记录中显示一条 `已备份 1 张照片`，不是「一批传输完成」或「连接了」。
- [ ] 相关 Rust、desktop tests/build、`just ci` 全绿；真机重新生成一张隔离测试图并核对活动记录。

## 范围

- 只准动：`apps/desktop/src/App.svelte` 与对应 desktop 测试；`crates/daemon/src/router.rs` 的 presence 审计写入；仅在无调用后可移除 `audit_repo` 的 dedupe 查询及对应测试；本卡、`docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md`。
- 不准动：Android Flow 状态机/outbox/proto、`audit_event` schema、NET-04/05、TEL/OBS 遥测、配对/外部删除的审计事实。

## 阻塞与依赖

AUDIT-01 的数据链已通过真机验证；但用户已否决“先修改该结构化事件的用户投影与 presence 副作用”的方向。必须先完成 AUDIT-03 审计合同，之后按新合同重新拆实现卡；本卡不恢复。
