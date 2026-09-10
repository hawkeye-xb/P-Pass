# TEL-02 接线 conn/flow_item 到生产代码（L2）

> ⬜ 状态：未开工 · 级别：**L2** · 阻塞：**TEL-01（先要有新 Event 变体）**

**目标**：`crates/daemon/src/flow_delivery.rs` 的 `FlowDelivery::fetch()`
真正记录 `conn` 和 `flow_item` 遥测事件——这是当前唯一的生产数据传输
路径（REBUILD-02 单文件 Flow，旧批次 `backup.rs` 是冻结的 legacy，不接）。

## 已确认的挂载点（读过代码，不是猜的）

- **`conn` 事件**：`FlowPathGuard::set_path()`
  （`flow_delivery.rs:149`）已经在收到 `ConnectionStatus`（Direct/Relay/
  Unknown）的那一刻被调用（`blobs.fetch_from_observing_path` 的回调，
  `flow_delivery.rs:298`）。在这里追加一次 `telemetry.record(Conn{...})`：
  `path` 从 `ConnectionStatus::as_str()` 取（direct/relay/unknown 三态，
  `unknown` 映射到手册未定义过的第三态，需要 schema 允许或映射为
  `fail_stage`——由实施 agent 判断哪种更诚实，不许悄悄丢弃 unknown）；
  `ms` 目前 `FlowPathGuard` 没有计时——需要在 `fetch()` 里对
  `fetch_from_observing_path` 调用包一层 `Instant::now()` 计时；
  `fail_stage` 在 `fetch()` 的各 `DeliveryError` 分支填（Fetch/
  Materialize/GuardMismatch/Cancelled 各对应一个 stage 字符串，禁止把
  错误的 `Display` 原文塞进去——那可能含路径）。
- **`flow_item` 事件**：`fetch()` 成功路径最后、`Ok(receipt_from(...))`
  之前（`flow_delivery.rs:356` 附近）。`bytes` 从已完成的 blob 长度取
  （`self.blobs` 或 ingest 后的文件 size，实施时确认哪个更准确、不需要
  额外磁盘 IO）；`dur_s` 从 `fetch()` 整体计时；`resumed` 目前没有直接
  信号——iroh-blobs 断点续传是否发生需要从 `Blobs`/`store` 层查，若拿不到
  廉价信号，本卡允许先填 `false` 但必须在 PROGRESS.md 写明"resumed 暂
  恒为 false，真实断点续传检测另开卡"，不许编造。

## 范围

- `crates/daemon/src/flow_delivery.rs`：`FlowDelivery` 持有一个
  `Option<Telemetry>`（同 `events: Option<EventBus>` 的可选注入模式），
  `with_telemetry()` builder 方法；`fetch()` 内联记录两个事件。
- `crates/daemon/src/main.rs`：`FlowDelivery::new(...)` 构造后追加
  `.with_telemetry(telemetry.clone())`（`telemetry` 变量已在 main.rs:296
  构造，`flow_delivery` 在 main.rs:376 构造，顺序已经对——直接传）。
- **不准动**：`backup.rs`（legacy，冻结）、IPC 协议、proto。

## 可执行验收

- 新增测试：`flow_delivery.rs` 或新测试文件里，用一个假的/内存
  `Telemetry`（`Telemetry::new` 已支持注入任意 URL，测试可指向本地
  mock server，参考 `telemetry_flow.rs` 现成的 `mock_server()` 辅助
  函数）验证一次成功 `fetch()` 产生恰好 1 个 `conn` + 1 个 `flow_item`
  事件，字段非零/非空。
- 反证：`enabled=false` 的 `Telemetry` 走同一 `fetch()` 路径，事件必须
  被丢弃在门口（复用 `telemetry.rs` 已有的"关闭=零网络"契约，不能因为
  这里新增调用点而破例）。
- `cargo test -p daemon` 全绿；`just ci` 全绿。

**证据要求**：报绿附真实命令输出（测试计数）。

## 阻塞与依赖

- 依赖 TEL-01 先落地新 `Event::Conn`/`Event::FlowItem` 变体。
