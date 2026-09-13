# MOB-76 「仅 Wi-Fi 时备份」开启时蜂窝网络仍发起传输（L1）

> 🟨 状态：进行中（Hermes 认领 2026-09-13）
> 级别：**L1** · 阻塞：无
> 当前节点：断点已定位（见实施记录），RED→GREEN 实现中 · 协同分支：`main`

## 问题

2026-09-12 OPPO（ColorOS）真机狗粮（v0.5.1，走查记录
`docs/evidence/2026-09-12-oppo-051-dogfood.md`）：手机使用 5G 蜂窝网络，
设置中「仅 Wi-Fi 时备份」处于**开启**状态，用户发起备份后传输仍然被启动
（在蜂窝链路上尝试、失败）。验收人因此手动关闭了该开关。

约束开关必须是硬闸门：开启状态下任何触发路径（前台手动「开始备份」、
相册选择、范围唤醒）都不应向蜂窝/中继路径发起实际传输，而应显示既有的
「将在连接 Wi-Fi 后进行」等待态。这与 MOB-71 不重叠——MOB-71 管的是
**关闭**限制后暂停态不再显示 Wi-Fi 等待文案（呈现层），本卡管的是**开启**
限制时约束没有被执行（闸门层）。

## 期望行为

「仅 Wi-Fi 时备份」开启且当前无 Wi-Fi 时：不发起任何 Flow 交付尝试
（零网络外呼），首页显示真实的 Wi-Fi 等待状态；网络恢复 Wi-Fi 或用户
关闭限制后按既有唤醒路径继续。

## 验收标准

- [ ] RED→GREEN：构造「Wi-Fi 限制开启 + 网络类型蜂窝」下用户点击「开始
      备份」，断言 delivery 外呼次数为 0 且投影为 Wi-Fi 等待；改前用例
      必须复现「照常发起传输」。
- [ ] 自动化：覆盖全部触发入口（手动开始、相册选择后的范围唤醒、
      前台补捞），限制开启时行为一致。
- [ ] 反证：把闸门判据从当前网络实时状态改回触发时快照，焦点用例必须
      失败（防瞬态标记复活 MOB-71 同族问题）。
- [ ] 真机：蜂窝网络 + 限制开启 → 发起备份 → 无传输、显示 Wi-Fi 等待；
      连上 Wi-Fi 后自动续传。
- [ ] Android JVM 全量绿（报测试计数）+ debug APK + `just ci`。

## 范围

- 只准动：Android 侧 Wi-Fi 约束在 Flow 交付入口的执行点（网络检查与
  Flow wake/开始备份的接线）、相应 JVM 测试。
- 不准动：MOB-71 已定型的暂停态文案投影、Flow 严格消费者语义、
  WorkManager 调度策略、桌面端。

## 阻塞与依赖

无。开工前先取证：当次失败传输的外呼发生在哪条触发路径（手动「开始
备份」按钮 vs 范围唤醒），以真实断点圈定闸门位置，不凭猜测补检查。

---

## 实施记录

- 2026-09-13（Hermes 认领，卡面前置取证完成）：无需口述回忆，代码考古直接
  钉死断点链——
  1. **触发入口的 `constraintsSatisfied` 确实实算**（MainActivity 选相册/
     进入 App 两处 `!settings.wifiOnly || isOnUnmetered(context)`），走这一次
     会正确落 `WAITING_FOR_CONSTRAINTS`；
  2. **但 FlowRunner 事件后 wake 全部硬编码放行**：`acceptCompletionReceipt`、
     `recordPermanentFailure`、`retryFailedDeliveries`、`skipMissingSource`、
     `cancelCurrentRound`、`restoreAllCancelledRounds`、`StrictConsumer.continueByUser`
     共 7 处 `wake(constraintsSatisfied = true)`，外加 `BackupWorker.doWork()`
     把 worker 约束满足**直接当**业务闸门（`runFlowWake(constraintsSatisfied =
     true)`）。结果：限制开启时第一次 wake 正确进等待态，之后**任何一张完成
     回执/一次失败重排都会把队头照常推上蜂窝**——与 09-12 观察 5→6 时序
     （先传 10 张、期间开关开着）完全同形。
  3. 与 MOB-19「手点零约束」的关系：本卡卡面（09-12，晚于 MOB-19）明确
     把「前台手动『开始备份』」列为**必须过闸门**的触发路径——即验收人已
     拍板在**交付层**覆盖 MOB-19（手点不再豁免 Wi-Fi 限制）；`constraintsFor(MANUAL)`
     的 WorkManager 调度约束不动（何时允许跑 vs 往哪条网络发是两层）。
- 修复方案（结构性消除，不留特征补丁）：`FlowRunner` 注入实时约束端口
  `constraintsProvider: () -> Boolean`，AndroidFlowRuntime 以
  `wifiOnly → isOnUnmetered` 实算接线（注入点默认 true，JVM 测试构造不动）；
  全部事件后 wake 改走该端口。RED 覆盖「限制开启 + 蜂窝下完成回执不得推进
  下一张」与「retry/continue 同闸」；反证 = 把端口调用退回常量 true 必红。
