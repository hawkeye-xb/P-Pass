# TEL-04 接线 first_byte 事件（L1）

> ⬜ 状态：未开工 · 级别：**L1** · 阻塞：**TEL-01（schema）**

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
