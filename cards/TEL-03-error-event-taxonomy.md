# TEL-03 error 事件 taxonomy 设计与接线（L2，待你补充判断）

> ⬜ 状态：未开工 · 级别：**L2** · 阻塞：**TEL-01（schema）+ 需要一次错误码
> 枚举设计讨论，不是纯机械接线**

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
