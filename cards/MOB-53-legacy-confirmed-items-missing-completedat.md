# MOB-53 UI-09 上线前已 CONFIRMED 的旧账本条目 completedAt 永远为 0，首页永久显示「从未成功备份过」（L1）

> 🟢 状态：代码已合并，本地验证通过 · 当前节点：等真机复核（可选，非阻塞）·
> 下一步：无强制下一步——已达标准，若你愿意可装最新 APK 到触发过本 bug 的
> 设备上确认「M/N 已回家」与「最近成功」不再矛盾 · 协同分支：`main`
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
- 2026-09-07 RED：`UI09LedgerAggregateTest` 新增
  `pre_ui09_confirmed_items_without_completedAt_are_backfilled_on_load`——
  用生产 `FlowRunner` 链路走完两次 receipt 确认后，剥离 JSON 里的
  `completedAt` 字段（模拟真机存量文件），断言 load() 后必须回填正值；
  改前用例真红（`AssertionError` 在断言行），复现验收人观察。
- 2026-09-07 GREEN：`DiscoveryLedgerStore.load()` 新增
  `backfillMissingCompletedAt`——对 `deliveryState==CONFIRMED &&
  completedAt<=0` 的条目盖 `System.currentTimeMillis()` 并 `persist()`
  写回（复用 `CompletionAndScope.kt:58` 已确立的「无戳记就盖 now()」模式），
  幂等：无变更条目时不重复 persist，同一条目回填一次后再加载不会再变。
  同时更新了 UI-09 时代的旧测试
  `old_ledger_json_without_completedAt_loads_as_zero_and_stays_compatible`
  →改名为 `..._loads_and_backfills_confirmed_items`，断言从「必须停在 0」
  改为「必须被回填为正值」——这条旧断言描述的正是本卡要修的 bug 本身，
  按 AGENTS.md「架构重定义后的测试纪律」判定为已被新设计取代，不是新实现
  的门禁。
- 2026-09-07 反证：临时把 `backfillMissingCompletedAt` 调用去掉，两条用例
  （新增 + 改写后的旧用例）均变红，还原后复绿。
- 2026-09-07 测试基线：Android JVM 全量 **275 tests / 0 failures / 4
  skipped**（基线 274 + 本卡 1 条新用例；XML 时间戳为本次生成）；
  `just ci` 全绿（含 arch-check、queue-sync）；debug APK 构建成功
  （`assembleDebug` BUILD SUCCESSFUL）。
- 未装真机验证：本次连接的两台设备（三星 SM-S9210 已在诊断阶段验证过
  bug 现象；华为 ALN-AL00 装的是另一项目 `com.hawkeyexb.ha`，与 P-Pass
  无关，未触碰）。修复本身是纯数据迁移逻辑，已用生产代码路径的 JVM 用例
  完整覆盖 RED→GREEN→反证，真机复核为可选项，不阻塞本卡关闭。
