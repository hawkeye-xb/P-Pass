# NET-25 真实传输路径上的 `flow.delivered` 推送是否送达，仍未验证

状态：🟥 挂号
级别：L2（猜测；真出问题也只是"稍慢"，有本地 iroh 事件兜底，不卡死）
关联: 从 [NET-24](done/NET-24-flow-delivered-push-not-reaching-phone.md) 分出

## 挂号段

- **现象**：NET-24 证实了「去重命中时推送必丢」——手机在 `offer` 之后才
  `subscribeTimeline`，daemon 的事件总线是 broadcast（无订阅者时 send 直接
  丢弃）。NET-24 用「offer 应答带回终态」绕开了这个洞，但**没有修那个订阅
  时序本身**。真实传输路径上推送到底有没有送达过，至今没有任何一次正面
  证据。
- **发现场景**：2026-09-17 做 NET-24 真机验收时。那一轮 13 张里只有 2 张是
  真实传输，且判据只到"每张耗时 0.3 秒级"，**无法区分**这 2 张是靠推送完成
  的，还是靠手机自己的本地 iroh-blobs 完成事件（`TransferStatus.Completed`
  → `CheckStatusNow`）完成的。两条路都会得到同样快的结果，所以这次验收
  **不构成推送可用的证据**。
- **严重度猜测**：低。真实传输一定会产生本地 iroh 事件，`idleForMs` 非 null、
  停滞检测正常工作，最坏退化为"比推送慢一点"，不会重现 NET-24 那种 30 秒
  卡顿（那是零事件场景独有的）。所以这是**可观测性/效率**问题，不是正确性
  问题。

## 备注（挂号时已知，供接卡人省一次考古）

- 订阅时序：`NativeFlowDeliveryPort.kt` 里 `desktop.offer(request)` 在前、
  `launch { client.subscribeTimeline(...) }` 在后，且订阅是异步 launch，
  返回时尚未建立。NET-24 未改这个顺序（验收人明确否掉「靠调时序赢竞态」
  这类修法）。
- 事件总线：`events.rs` 的 `EventBus = broadcast::Sender`，模块头注释写明
  「无订阅者时 send 直接丢弃」，`emit` 是 `let _ = bus.send(...)`，错误被吞。
- NET-24 原卡另外两条未证伪的候选一并转入本卡：daemon 侧订阅者表在断链
  重连后是否残留失效连接；`emit_flow_delivered` 的推送目标 `peer: NodeId`
  在重连后是否仍对应当前活跃连接。
- **取证思路**（未验证，不得直接采信）：给推送送达补一条手机侧日志，跑一批
  **全新内容**（确保不命中去重）的真实传输，看 `FlowPushOutcome.Delivered`
  分支是否被走到过；若一次都没有，才说明推送在真实路径上同样从未送达。
