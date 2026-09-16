# NET-23 Flow 等待循环在本地信号永远不触发时必须有出口　级别 L0

> ✅ 状态：已修复并通过 `./gradlew testDebugUnitTest`（全绿）· 协同分支：`main`
> 级别：L0 · 阻塞：无
> **背景**：2026-09-16 真机复现（三星 SM-S9210）——断链重连后重新触发
> 备份，11 张照片全部命中 NET-20 的内容去重（daemon 侧早已完成、有
> receipt），手机 UI 卡在「正在备份...第 0/11 张」超过 15 分钟不动，
> daemon 数据库显示对应 tuple 早已 `completed`，daemon 日志/DB 在此
>期间零新增活动——手机侧从未再发起过一次 `flow.status()` 轮询。

## 问题

`NativeFlowDeliveryPort.start()` 的等待循环（`flowWaitStep`，
`crates/../NativeFlowDeliveryPort.kt`）按优先级依赖三个信号：
1. `flow.delivered`/`flow.failed` 推送（主信号）；
2. 手机自己的本地 iroh-blobs 发送端状态（`bridge.transferStatus()`）；
3. 兜底的 `flow.status()` 轮询。

兜底轮询只在本地状态显示「已断开且空闲超过 30 秒」（`idleForMs != null
&& idleForMs >= threshold`）时才触发。但 `idle_for_ms`
（`crates/transport/src/android_blobs.rs`）的定义是「距上一次
iroh-blobs get-request/progress/completed/aborted 事件的时间——**如果
这条 lease 从来发生过任何事件的话**」。

NET-20 的内容去重（`complete_without_fetch`）和 NET-22 的 rebind 分支
都是"daemon 完成得知道，但从不碰数据面"——本地 iroh-blobs 上**永远
不会有任何一次事件**，`idle_for_ms` 因此永远是 `null`，不是"还没到
30 秒"。旧代码把 `null` 和"还没到阈值"归成同一档、一起走
`KeepWaitingForPush`，于是只要 `flow.delivered` 推送因为任何原因
（订阅时机、断链重连的竞态等）没有送达这一次尝试，就**没有任何出口，
永久挂起**——这正是真机复现的现象。

## 实现

`flowWaitStep` 新增第四个参数 `attemptElapsedMs`——**这次等待循环自己
的挂钟耗时**，由调用方 `NativeFlowDeliveryPort.start()` 用
`SystemClock.elapsedRealtime()` 从循环开始计时。`InProgress` 分支新增
一条判据：`idleForMs == null && attemptElapsedMs >= idleStallThresholdMs`
同样落到 `CheckStatusNow`——不改变任何有真实本地活动的传输的行为
（那些走已有的 `idleForMs`-based 分支），只堵住"本地从头到尾没有任何
信号"这一种此前无法退出的情形。

## 验收标准

- [x] RED 先行的等价用例：`disconnected_with_no_activity_ever_but_still_under_the_stall_threshold_keeps_waiting`
      （未到阈值前不能提前误判为卡死）+
      `disconnected_with_no_activity_ever_past_the_stall_threshold_falls_back_to_status_check`
      （过阈值后必须有出口）——后者是本卡要堵的缺口，前者是防止误伤
      正常传输起点的反证。
- [x] 现有 `NET14PushFirstDeliveryTest`/`ARCH01StrictConsumerTest` 全部
      保持绿：`./gradlew testDebugUnitTest --tests
      "com.hawkeyexb.ppass.backup.flow.NET14PushFirstDeliveryTest"
      --tests "com.hawkeyexb.ppass.backup.flow.ARCH01StrictConsumerTest"`
      全绿（含 2 条新用例）。
- [x] 真机验证：三星 SM-S9210，同一批 11 张卡住的照片，重启 App 后
      从 0/11 推进到 11/11、UI 显示「照片都存好了」；daemon 侧
      `flow_delivery` 表对应 epoch 下 11 行全部 `completed`。

## 范围

- 只动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/NativeFlowDeliveryPort.kt`
  （`flowWaitStep` 签名与判据、调用处新增挂钟计时）、
  `apps/android/app/src/test/java/com/hawkeyexb/ppass/backup/flow/NET14PushFirstDeliveryTest.kt`
  （新增 2 条用例，既有用例补齐新参数）。
- 未动：daemon 侧代码、协议线格式、push/local-status 的既有判据（除新增分支外）。

## 阻塞与依赖

无前置。与 NET-22 同一次真机复现中一起发现；NET-22 补的是 daemon 侧
"本该推送而没推"的缺口，本卡补的是手机侧"推送没送到时必须有兜底"的
缺口——两者独立、任一个单独合并都成立，一起合并才闭合了这条路径上的
两个洞。

## 备注

真机验证中观察到：本卡修复后，去重命中的每一张仍然要等满 30 秒兜底
超时才被轮询捞回（11 张耗时约 3 分钟），不是预期的"推送到达后瞬时
完成"。说明这次真机复现里 `flow.delivered` 推送**始终没有成功送达
手机**，根因未查——本卡只保证了"送不到时不会永久卡死"，没有解决
"为什么送不到"。跟踪见 [NET-24](../NET-24-flow-delivered-push-not-reaching-phone.md)（待开）。
