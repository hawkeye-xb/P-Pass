# NET-16 completed 后重复 status/fetch 必须零重传字节的直接断言　级别 L1

> ⬜ 状态：未开工 · 协同分支：`main`
> 级别：L1 · 阻塞：无
> **从 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md) 拆出**：
> NET-06 已有 `status_reports_completed_with_the_durable_receipt` 验证了
> "status 读到 receipt"，但从未验证"重复调用不会二次拉取字节"——这是
> 相邻但不同的断言，本卡单独补齐。完成后回 NET-06 勾掉对应项。

## 问题

`persisted_receipt()` 在 grant 已 Completed 时被 `status()`/`fetch()` 复用
来返回同一份 receipt，但仓库现有测试只断言了"receipt_id 相同"，没有断言
"重复调用没有第二次触发数据面拉取"。如果未来有人在 `fetch()` 里加了一条
"每次都重新走一遍 fetch_from_observing_path 保险"式的防御性代码，现有
测试集完全发现不了——这正是本卡要堵的空子。

## 期望行为

对同一个已 Completed 的 grant 连续调用 `status()`/`fetch()` 多次，断言：
1. 每次都返回同一个 `receipt_id`（已有覆盖）。
2. 底层数据面拉取只在最初完成时发生一次，重复调用不产生新的
   `FlowTaskRegistry` 登记、不产生新的 iroh-blobs 拉取活动（可以通过
   `tasks.is_running()` 恒为 false 且 network/blob store 活动计数不增长
   来断言）。

## 验收标准

- [ ] RED 先行：新增 daemon 集成测试——grant 完成后连续调用 `fetch()`
      3 次，断言只有第一次真正触发数据面（若已完成则直接走 receipt 路径，
      不再进 `spawn_fetch_task`），且三次返回的 `receipt_id` 完全相同。
      改前如果这条路径本就正确应保持绿；若引入回归（重复调用又拉一次）
      必须能被此用例抓到——用临时改坏 `fetch()`（去掉"已完成直接返回
      receipt"的短路分支）来验证反证成立。
- [ ] 反证：临时去掉"completed 直接返回 receipt 不重新 spawn"的短路
      分支，新用例必须变红；恢复后复绿。
- [ ] `cargo test -p daemon --test flow_delivery` 全绿（报出具体条数）+
      `just ci` 全绿。

## 范围

- 只准动：`crates/daemon/tests/flow_delivery.rs`（新增测试；若发现
  `fetch()`/`status()` 真的缺短路分支才允许改
  `crates/daemon/src/flow_delivery.rs`，若已存在则本卡零生产代码 diff）、
  卡片/队列文档。
- 不准动：协议帧格式、Android 侧代码。

## 阻塞与依赖

无前置，无下游。完成后需回写 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md)
勾掉"幂等"验收项。
