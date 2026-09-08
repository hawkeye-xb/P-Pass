# BLOB-02 flow-blobs 收件仓永不回收，占盘持续膨胀

> ⬜ 状态：未开工
> 级别：L2 · 阻塞：无

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

- [ ] `transport::Blobs` 新增一个启用周期性 GC 的构造路径，对外只暴露
      `[u8;32]` 哈希集合的"当前受保护"回调，不把 `iroh_blobs` 具体类型
      （`Hash`/`GcConfig`/`ProtectCb` 等）泄漏出 `crates/transport`
      （ADR-001 iroh 隔离边界不能破）。
- [ ] `storage::Db` 新增查询：返回 `flow_delivery` 表中 `state = 'active'`
      的 `content_hash` 集合——这是回调判据的唯一数据源，天然对齐现有
      `FlowGrantState` 状态机（不新增状态、不改表结构语义）。
- [ ] `main.rs` 构造 `flow_blobs` 时改用带 GC 的新构造路径，回调接到
      上面的查询。
- [ ] 单测（真实 iroh 传输链路，不 mock）：offer → fetch 完成 → 触发一轮
      GC → 断言该 hash 在 `flow-blobs` 中已被回收（`local_bytes` 归零或
      等价判据）。
- [ ] 反证（必带）：回调返回空集（模拟"保护判据被拿掉"）→ 一次仍在
      `Active` 状态、传输尚未完成的 grant，在 GC 落到中途时其数据被判定
      为"应当删除"——证明保护确实在生效、不是摆设判据。
- [ ] 真机：连续传一批照片，中途 `du -sh .ppf/flow-blobs` 记录峰值；等
      GC 跑过至少一轮后复测，应回落到仅剩"正在传输中"的量级，不再随
      已完成的传输持续累积。
- [ ] `just ci` 全绿。

## 范围

- 只准动：`crates/transport/src/blobs.rs`（新增带 GC 的构造方法）、
  `crates/storage/src/flow_delivery_repo.rs`（新增查询）、
  `crates/daemon/src/main.rs`（接线）、对应单测。
- 不准动：`.ppf/blobs`（旧仓，BLOB-01 范围）、`FlowGrantState` 状态机
  语义、备份/同步协议（`crates/proto`）、手机端。

## 阻塞与依赖

无。依赖 REBUILD-02 已落地的 `flow_delivery`/`FlowGrantState`（已在
main）。
