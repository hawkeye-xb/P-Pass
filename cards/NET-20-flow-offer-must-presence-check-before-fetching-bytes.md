# NET-20 Flow 单通道 `offer` 缺传输前哈希对齐——已存在内容仍整份重传　级别 L1

> ⬜ 状态：未开工 · 协同分支：`main`
> 级别：L1 · 阻塞：无
> **背景**：2026-09-16 用户对话核实发现，NET-06 把 Flow 重构成单条通道
> （offer 秒回 + 后台 spawn 抓取 + 轮询 status）时，遗漏了旧批量管线
> （`backup.manifest`/`backup.presence`）本来就有的「传输前查重」能力。

## 问题

旧批量管线（`crates/daemon/src/backup.rs::manifest`/`presence`）的形状是：
手机先把待传 hash 清单发过来，daemon 查本地 `asset` 表
（`db.get_asset(&hash)`），只把库里没有的 hash 回给手机（`missing`），
手机只传那些真正缺的文件——**这是传输前的哈希去重**。

新的 Flow 单通道管线（`crates/daemon/src/flow_delivery.rs::offer_inner`，
NET-06）里，`offer` 只做了两件事：
1. `rebind_completed_flow_grant`——判断这条 **tuple 自己**是不是已经传完过
   （重试幂等，不是查内容库）；
2. `spawn_fetch_task` 的幂等检查——同 tuple 是否已有任务在跑。

**它从未调用 `db.get_asset(&hash)`。** 于是 `offer` 无条件
`spawn_fetch_task` → iroh-blobs 把整个文件字节真的拉下来、`export_to`
落到 staging，直到 `materialize` 阶段调 `Ingestor::ingest()` 时才对本地
文件重新算一遍 BLAKE3、查 `get_asset`，命中才判 `Duplicate` 丢弃
（`crates/core-index/src/ingest.rs:117`）。

也就是说：**同一张照片/视频，哪怕桌面本来就有，现在也会把整份字节真的
传一遍，传完才发现是重复的，再扔掉。** 对大文件（真机验收用的 224MB
视频）这不是小事——原图被误删重新扫描、跨设备互传同一批照片、断连重试
后手机侧游标没推进导致重复 offer 等场景都会命中，每次都白传一份完整
文件，直接影响传输体验（时间、流量、以及未来 relay 计费口径）。

这不是"叫法不同"，是 NET-06 重构核心管道时真实漏掉的一块业务逻辑——
事后去重（ingest 阶段）能保证正确性，但传输前去重（offer 阶段）这层
效率保障在新管道里从未被搬过来。

## 期望行为

`offer_inner` 在 `checked_request` 拿到 `content_hash` 之后、
`spawn_fetch_task` 之前，先查一次本地内容库：
- 若 `db.get_asset(&hash)` 命中（内容已在库里）：**不发起 iroh-blobs
  抓取**，直接落一个等价于"完成/重复"的终态（不新建 grant 的 Active
  抓取任务），让手机侧 `status` 轮询直接看到 completed/duplicate，
  不必等一次真实传输。
- 若未命中：走现有路径（spawn 抓取）。
- 这一步是纯读，不改变现有幂等语义（`rebind_completed_flow_grant`、
  tuple 级去重）——两层去重的关系是"tuple 幂等在前，内容库存在性检查
  在后，均未命中才真正发起抓取"。

## 验收标准

- [ ] RED 先行：新增 daemon 集成测试——库中已存在某 hash 对应的 asset，
      手机对**从未见过的新 tuple**（不同 queue_sequence/lease_token）
      offer 同一个 content_hash，断言：`spawn_fetch_task`/
      `fetch_from_observing_path` 从未被调用（用现有的
      `tasks.is_running()` 或 native provider 抓取计数断言），且
      `status()` 很快能读到一个完成态/重复态而不必等数据面。
- [ ] 反证：临时去掉新加的 presence 短路分支，上述测试必须变红；恢复后
      复绿。
- [ ] 现有 NET-06/NET-15~19 相关测试（tuple 级幂等、崩溃重拉、迟到竞态）
      全部保持绿——新加的内容库检查不能破坏"同一 tuple 的正常抓取流程"。
- [ ] 补一条集成测试：库中不存在该 hash 时，行为与改动前完全一致（真的
      发起抓取），防止误伤正常传输路径。
- [ ] `cargo test -p daemon --test flow_delivery` 全绿（报出具体条数）+
      `just ci` 全绿。
- [ ] 需要用户拍板：命中已存在内容时，`materialize`/`status` 应该返回
      什么样的 receipt（是否需要一个新的 `content_hash` 匹配但
      `queue_sequence` 不同的"跳过"终态？还是复用现有
      `IngestOutcome::Duplicate` 对应的语义直接走已有的完成路径）——
      写代码前先在卡内或对话里确认这一点，不要自己定新协议字段。

## 范围

- 只准动：`crates/daemon/src/flow_delivery.rs`（`offer_inner`）、
  `crates/daemon/tests/flow_delivery.rs`（新增测试）、卡片/队列文档。
- 不准动：`proto` 线格式（除非验收拍板确认必须加字段——若加字段需同步
  改 Android 侧并升级兼容性判断，另评估是否要开子卡）、Android 侧代码、
  旧批量管线 `backup.rs`。

## 阻塞与依赖

无前置。不阻塞 NET-06 归档（NET-06 归档只等 NET-15~19 五张子卡），本卡
是并行的独立缺口，不合并进 NET-06 也不算它的验收项。
