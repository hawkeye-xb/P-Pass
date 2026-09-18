# MOB-56 失败/接收回调绕过 flowTriggerLock，可致同一队头并发双发（L0）

> 🟢 状态：**已完成（2026-09-18 关卡）**——代码已合并 + 源码门禁守住不变量；
> 真机项实测改判为无判别力。遗留的架构层问题（这条「缝」本身可以再次出现）
> 不在本卡，已挂到 issue #162。
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
- [x] 门禁：源码扫描测试锁死「`AndroidFlowRuntime.kt` 每个 `runner.*`
      状态变更调用都在 `synchronized(flowTriggerLock)` 词法范围内」，
      撤掉任一处锁必红。
- [x] Android JVM 全量绿（报测试计数）+ `just ci`。
- [x] 真机：**2026-09-18 实测改判为「无判别力」，不作为验收依据**。撤掉
      两个回调的锁做对照组（`0.5.4-test.11`）与修复版（`test.10`）跑同一
      剧本，判定结果完全相同（各 13 个回调临界区 / 0 重叠 / 0 双发）——
      ARCH-03 的严格单活跃租约让回执天然顺序到达（相邻段间隔 15-20ms、
      段长 150-210ms），真机上施加不出「两条不同来源的触发交叠」这个
      触发前提。详见 issue #107 的实测评论。

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

- 2026-09-18 回归复核（基线 `e1bd1da9`）：
  - 静态穷举——文件内 10 处 `runner.*` 状态变更调用全部在
    `synchronized(flowTriggerLock)` 内；`flowTriggerLock` 是本文件
    private 顶层 val，全仓无其他引用，无外部持有 `runner` 的代码；
    `FlowRunner`/`StrictConsumer` 内部零异步派发（无 `thread(`/`launch`/
    `Handler`/`post`/`Dispatchers`），所以在回调点加锁是有效的——否则锁
    会在派发时就释放。
  - **发现 GREEN 行此前只有源码 review、没有自动化门禁**：把 392/393
    两行的 `synchronized` 摘掉，Android JVM 全量 406 tests / 0 failures
    照样全绿。卡里的 RED 用例直接驱动 `StrictConsumer.wake()`、不经过
    `AndroidFlowRuntime`，证明的是「没锁会炸」而不是「回调有锁」。
  - 补 `MOB56CallbackLockGuardTest`（同 `MOB62RuntimeInitializationTest`
    的源码扫描做法）：按花括号深度判定词法范围，注释/字符串先整段置空
    以免干扰配平；另有反空转断言（调用点少于 10 处即红，防重命名后
    在空集上无条件通过）。
  - 双向突变验证：①撤掉 392/393 的锁 → 红，报 `392: recordPermanentFailure`
    `393: acceptCompletionReceipt`；②把扫描正则改成扫不到的名字 → 红，
    报 `found 0 — the guard is vacuous`。还原后 Android JVM 全量
    **407 tests / 0 failures / 4 skipped** + `:app:lintDebug` 绿。
  - 真机那条仍未勾：它是「不稳定网络下观察不到并发日志」的否定性观察，
    而本卡的竞态按卡面自述极难稳定复现——跑一轮没看到与运气好不可区分，
    不作为验收证据。

## 备注

- **架构层遗留（本卡不解决，已挂 #162）**：本卡补的是外部同步，没有消除
  「缝可以再次出现」这件事——不变量横跨读账本→判断→起传输→写账本四步、
  状态在磁盘上，而保护它的 `flowTriggerLock` 放在被保护对象**外面**
  （`StrictConsumer.wake()` 内部零同步，靠调用方串行化的约定）。第 8 个
  入口进来的人照样可能漏拿锁；门禁是守约定，不是消灭约定。真正消灭它的
  三条路（锁收进 `StrictConsumer` / 所有触发投递单消费者队列 / 账本写回
  改 compare-and-swap 让竞态立刻炸）都超出本卡范围，在 #162 里一起评估。
- 2026-09-18 新发现的**同类但独立**缺口（不在本卡范围，需另开卡评估）：
  `runtimeFor` 的构造段本身没有互斥——两个线程同时为同一 key 构造，会
  各自建一个 `FlowRunner` 并各跑一次 `runner.reconcileProcessStart()`，
  写的是同一份磁盘账本。门禁把这一处列为唯一白名单例外（构造期 runner
  还没写进 `flowRuntimes`，单个构造流内无并发触发），例外理由与这条
  留白都写在测试的 `PRE_PUBLICATION` 注释里。
- 本卡与 MOB-54 共享同一触发根源：MOB-54 补的失败路径 `wake()` 调用
  放大了本卡的竞态触发概率，但本卡描述的架构缺口本身独立于 MOB-54
  存在（`acceptCompletionReceipt` 的 `wake()` 调用是 REBUILD-02/03
  时代就有的，同样缺锁）。
