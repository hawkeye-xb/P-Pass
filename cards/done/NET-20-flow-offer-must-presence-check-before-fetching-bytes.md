# NET-20 Flow 单通道 `offer` 缺传输前哈希对齐——已存在内容仍整份重传　级别 L1

> ✅ 状态：已修复并通过 `just ci` · 协同分支：`main`
> 级别：L1 · 阻塞：无
> **背景**：2026-09-16 用户对话核实发现，NET-06 把 Flow 重构成单条通道
> （offer 秒回 + 后台 spawn 抓取 + 轮询 status）时，遗漏了旧批量管线
> （`backup.manifest`/`backup.presence`）本来就有的「传输前查重」能力。
> **决定**（用户拍板"顺手做了"）：命中已存在内容时复用现有
> `complete_flow_grant`/`FlowCompletionReceipt` 完成路径，**不新增协议
> 字段**——手机侧看到的仍是"这个 tuple completed 了、这是它的
> receipt"，无法从线上协议区分"真传了"还是"跳过了"，这是本卡刻意的
> 最小改动范围（卡内验收标准原话："不要自己定新协议字段"）。

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
文件重新算一遍 BLAKE3、查 `get_asset`，命中才判 `Duplicate` 丢弃。

## 实现

`offer_inner` 在 `checked_request`/`provider_for`/`rebind_completed_flow_grant`
（tuple 级幂等）之后、`spawn_fetch_task` 之前，新增一次内容库查询：

- 新增 `core_index::Ingestor::has_durable_copy(&hash) -> Result<bool>`——
  不是简单 `get_asset(hash).is_some()`，而是与 `ingest_inner` 自己判断
  Duplicate 的逻辑同构：索引有行 **且** `existing.rel_path` 在磁盘上真实
  存在才算"已有持久副本"（否则是 WATCH-03 场景：文件被外部删除后同一
  内容在别处重新出现，仍然需要真的接收）。两处判断如果各写一套逻辑，
  日后维护者很容易只改一边导致行为分裂——这是有意让它们共享同一份
  判据的原因。
- 命中 → `complete_without_fetch`：不碰数据面，直接生成新
  `receipt_id`、调用现有的 `complete_flow_grant`（与真实传输成功后
  完全相同的收尾路径），并 `emit_flow_delivered` 推送给手机——手机侧
  代码零改动，`status()`/`fetch()` 轮询到的是与真实完成一模一样的
  `completed` + receipt。
- 未命中 → 走原有路径（`spawn_fetch_task`），行为不变。

## 验收标准

- [x] RED 先行：`offer_skips_the_network_fetch_when_content_already_has_a_durable_copy`——
      库中已存在某 hash 对应的 asset（真实写入磁盘文件，不是只插一行
      索引），对**不同 tuple**（不同 queue_sequence/lease_token）offer
      同一个 content_hash，provider 地址故意给一个语法合法但从不可能
      被拨通的 fixture，断言：`status()` 立即读到 `completed` 状态和
      非空 receipt——如果代码真的尝试发起网络抓取，这个 fixture 地址
      会让 `offer` 直接报错，测试因此能捕捉"是否真的跳过了网络"。
- [x] 反证：临时把 presence 短路分支替换为 `if false`，上述测试从
      "立即 completed"变成"active"（新旧状态不同，`assert_eq!` 报
      `left: "active", right: "completed"`）——证明测试真的在钉这条
      短路逻辑，不是碰巧通过。已恢复。
- [x] `offer_still_fetches_when_content_is_not_yet_in_the_library`——
      库中不存在该 hash 时，行为与改动前完全一致（真的发起抓取并
      完成），防止误伤正常传输路径。
- [x] 现有 NET-06/NET-15~19 相关测试全部保持绿：
      `cargo test -p daemon --test flow_delivery` **28/28**（26 原有 +
      2 新增）。
- [x] `cargo test -p core-index` 全绿（`has_durable_copy` 复用现有
      fixture，无新增测试文件）。
- [x] `just ci` 全绿。

## 范围

- 改动：`crates/core-index/src/ingest.rs`（新增
  `Ingestor::has_durable_copy`）、`crates/daemon/src/flow_delivery.rs`
  （`offer_inner` 插入短路 + 新增 `complete_without_fetch`）、
  `crates/daemon/tests/flow_delivery.rs`（2 条新测试）、卡片/队列文档。
- 未动：`proto` 线格式（如卡内决定，未加字段）、Android 侧代码、旧批量
  管线 `backup.rs`。

## 阻塞与依赖

无前置。不阻塞 NET-06 归档（NET-06 归档只等 NET-15~19 五张子卡），本卡
是并行的独立缺口，不合并进 NET-06 也不算它的验收项。

**留白**：仅本地测试 + `just ci`，未做真机验证（需要构造"桌面已有某照片，
手机重新 offer 同内容不同 queue_sequence"的真实场景，比如断连重试或跨
设备互传同一批照片）。
