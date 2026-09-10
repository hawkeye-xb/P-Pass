# TEL-04 接线 first_byte 事件（L1）

> ✅ 状态：已完成（2026-09-10）· 级别：**L1**

**目标**：`Event::FirstByte { ms, kind }` 接到缩略图/大图服务路径，
量化"翻相册卡不卡"。

## 待实施 agent 定位挂载点

本卡未预先确认挂载点（不同于 TEL-02 已读过 `flow_delivery.rs`）——先读
`crates/daemon/src/query.rs`（`QueryEngine`，desktop 照片墙 timeline/thumb
服务端）找到"收到缩略图/原图请求 → 返回字节"的具体函数，在请求开始到
数据写出的耗时处打点。`kind` 取值 `thumb`（缩略图）或 `blob`（原图/大图）。

## 范围

- `crates/daemon/src/query.rs`：计时 + `telemetry.record(FirstByte{...})`。
- `crates/daemon/src/main.rs`：`QueryEngine::new(...)` 后追加
  `telemetry` 注入（同 TEL-02 的 builder 模式，`with_telemetry()`）。

## 可执行验收

- 新增测试：一次缩略图/大图请求产生 1 个 `first_byte` 事件，`ms >= 0`，
  `kind` 与请求类型一致。
- `enabled=false` 时零事件（复用已有契约）。
- `cargo test -p daemon` 全绿。

## 阻塞与依赖

- 依赖 TEL-01。
- 优先级低于 TEL-02（direct/relay 连接质量比预览延迟更紧迫）。

---

## 验收记录（2026-09-10）

- 挂载点确认为 `crates/daemon/src/query.rs` 的两个数据交付函数：
  `thumb()`（`kind="thumb"`，缩略图缓存命中/生成/占位图三条路径都记录，
  因为每条路径都真的向调用方返回了字节）和 `original()`（`kind="blob"`，
  只有成功读到文件字节才记录——`NotFound`/超尺寸/非图片分支不产出字节，
  记它们的"耗时"不是卡片要问的"翻相册卡不卡"，故意不记）。
  `blob_ticket()` 只发票据不传字节，真正的传输走 iroh-blobs 另一条路径
  （已被 TEL-02 的 `conn`/`flow_item` 覆盖），不算 `first_byte`。
- `QueryEngine` 加 `Option<Telemetry>` + `with_telemetry()` builder，与
  TEL-02 的 `FlowDelivery` 同构；`main.rs` 用同一个 `telemetry.clone()`
  接入（daemon_alive/conn/flow_item/first_byte 四类事件共享一个客户端
  实例，同一份"关闭=零网络"契约）。
- 新增测试文件 `crates/daemon/tests/query_telemetry.rs`（3 个测试）：
  - `original_records_one_first_byte_event_on_success`：真实入库资产成功
    读取后恰好 1 个 `first_byte` 事件，`kind="blob"`，`ms` 存在。
  - `not_found_asset_never_emits_a_first_byte_event`：不存在的 hash 返回
    错误、零事件——验证"只在真交付字节时计入"的设计意图。
  - `disabled_telemetry_means_zero_network_calls_from_query_engine`：
    `enabled=false` 反证零网络请求。
- `cargo test -p daemon --test query_telemetry` → 3/3 passed。
- `cargo test -p daemon --test browse_flow --test desk_flow --test
  sync_flow` → 5/5 passed（既有 `QueryEngine` 消费者零回归）。
- `cargo nextest run --all-features` → 359/359 passed, 1 skipped（较
  TEL-02 完成时的 356 净增 3）。
- `just ci`：fmt/clippy -D warnings/arch-check/queue-check 全绿。
