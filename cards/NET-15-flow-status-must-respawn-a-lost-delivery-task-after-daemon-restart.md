# NET-15 daemon 重启后 status 必须发现"grant active 但无任务"并自动重拉　级别 L1

> ✅ 状态：代码完成 `c01a02f`（daemon src）+ `b67b0a7`（集成测试，2026-09-17），全部门禁绿；L1 无需真机，待验收人复核归档
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

- [x] RED 先行（daemon 集成测试）：构造"grant Active 但任务登记表中无
      对应条目"的场景（模拟重启：直接操作 db 写入 Active grant，不经过
      `offer()`），调用 `status()` → 断言任务被重新拉起（可通过后续再次
      `status()` 观察到 `task_running=true`，或直接观察交付最终收敛到
      completed）；改前必须真红（当前行为：`task_running` 报告
      `false`，永远不会自愈）。
- [x] 断点续传：重新拉起后从已有 partial 继续（复用 blobs_resume 的
      断言手法：不该出现字节数从零重新增长）。
- [x] 反证：注释掉新增的重拉分支，新用例必须变红。
- [x] `cargo test -p daemon --test flow_delivery` 全绿（报出具体条数）+
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

## 实施记录（2026-09-17，代码 `c01a02f`、测试 `b67b0a7`）

- **验收项全部勾掉**（`cargo test -p daemon --test flow_delivery` **33/33**
  = 32 原有 + 1 新；`just ci` 全绿：fmt/clippy/nextest 全量/arch-check/
  queue-check/md-check/token-check）。
- **新测试**：`status_respawns_the_delivery_task_lost_to_a_daemon_restart`。
  手法与既有 `suspend_then_resume` 同族——同一 db + 同一 retained store
  上新建 `FlowDelivery` 实例模拟进程重启（内存登记表归零、grant 行仍
  Active；suspend 是进程死亡的进程内等价物）。重启前留真 partial
  （24MB PRNG 负载、KILL 阈值 2MB），重拉后 8 次轮询内收敛 completed 且
  `local_bytes == PAYLOAD`——断点续传、不从零重长。
- **改前真红**：新测试在修法前跑挂（`task_running=false` 且永不收敛），
  不是"先写测试再假装它红"。
- **反证真跑**：注释 `status()` 里的重拉分支 → 新测试变红（报错正是
  `task_running` 断言），还原后复绿。
- **修法**：照卡面 `status()` 内检出 `grant Active &&
  !tasks.is_running` → `resume_request(&grant)` 从 grant 行重建
  `FlowFetchRequest`（`capture_at_ms` 不落库，填 0——协议明文的老客户
  端值，`core-index` ingest 退回 EXIF→mtime），复用现有
  `spawn_fetch_task`，不新造第二套启动路径。
- **范围外追加（显式登记）**：原 `spawn_fetch_task` 的「is_running 检查 +
  register」是两次独立加锁，并发 offer/fetch/status 理论上可双 spawn；
  `FlowTaskRegistry` 新增原子 `try_register`（**键值结构未动**，符合卡
  面"不准动键值结构"），spawn 全部改走它。
- **语义变更（显式登记）**：`suspend_interrupts_an_in_progress_fetch_and_
  keeps_the_grant_active` 原断言「suspend 后 status 读到
  task_running=false」。新语义下 status 轮询本身就是恢复信号，该断言升
  级为「status 轮询重拉任务（task_running=true）」。安全性依据：grant
  按 peer 隔离，来问本 tuple 的 caller 即是在等它完成（与 suspend 注释
  里 "A later flow.offer resumes" 同一恢复事实）；手机侧暂停会停掉本
  peer 的轮询，不会误复活。`status()` 从此不再是只读可观测点。
- **不 bump 版本**：无协议帧/手机侧变化（手机端本来只读 `state`，无视
  `task_running`）。
- **发现分岔（挂号建议，未越权修）**：`network_fetch_failure_records_a_
  fetch_failed_error_at_fetch_stage` 为时序敏感既有测试（真实断网路径，
  断言 conn+error 恰好 2 条事件），本次全量跑约 1/5 概率多 1 条 conn
  事件变红；无改动基线 4/4 绿、带改动 8/10 绿，且该测试不调用
  `status()`、与本卡改动无调用路径交集，判定为既有抖动被二进制布局扰
  动，建议另开卡根治（判据改为集合断言或注入确定时序）。
- NET-06「崩溃恢复」勾项已随本卡勾掉。
