# MOB-53 UI-09 上线前已 CONFIRMED 的旧账本条目 completedAt 永远为 0，首页永久显示「从未成功备份过」（L1）

> 🟡 状态：开工中（本 agent 认领，2026-09-07 三星真机验证顺带发现即接） ·
> 当前节点：写 RED 用例 · 下一步：GREEN 实现 + JVM 全量 + APK · 协同分支：`main`
> 级别：L1 · 阻塞：无

## 问题

2026-09-07 三星 SM-S9210 真机验证 test.6（含 UI-09/MOB-51）时直接复现：
首页英雄区同时显示「37 / 38 张已回家」和「还没有成功备份过」——两句话
自相矛盾，且**永久性**，不会随时间/后续备份自愈。

根因（真机账本文件 + 源码核实）：

1. `TransferItem.completedAt`（`DiscoveryLedger.kt:121`）是 UI-09（09-06）
   才加进 schema 的新字段，默认值 0，靠 `encodeDefaults`+`ignoreUnknownKeys`
   兼容旧账本文件。
2. 该字段只在 `CompletionAndScope.kt:58` 的 receipt 确认路径写入
   （`acceptCompletionReceipt`）。这台真机上 37 张 `CONFIRMED` 照片全部是
   在 UI-09 上线**之前**就已经传完的旧数据——它们不会再走一次 receipt，
   `completedAt` 永远留在 schema 默认值 0。
3. `flowAggregateOf`（`FlowUiProjection.kt:38-51`）里 `lastSuccessAt` 只取
   `CONFIRMED` 项里 `completedAt` 的最大值——全体是 0 时聚合结果也是 0。
4. `lastSuccessOf(ts, now)`（`BackupStatus.kt:114-115`）把 `ts<=0` 恒判定为
   `LastSuccess.Never` → 首页渲染「还没有成功备份过」（`last_success_never`
   字符串资源）——这与 M=37（真实、来自同一账本）当场对撞。

**这是 UI-09 迁移引入的新缺陷，与 UI-10（诊断已有、未开工的空快照/死 UI
问题）是两个不同的根因，不要合并处理。**

## 期望行为

- 已 `CONFIRMED` 但 `completedAt<=0` 的旧账本条目，在账本加载/迁移时一次性
  补盖时间戳（复用 `CompletionAndScope.kt:58` 已确立的模式：`takeIf { > 0 }
  ?: System.currentTimeMillis()`），并持久化写回，不是每次读时算出来又丢弃。
- 迁移只针对 `deliveryState == CONFIRMED && completedAt <= 0` 的条目；不改变
  其它字段、不触发新的 receipt、不影响 `CANCELLED_*` 项。
- 迁移后本卡描述的自相矛盾状态在真机上消失：显示「37/38 已回家」+ 一个
  非空的「最近成功」时间（哪怕是迁移当刻的时间，不是编造的历史时间——
  没有更早的可靠事实源，迁移当刻是唯一诚实的选择）。

## 验收标准

- [ ] RED：JVM 用例构造「账本含若干 `CONFIRMED` 条目、`completedAt=0`」
      的快照（模拟 UI-09 上线前的存量数据），断言迁移前 `flowAggregateOf(...)
      .lastSuccessAt == 0`（复现本卡缺陷）。
- [ ] GREEN：迁移逻辑跑过之后，同一批 `CONFIRMED` 条目 `completedAt > 0`，
      `flowAggregateOf(...).lastSuccessAt > 0`，`lastSuccessOf` 不再落
      `Never` 分支。
- [ ] 迁移是幂等的：对已有正确 `completedAt` 的条目不改动、重复触发不重
      复回填、不改变时间戳（有用例锁死幂等性）。
- [ ] 反证：把迁移逻辑临时禁用，上条用例必须变红。
- [ ] Android JVM 全量绿（报测试计数）+ debug APK + `just ci`。
- [ ] 真机：本卡在其触发的设备上，「M/N 已回家」与「最近成功」文案不再
      同屏矛盾（验收人确认或本 agent 用 adb 读取 discovery-ledger.json +
      UI dump 交叉验证，不强制要求验收人操作）。

## 范围

- 只准动：`backup/flow/DiscoveryLedger.kt`（加载/迁移逻辑）、
  `backup/flow/FlowUiProjection.kt`（如需要）、对应 JVM 测试、卡片/队列/
  进度文档。
- 不准动：`CompletionAndScope.kt` 的 receipt 确认路径本身（正常路径没有
  bug，问题只在存量迁移）、UI-10 范围内的文件、桌面端。

## 阻塞与依赖

无前置、无阻塞；与 UI-10 是并行的两个独立缺陷，可任选一个先做。

---

## 实施记录

- 2026-09-07：三星 SM-S9210 真机复现（本 agent 构建 debug APK 装机验证，
  同时发现手机上原装 APK 已停留在 2026-09-02，比 test.4/test.6 都老——
  这是 Git 同步核对时顺带确认的另一件事：远端代码本身没有滞后，是设备上
  的安装包滞后，已在本次验证中用新构建覆盖）。账本文件路径：
  `files/flow-state/<daemonNodeId>/discovery-ledger.json`，38 项中 37
  `CONFIRMED` / 1 `CANCELLED_BY_USER_ROUND`，全部 `completedAt: 0`。
