# BLOB-02 flow-blobs 收件仓永不回收，占盘持续膨胀

> 🟡 状态：代码已合并（commit `c6c0bb6`，已在 `main`），待共享真机回归（2026-09-09）
> 当前节点：`transport::Blobs::open_with_periodic_gc` 新增带 GC 的构造路径，只对外
> 暴露 `[u8;32]` 哈希集合回调（未泄漏 `iroh_blobs` 类型）；`storage::Db::active_flow_content_hashes()`
> 查询 `flow_delivery` 表 `state = 'active'` 的 `content_hash` 集合作为唯一保护判据；
> `main.rs` 构造 `flow_blobs` 时接入该回调，周期 60s。
> 下一步：真机连续传一批照片，`du -sh .ppf/flow-blobs` 记录峰值，等至少一轮 GC 后
> 复测应回落到仅剩「正在传输中」的量级。
> 级别：L2 · 阻塞：真机验收

## 问题

`.ppf/flow-blobs`（REBUILD-02 引入的新 Flow 单条传输收件仓）目前没有任何
回收逻辑，随着传输总量线性增长，用户实测已到"几个 GB"。

根因（源码读取确认）：`crates/daemon/src/flow_delivery.rs` 的 `fetch()`
成功路径——`blobs.fetch_from` 拉取 → `export_to` 拷到 staging →
`ingestor.ingest()` 入库 → `complete_flow_grant` 写 receipt——全程没有一行
调用任何删除/回收接口。`crates/daemon/src/main.rs:336-337` 构造这个独立
store 之后，再没有任何代码路径碰过它。于是每传完一张照片，字节在
`originals` 落一份、在 `.ppf/flow-blobs` 永久多留一份，与 BLOB-01 修复前
`.ppf/blobs` 的泄漏机制完全同构。

这不是旧管线遗留问题：旧批处理管线（`backup.rs` / `.ppf/blobs`）已被
BLOB-01 修复（daemon 启动时整体清空）；REBUILD-03 已让新 Flow 管线
（`flow_delivery.rs` / `.ppf/flow-blobs`）成为手机传照片的**唯一**生产路径。
现在观测到的膨胀 100% 来自新管线，是新管线自身遗留的空当，且会持续增长
直到手动清空。

`BLOB-01` 的"启动时整体清空"策略在这里**不能直接照搬**：REBUILD-02 把
`flow-blobs` 与旧 `.ppf/blobs` 分离的目的就是保住 iroh-blobs 的断点续传
partial（`main.rs:333-335` 注释原话），粗暴清空会连同正在传输的数据一起
清掉，抵消隔离的意义。

## 期望行为

`.ppf/flow-blobs` 里只保留"当前正在传输/未完成"的数据；一个 Flow item
一旦转为 `completed`（已写入 receipt 并入库）或 `cancelled`，其对应内容
应在有限时间内（一轮 GC 周期）被物理回收，不再无限增长。

## 验收标准

- [x] `transport::Blobs` 新增一个启用周期性 GC 的构造路径，对外只暴露
      `[u8;32]` 哈希集合的"当前受保护"回调，不把 `iroh_blobs` 具体类型
      （`Hash`/`GcConfig`/`ProtectCb` 等）泄漏出 `crates/transport`
      （ADR-001 iroh 隔离边界不能破）。——`Blobs::open_with_periodic_gc`，
      公开签名只见 `Fn() -> Pin<Box<dyn Future<Output = Result<HashSet<[u8;32]>>>>>`。
- [x] `storage::Db` 新增查询：返回 `flow_delivery` 表中 `state = 'active'`
      的 `content_hash` 集合——这是回调判据的唯一数据源，天然对齐现有
      `FlowGrantState` 状态机（不新增状态、不改表结构语义）。——
      `Db::active_flow_content_hashes()`。
- [x] `main.rs` 构造 `flow_blobs` 时改用带 GC 的新构造路径，回调接到
      上面的查询。——`open_with_periodic_gc(..., Duration::from_secs(60), flow_gc_protected)`。
- [x] 单测（真实 iroh 传输链路，不 mock）：offer → fetch 完成 → 触发一轮
      GC → 断言该 hash 在 `flow-blobs` 中已被回收（`local_bytes` 归零或
      等价判据）。——`crates/transport/tests/blobs_resume.rs::periodic_gc_reclaims_a_completed_remote_blob`
      与 `crates/daemon/tests/flow_delivery.rs::completed_flow_fetch_is_reclaimed_by_periodic_gc`
      均走真实 provider/receiver iroh 连接 + 真实 fetch，非 store mock。
- [x] 反证（必带）：回调返回空集（模拟"保护判据被拿掉"）→ 一次仍在
      `Active` 状态、传输尚未完成的 grant，在 GC 落到中途时其数据被判定
      为"应当删除"——证明保护确实在生效、不是摆设判据。——
      `periodic_gc_respects_then_rechecks_protected_hashes`：先证明回调
      命中该 hash 时 GC 存活（`local_bytes > 0`），再清空回调集合、断言
      同一 hash 被回收到 0；`storage` 侧另有
      `active_flow_content_hashes_excludes_completed_and_cancelled_grants`
      反证 completed/cancelled 不会被误判为受保护。
- [ ] 真机：连续传一批照片，中途 `du -sh .ppf/flow-blobs` 记录峰值；等
      GC 跑过至少一轮后复测，应回落到仅剩"正在传输中"的量级，不再随
      已完成的传输持续累积。——**留给共享真机回归**。
- [x] `just ci` 全绿（本次复核：clippy/fmt/arch-check/queue-check/nextest 全过，
      另单独跑通 3 项 BLOB-02 专属测试，见「代码完成记录」）。

## 代码完成记录（2026-09-09）

- 提交 `c6c0bb6`（fix(blobs): reclaim completed Flow stores），已在 `main`。
- 本次复核实测命令与输出：
  - `cargo nextest run -p transport --test blobs_resume periodic_gc` →
    `2 tests run: 2 passed`（`periodic_gc_reclaims_a_completed_remote_blob`、
    `periodic_gc_respects_then_rechecks_protected_hashes`）。
  - `cargo nextest run -p daemon --test flow_delivery completed_flow_fetch_is_reclaimed_by_periodic_gc` →
    `1 test run: 1 passed`。
  - `cargo nextest run -p storage active_flow_content_hashes` →
    `1 test run: 1 passed`（`active_flow_content_hashes_excludes_completed_and_cancelled_grants`）。
  - `just ci` → `CI pipeline: all green ✅`（fmt/clippy/nextest/arch-check/queue-check）。
- 范围内文件确认与卡片一致：`crates/transport/src/blobs.rs`、
  `crates/storage/src/flow_delivery_repo.rs`、`crates/daemon/src/main.rs`，
  外加对应测试文件；未越界改动 `FlowGrantState`、`.ppf/blobs`、proto、手机端。
- 唯一未闭合项：真机 `du -sh .ppf/flow-blobs` 峰值 → GC 后回落的观测，
  按范围红线交给共享真机回归，不由本次实施代劳。

## 范围

- 只准动：`crates/transport/src/blobs.rs`（新增带 GC 的构造方法）、
  `crates/storage/src/flow_delivery_repo.rs`（新增查询）、
  `crates/daemon/src/main.rs`（接线）、对应单测。
- 不准动：`.ppf/blobs`（旧仓，BLOB-01 范围）、`FlowGrantState` 状态机
  语义、备份/同步协议（`crates/proto`）、手机端。

## 阻塞与依赖

无。依赖 REBUILD-02 已落地的 `flow_delivery`/`FlowGrantState`（已在
main）。
