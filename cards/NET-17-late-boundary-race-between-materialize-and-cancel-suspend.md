# NET-17 迟到边界竞态：materialize 前后各发一次 cancel/suspend 终态必须确定　级别 L1

> ✅ 状态：已完成（PR #191，2026-09-18） · 协同分支：`test/NET-17-late-boundary-race`
> 级别：L1 · 阻塞：无
> **从 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md) 拆出**：
> NET-06 卡内「竞态规则统一：先过 irreversible 边界
> （`complete_flow_grant`）者赢」的设计已经写清楚，但对应的用例从未写，
> 一直标注"未写，留给下一步"。本卡单独把它补上。完成后回 NET-06 勾掉
> 对应项。**已完成，已回写 NET-06。**

## 问题

NET-06 卡内已裁决的竞态规则（原文）：

> 竞态规则统一：先过 irreversible 边界（`complete_flow_grant`）者赢，规则
> 是账本数据不是时序——cancel/suspend 后迟到的 completed status 收敛为
> CONFIRMED（字节没白传，照片确实已备份），不弹 skipped。

但这条规则至今没有被测试锁定：数据面拉取即将完成（即将调用
`complete_flow_grant`）的同时手机侧发出 `cancel`/`suspend`，谁先到、
最终账本状态是什么，完全没有确定性验证。这类竞态只能靠精确注入时序的
集成测试复现，不能靠 sleep 碰运气。

## 期望行为

两个方向都要有确定性用例：
1. **cancel/suspend 先到，`complete_flow_grant` 还没执行** → 最终状态是
   Cancelled（数据没有白传，因为 grant 已在 completed 之前被标记）。
2. **`complete_flow_grant` 先执行完，cancel/suspend 才到** → 最终状态是
   Completed/CONFIRMED（不能因为迟到的 cancel 把已经成功的传输打成
   取消——"字节没白传，照片确实已备份"）。

两种时序都必须是确定性触发（用可控制的 hook/channel 精确排出先后，不是
概率性 sleep）。

## 验收标准

- [x] RED 先行：两个新 daemon 集成测试，分别精确控制"cancel 先于
      complete_flow_grant"和"complete_flow_grant 先于 cancel"的执行顺序
      （参考仓库已有的 kill-race 测试手法，如
      `transport::tests::blobs_resume` 或本卡同族的
      `suspend_interrupts_an_in_progress_fetch_and_keeps_the_grant_active`
      对同步点的精确控制方式），断言各自收敛到规则要求的终态。
      **`cancel_before_complete_flow_grant_converges_to_cancelled` +
      `complete_flow_grant_before_cancel_converges_to_completed`；排序由
      数据证明（24MB payload + 2MB kill 阈值 / durable receipt 可见性），
      无 sleep。**
- [x] 两个用例必须双向都真实触发过对方顺序（不能只测一个方向就假装
      覆盖了竞态）。**每个用例内部各跑两个 item、各覆盖一个方向
      （cancel-first 与 complete-first 都真实驱动）。**
- [x] 反证：把"先过 complete_flow_grant 者赢"的判定去掉/颠倒，至少一个
      新用例必须变红。**真跑：临时撤掉 `cancel_flow_grant`/
      `complete_flow_grant` 的 `AND state = 'active'` SQL 守卫
      （`crates/storage/src/flow_delivery_repo.rs`）→ 两个新用例同时变红
      （panic 于 flow_delivery.rs:2535 / :2682）；恢复守卫后复绿。**
- [x] `cargo test -p daemon --test flow_delivery` 全绿（报出具体条数）+
      `just ci` 全绿。**35 passed / 0 failed（跑了两遍）；just ci 各 lane
      全部 exit 0。**

## 范围

- 只准动：`crates/daemon/tests/flow_delivery.rs`（新增两个精确时序测试；
  若发现生产代码确实没有正确处理某个方向才允许改
  `crates/daemon/src/flow_delivery.rs`）、卡片/队列文档。**实际只动了
  测试文件（+2 用例，生产代码零改动）。**
- 不准动：`FlowTaskRegistry` 键值结构、协议帧格式、Android 侧代码。

## 阻塞与依赖

无前置，无下游。完成后需回写 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md)
勾掉"迟到边界竞态用例"验收项。**已回写（PR #191）。**

## 实施记录

- 2026-09-18：完成（PR #191，分支 `test/NET-17-late-boundary-race`，基于
  main `c9d0485`）。只动 `crates/daemon/tests/flow_delivery.rs`（+2 用例，
  生产代码零改动）。两个用例各覆盖竞态双向：cancel-first 方向用 24MB
  payload + 2MB kill 阈值证明 fetch 仍在途（`complete_flow_grant` 严格在
  fetch 内部之后执行，此刻边界必未过）→ 收敛 `cancelled`、无回执、重复
  cancel 与迟到 suspend 均 `GuardMismatch`；complete-first 方向用 `fetch`
  返回 durable receipt 证明边界已跨过 → 迟到 cancel/suspend 必败、终态保持
  `completed`、回执存活。反证真跑（撤 SQL 守卫 → 两用例红于
  flow_delivery.rs:2535/:2682，恢复后复绿）。自验：`flow_delivery` 35/35
  全绿（两遍）+ `just ci` 全绿；全 workspace 439/2，2 个失败均为环境/既有
  问题（沙箱缺 HEVC 插件的 heic 用例 + 既有偶发 flaky），与本卡无关。
