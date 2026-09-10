# TEL-03 error 事件 taxonomy 设计与接线（L2）

> ✅ 状态：已完成（2026-09-10）· 级别：**L2**

**目标**：把 OBS-02 裁决新增的 `error` 事件（字段：`code`, `stage`）真正
接到 `crates/daemon/src/flow_delivery.rs` 的 `DeliveryError` 各分支，
解决"崩溃/问题只能靠人工日志导出"（MOB-52 一类问题）的空白。

## 需要先决定的事（不是照抄 TEL-01/02 就能做）

1. **`code` 的取值来源**：直接用 `DeliveryError` 的 Rust 变体名
   （`GuardMismatch`/`Cancelled`/`Fetch`/`Materialize`/`Storage`/
   `InvalidRequest`）做字符串码，还是需要更细的错误码（比如
   `Fetch` 内部区分"连接失败"vs"blob 不存在"）？前者简单但粒度粗，
   后者更有诊断价值但要动 `DeliveryError` 定义。
2. **红线检查**：`DeliveryError::InvalidRequest(String)` /
   `DeliveryError::Fetch(String)` 等变体内部的 `String` 来自
   `e.to_string()`，可能含义未知第三方库的错误原文——**绝不能把这段
   原文塞进 `code` 或任何遥测字段**（可能意外携带路径/hash）。只传变体
   名/固定阶段字符串，原始错误信息只留在本地日志。
3. **要不要覆盖手机端（Android）**：本卡范围是 daemon 侧；Android 端
   若也要报错误（比如 MOB-52 的闪退），是另一条完全不同的链路
   （Android 没有这个 telemetry.rs 客户端），需要另开卡评估要不要做，
   本卡不动 Android。
4. **触发频率控制**：同一错误反复发生（比如网络持续不通）要不要限流/
   去重，避免刷屏（参考 NET-03 的"idle 设备刷屏审计"教训）——建议
   同一 `(code, stage)` 组合在一个批次 flush 窗口（5min）内只记一次，
   由实施 agent 设计具体去重键。

## 范围

- `crates/daemon/src/telemetry.rs`：`Event::Error { code, stage }`
  （TEL-01 已建好这个变体，本卡负责真正调用它）。
- `crates/daemon/src/flow_delivery.rs`：`fetch()`/`offer()`/`cancel()`
  失败分支记录事件。
- `infra/workers/telemetry/`：如 taxonomy 设计改变了字段结构需同步。

## 可执行验收

- 测试覆盖至少 2 种失败路径（如 `GuardMismatch`、`Fetch` 失败注入）产生
  对应 `error` 事件，字段内容不含路径/hash（字符串扫描断言）。
- `cargo test -p daemon` 全绿。

## 阻塞与依赖

- 依赖 TEL-01。
- **不是纯 L1 机械卡**：上面 4 个问题里第 1、4 条需要实施前简短跟验收人
  确认粒度和去重策略，不要自行决定后才汇报。

---

## ✅ 裁决结果（2026-09-10，验收人拍板）

1. **粒度：更细分**——用户原话："大概是希望更加细分，要不然看到这些
   error 也没有什么太多的诊断价值……多改代码就多改代码嘛。"
2. **去重：要限流**——"同一个错误反复发生，我们需要做限流，避免一直
   刷。因为我们做得更细分，所以说限流是更合理的。"

## 实施记录

- **细分 `DeliveryError::Materialize` 为三个变体**（`MaterializeStaging`/
  `MaterializeExport`/`MaterializeIngest`）——原来一个笼统变体盖住了
  文件系统/blob 存储/索引三个完全不同的子系统，混在一起报错等于没有
  诊断价值。`telemetry_code()` 方法把每个变体映射到固定英文码：
  `guard_mismatch`/`cancelled`/`invalid_request`/`fetch_failed`/
  `materialize_staging_failed`/`materialize_export_failed`/
  `materialize_ingest_failed`/`storage_failed`。
- **红线**：`telemetry_code()` 只返回固定字符串，绝不把变体内部的
  `String`（来自第三方库 `e.to_string()`，可能带路径）传出去。
- **`GuardMismatch`/`Cancelled` 不上报**：这两个是正常控制流（过期
  重试、用户主动取消），不是"问题"；上报会稀释信号，即使有去重也是
  噪音。
- **`stage` = 触发它的公开方法名**（`offer`/`fetch`/`cancel`），通过
  `xxx_inner()` 包装模式统一在唯一出口处判断上报，不在十几个 `?` 调用
  点分别加逻辑。
- **限流实现**：`Telemetry` 新增 `error_dedup: HashMap<(code, stage),
  Instant>`，同一 key 在 `ERROR_DEDUP_WINDOW`（=`FLUSH_INTERVAL`=5min）
  内只记一次，在 `record()` 门口拦截（非 Error 事件不受影响）。
- **手机端（Android）不动**：本卡范围仅 daemon 侧，Android 若要报错误
  是完全不同的链路（无此 `telemetry.rs` 客户端），需另开卡评估。

## 验收记录（2026-09-10）

- 新增测试（`crates/daemon/src/telemetry.rs`，3 个）：
  - `repeated_error_within_the_dedup_window_is_dropped_at_the_door`：
    10 次相同 `(code, stage)` 只入队 1 个事件。
  - `distinct_code_or_stage_are_not_deduped_against_each_other`：code
    或 stage 任一不同都不互相抵消去重。
  - `non_error_events_are_never_deduped`：`Conn` 等其他事件类型不受
    去重影响，每次调用都入队。
- 新增测试（`crates/daemon/tests/flow_delivery.rs`，3 个）：
  - `invalid_request_records_an_error_event_tagged_with_its_stage`：
    空 `file_name` 触发 `InvalidRequest`，产生 `code=invalid_request`/
    `stage=offer`；红线扫描确认事件里不含原始错误文本。
  - `network_fetch_failure_records_a_fetch_failed_error_at_fetch_stage`：
    真实关闭 provider 连接触发 `Fetch` 失败（不是伪造的错误变体），
    产生 `code=fetch_failed`/`stage=fetch`。
  - `repeated_same_error_is_deduped_within_the_flush_window`：连续 5 次
    相同失败通过 `FlowDelivery` 完整路径仍只产出 1 个 `error` 事件。
- `cargo test -p daemon --lib telemetry` → 6/6 passed（3 既有 + 3 新增）。
- `cargo test -p daemon --test flow_delivery` → 13/13 passed（10 既有
  + 3 新增，零回归）。
- `cargo nextest run --all-features` → 365/365 passed, 1 skipped（较
  TEL-04 完成时的 359 净增 6）。
- `just ci`：fmt/clippy -D warnings/arch-check/queue-check 全绿。
- **遥测五件套（TEL-01/02/03/04）至此全部闭环**：`daemon_alive`/
  `conn`/`flow_item`/`first_byte`/`error` 全部真正接线到生产路径。
