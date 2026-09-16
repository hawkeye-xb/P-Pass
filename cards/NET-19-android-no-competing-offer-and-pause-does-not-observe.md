# NET-19 Android 侧两项断言补齐：offer 只调一次 + 暂停不观察对端　级别 L1

> ⬜ 状态：未开工 · 协同分支：`main`
> 级别：L1 · 阻塞：无
> **从 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md) 拆出**：
> 这两项都在 NET-06 验收标准里标注"未写专门断言/本条留白"，且都是
> `NativeFlowDeliveryPort.kt`/暂停路径这一侧的收尾，范围相邻，合并一卡。
> 完成后回 NET-06 勾掉对应两项。

## 问题

1. **重试不互踩（offer 调用次数=1）**：`NativeFlowDeliveryPort.kt` 的
   `start()` 现在的实现里 offer 只在循环外调用一次，随后进入
   推送/本地信号/status 轮询循环（`NativeFlowDeliveryPort.kt:292` 之后），
   行为上已经满足"手机侧超时后先看 status/推送，不重发 offer"，但没有
   专门的 JVM 测试断言"整个流程里 `desktop.offer()` 只被调用了 1 次"。
2. **暂停不观察用例**：NET-06 卡内设计原则 1「暂停期间不监控对端状态」
   从未在 Android 侧接线验证——需要确认暂停路径（`StrictConsumer`
   `pauseAutoBackup`/暂停当前轮）触发时，确实不会额外发起
   `status()`/网络查询调用。卡内标注"Android 侧未接线，本条留白"，需要
   先确认这是"缺测试"还是"缺实现"，再补齐。

## 期望行为

- 一个 JVM 测试用例，用 mock/fake `DaemonClient` 断言一次完整的
  offer→等待→completed 流程里，`offer()` 恰好被调用 1 次。
- 一个 JVM 测试用例，触发暂停路径后断言零 `status()`/网络调用；如果
  现状代码确实会在暂停时发起查询（即"缺实现"而非"缺测试"），需要按
  NET-06 原则 1 补上"暂停立即本地生效、不等待/不查询对端"的行为，再补
  测试锁定。

## 验收标准

- [ ] RED 先行：offer 调用次数断言——用 spy/计数 fake 替代
      `DaemonClient.offer`，跑完整个 completed 流程后断言调用次数为 1；
      改前如果本就是 1 次，此用例应直接通过（先确认这是真实现状，不是
      臆测）。
- [ ] RED 先行：暂停零查询断言——触发暂停后断言 fake `DaemonClient` 的
      `status()`/相关网络方法零调用次数；若现状代码在暂停时确有查询，
      此用例应先真红，再修代码复绿。
- [ ] 两个用例都需要反证（人为让 offer 调用两次 / 让暂停触发一次查询，
      确认用例能抓到）。
- [ ] Android JVM 全量绿（报测试计数）+ `just ci` 全绿。

## 范围

- 只准动：`apps/android/app/src/main/java/.../backup/flow/NativeFlowDeliveryPort.kt`、
  `StrictConsumer.kt`（若确认暂停路径缺失"不查询"保证才允许改，改前先
  在卡内记录现状是否已经满足）、对应 JVM 测试文件、卡片/队列文档。
- 不准动：`FlowRunner` 状态机、daemon 侧代码、协议帧格式。

## 阻塞与依赖

无前置，无下游。完成后需回写 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md)
勾掉"重试不互踩"与"暂停不观察用例"两项验收项。
