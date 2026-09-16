# NET-15 daemon 重启后 status 必须发现"grant active 但无任务"并自动重拉　级别 L1

> ⬜ 状态：未开工 · 协同分支：`main`
> 级别：L1 · 阻塞：无（可立即开工，daemon 单机内可测）
> **从 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md) 拆出**：
> 是 NET-06「期望行为④ 崩溃恢复」一直标注"未实现"的那一项，NET-06 本卡
> 不再挂它，由本卡独立收尾。完成后回 NET-06 勾掉对应验收项并更新其
> QUEUE 状态。

## 问题

`flow_delivery.rs::status()`（第 809-840 行）只读 `matching_grant`/
`flow_receipt` 拼出 active/completed/cancelled/not_found 四态，外加进程内
`task_running`（`self.tasks.is_running(peer, &grant)`）这一事实——但当
`task_running=false` 且 `grant.state == Active` 时，`status()` 只是如实
汇报"没有任务在跑"，不会做任何事。daemon 进程重启后，内存里的任务登记表
（`FlowTaskRegistry`/`tasks`）随进程消失，而 durable 的 `flow_delivery`
表仍然记着这个 grant 是 Active——这正是"grant active 但无运行任务"的
真实触发条件，此刻却没有代码把交付任务重新拉起来。手机侧轮询/推送等待
永远等不到完成信号，只能靠外部触发（重开 App/切相册）才会发现异常并
重新 offer。

## 期望行为

`status()` 检测到 `grant.state == Active && !task_running` 时，应在
返回结果前（或作为副作用）重新 `spawn` 交付任务——复用 `offer_inner()`
既有的 spawn 逻辑，不新造第二套启动路径。iroh-blobs 的 `FsStore` 本身
支持断点续传（`blobs_resume` 集成测试已验证跨重启场景），重新拉起后应从
上次的 partial 继续，而不是从零开始。

## 验收标准

- [ ] RED 先行（daemon 集成测试）：构造"grant Active 但任务登记表中无
      对应条目"的场景（模拟重启：直接操作 db 写入 Active grant，不经过
      `offer()`），调用 `status()` → 断言任务被重新拉起（可通过后续再次
      `status()` 观察到 `task_running=true`，或直接观察交付最终收敛到
      completed）；改前必须真红（当前行为：`task_running` 报告
      `false`，永远不会自愈）。
- [ ] 断点续传：重新拉起后从已有 partial 继续（复用 blobs_resume 的
      断言手法：不该出现字节数从零重新增长）。
- [ ] 反证：注释掉新增的重拉分支，新用例必须变红。
- [ ] `cargo test -p daemon --test flow_delivery` 全绿（报出具体条数）+
      `just ci` 全绿。

## 范围

- 只准动：`crates/daemon/src/flow_delivery.rs`（`status()` 内新增重拉
  分支，复用 `spawn_fetch_task`/`offer_inner` 已有逻辑）、
  `crates/daemon/tests/flow_delivery.rs`（新测试）、卡片/队列文档。
- 不准动：`FlowTaskRegistry` 键值结构、`suspend`/`cancel` 语义、协议帧
  格式、Android 侧代码（这是纯 daemon 侧修复，手机侧无需感知）。

## 阻塞与依赖

无前置，无下游。完成后需回写 [NET-06](NET-06-flow-delivery-async-202-reconcile-ledgers.md)
勾掉"崩溃恢复"验收项。
