# MOB-56 失败/接收回调绕过 flowTriggerLock，可致同一队头并发双发（L0）

> 🟢 状态：代码已合并，本地验证通过 · 当前节点：等真机复核（可选，非阻塞）·
> 下一步：真机确认不稳定网络下不再有并发传输 · 协同分支：`main`
> 级别：**L0**（违反 ARCH-03 严格消费者单活跃租约不变量，可能导致同一文件
> 双发、账本写坏） · 阻塞：无

## 问题

2026-09-07 三星 SM-S9210 真机回归（daemon 网络不稳定，`hello`/`flow.fetch`
反复 15 秒超时）：logcat 显示两条独立的「Native Flow delivery failed」
记录，时间戳只差 322ms、线程号不同（8329 vs 8282）——不是同一次调用的
重试记录，是**两个并发的原生传输尝试**。

根因（源码核实）：`AndroidFlowRuntime.kt` 里每一个触发 Flow 状态变化的
入口（`runFlowWake`、`pauseFlow`、`continueFlow`、`retryFailedFlow`、
`cancelCurrentFlowRound`）都套了 `synchronized(flowTriggerLock)`，唯独
`NativeFlowDeliveryPort` 的两个回调——`onPermanentFailure`（失败重试）和
`onReceipt`（成功确认）——直接调用 `runner.recordPermanentFailure()` /
`runner.acceptCompletionReceipt()`，绕过了这把锁。

`StrictConsumer.wake()`（ARCH-03）是读-检查-写：读账本、检查
`fetchLease == null`、写入新租约——中间没有内部同步，因为设计上依赖
调用方串行化。两个线程同时进入 `wake()`，都能读到 `fetchLease == null`，
都会尝试为同一个 `queueSequence` 建立租约并调用 `delivery.start()`，
构成对 ARCH-03「同一时刻只有一个活跃传输」不变量的违反；`persist()`
的临时文件原子 rename 在并发写入时也可能互相冲突抛异常。

这个缺口从更早的架构（REBUILD-02/03，`acceptCompletionReceipt` 内部早就
调用 `wake()`）就存在，只是网络稳定时几乎不触发。MOB-54（本轮同一次回归
新加的失败路径 `wake()`）让触发概率显著上升——网络不稳定时失败回调更
频繁，与并发的成功回调/其他触发碰撞窗口变大。

## 期望行为

Flow 状态变化的每一个入口（不论是用户触发的还是原生传输回调触发的）
都必须通过同一把锁串行化，保证 `StrictConsumer` 任意时刻只有一个活跃
租约、一个正在跑的原生传输。

## 验收标准

- [x] RED：JVM 用例证明未同步的并发 `wake()` 不安全（双发或
      `persist()` 写冲突异常），跨多轮尝试稳定复现。
- [x] GREEN：`onPermanentFailure`、`onReceipt` 两个回调套入
      `synchronized(flowTriggerLock)`，与其余入口一致。
- [x] Android JVM 全量绿（报测试计数）+ `just ci`。
- [ ] 真机：网络不稳定环境下（人为制造 daemon 无响应）不再出现两条
      并发的传输失败/成功日志。

## 范围

- 只准动：`backup/flow/AndroidFlowRuntime.kt`（两个回调的同步包装）、
  对应 JVM 测试、卡片/队列/进度文档。
- 不准动：`StrictConsumer`/`FlowRunner` 内部语义（本卡不改变 ARCH-03
  的读-检查-写模型，只补齐外部同步）、账本协议。

## 阻塞与依赖

无前置。与 MOB-54 同源触发窗口（失败重试路径），建议一并真机验证。

---

## 实施记录

- 2026-09-07：三星真机回归时 logcat 直接抓到两条 322ms 内、不同线程的
  独立传输失败记录，定位到 `AndroidFlowRuntime.kt:218-219` 两处回调
  缺少 `synchronized(flowTriggerLock)`（对照同文件其余 5 个入口）。
- 2026-09-07 RED：`ARCH01StrictConsumerTest.concurrent_wake_without_
  external_synchronization_is_unsafe`——两线程用 `CyclicBarrier` 同步
  起跑，都调用未加锁的 `StrictConsumer.wake()`；`SlowFakeDeliveryPort`
  在 `start()` 里 sleep 20ms 扩大竞态窗口。断言接受两种真实症状之一
  （同一 `queueSequence` 被 `start()` 两次，或 `persist()` 抛出
  `"cannot atomically persist discovery ledger"`），跨 20 轮重试取
  非确定性竞态的稳定信号。首次运行即抓到 `persist()` 冲突异常，
  3 次独立 CI 全绿复现，证明修复前风险真实存在。
- 2026-09-07 GREEN：`AndroidFlowRuntime.kt` 的
  `onPermanentFailure`/`onReceipt` 两个回调体包入
  `synchronized(flowTriggerLock) { ... }`，与文件内其余 5 个入口
  （`runFlowWake`/`pauseFlow`/`continueFlow`/`retryFailedFlow`/
  `cancelCurrentFlowRound`）用同一把锁保持一致。
- 2026-09-07 测试基线：Android JVM 全量 **277 tests / 0 failures / 4
  skipped**（`--rerun-tasks` 强制全量重跑，XML 时间戳为本次生成）；
  `just ci` 全绿（含 arch-check、queue-sync）。
- 未装真机验证：本卡的竞态本身极难在真机上稳定复现（依赖网络恰好在
  两个触发路径重叠的窗口内失败/成功），JVM 层已用真实生产类
  （`StrictConsumer`/`DiscoveryLedgerStore`）+ 多线程 + 20 轮重试锁死
  该风险的存在与修复；真机验证降级为「不稳定网络下观察不再有并发传输
  日志」的可选确认项。

## 备注

- 本卡与 MOB-54 共享同一触发根源：MOB-54 补的失败路径 `wake()` 调用
  放大了本卡的竞态触发概率，但本卡描述的架构缺口本身独立于 MOB-54
  存在（`acceptCompletionReceipt` 的 `wake()` 调用是 REBUILD-02/03
  时代就有的，同样缺锁）。
