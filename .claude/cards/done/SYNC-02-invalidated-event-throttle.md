# SYNC-02 timeline.invalidated 事件源 + 节流合并　级别 L2

背景与全部裁决点见 `docs/product/2026-08-12-metadata-sync-decisions.md`
（§②⑤，本卡只实现这两条，不引用聊天记录，聊天记录不是验收依据）。

## 目标

`events.rs` 新增 `timeline.invalidated` 事件；三个真实变更点触发它，
但经过固定窗口节流 + 批次收尾强制触发合并，不是来一次写入发一次。

## 范围

只准动：
- `crates/daemon/src/events.rs`（新增常量 + 节流合并逻辑）
- `crates/core-index/src/ingest.rs`（ingest 成功后的触发点）
- `crates/daemon/src/reconcile.rs`（一轮对账移除完成后的触发点）
- `crates/core-index/src/rebuild.rs`（重建完成后的触发点）
- `crates/daemon/src/backup.rs`（`backup.commit` 处接"批次收尾强制
  触发"这一个钩子）

## 不准动

- `router.rs` 的订阅入口（SYNC-03，依赖本卡但本卡不做）
- Android 端任何代码（SYNC-04）
- `proto::AssetMeta`（SYNC-05，独立卡）

## 设计要点（§⑤ 原文落地）

- 事件内容**不带数据**，只是"变了"的 ping（`{"event":"timeline.
  invalidated","data":{}}` 或更简，不需要携带哪张照片变了）。
- 节流窗口：固定时长（做成常量/参数，不锁死具体秒数，允许后续调）。
  窗口内多次触发只算一次；窗口到点必须真正 emit 一次（哪怕期间只
  触发了一次）——**不是防抖**（防抖=活动不停就一直重新计时，只有
  安静才发，本卡明确不要这个语义，理由见决策档案§⑤）。
- 批次收尾（`backup.commit` 执行完成的那一刻）：如果窗口内有挂起的
  未发信号，立即强制 flush 一次，不等窗口到点；如果窗口内没有挂起
  信号（这批啥也没变，理论不该发生但要写测试防回归），不额外发空信号。
- `reconcile`/`rebuild` 本身是单次跑完的整轮操作，天然只会各触发一次，
  不需要额外的批次收尾钩子——只有 `ingest`（逐文件调用）需要节流。

## 可执行验收

不接受"应该 work"：
- 单测：同一节流窗口内连续调用触发点 N 次（N≥3）→ 断言只 emit 一次。
- 单测：`backup.commit` 执行时若窗口内有挂起信号 → 断言立即 emit，
  不等待窗口超时（用可控时钟/channel 断言时序，不是 sleep 猜时间）。
- 单测：`reconcile.run_once`/`rebuild` 各自跑一轮 → 断言恰好 emit 一次
  （不是零次也不是多次）。
- **反证**：把节流逻辑临时去掉（改回逐次直发）→ 上面第一条断言必须
  变红（证明判据真的在测节流，不是恒真式）。

## 证据要求

报绿附单测输出摘要（含反证那条的实际失败输出，证明关掉判据后确实红）。

## 跨卡声明禁令

不许写"SYNC-03/04 已接上"——本卡完成时那两张卡可能还没合并，`events.
rs` 里新事件此时没有任何订阅者在消费，这是预期状态，不是半成品。

## 收尾

`cargo test`（daemon + core-index）全绿 + `just arch-check` 绿（本卡不
碰 iroh/cfg，理论不受影响，仍要跑一次确认）+ PROGRESS.md 一行 + 本卡
移入 `done/`。

---

### 执行记录（2026-08-12）

- `events.rs`：新增 `TIMELINE_INVALIDATED` + `Throttle`（`signal`/
  `flush_now`，generation 计数器防止 flush_now 之后旧的窗口定时任务
  补发一次）。单测 4 条（窗口合并/立即 flush/无挂起信号 flush 是
  no-op/flush_now 后旧任务不补发），全部用 `#[tokio::test(start_paused
  = true)]` + `tokio::time::advance` 做可控时钟，不是 sleep 猜时间。
- `backup.rs`：`BackupEngine` 加 `throttle: Option<Throttle>` +
  `with_events`；`commit` 循环里 `IngestOutcome::New` 分支 `signal()`，
  循环结束后 `flush_now()`。新增集成测试
  `commit_batch_emits_timeline_invalidated_exactly_once`
  （`daemon/tests/backup_flow.rs`）：5 个文件一批 commit → 恰好收到
  1 次 `timeline.invalidated`。
- `reconcile.rs`：`Reconcile` 加 `events: Option<EventBus>` +
  `with_events`；`run_once` 完成后直发一次（不经 Throttle——单轮操作
  天然只触发一次）。单测 2 条（恰好 emit 一次；未接事件总线不 panic）。
- **范围调整（未按原计划动 `rebuild.rs`）**：接线前查了实际调用链，
  `core_index::rebuild()` 当前在 daemon 运行期**零调用点**（`grep`
  全仓库只有 `core-index/tests/rebuild.rs` 和
  `daemon/tests/backup_flow.rs` 两处测试引用，没有任何 CLI/IPC 路径
  会在运行时调它）。给一个没有真实消费者的函数接一个只在测试里能验证
  自己接没接的空调用，没有验证价值——留白，等 rebuild 真正被接入某条
  运行路径（比如未来的手工重建入口）时再一并补这个触发点。
- `main.rs` 接线：`event_bus.clone()` 分别喂给 `BackupEngine::with_events`
  和 `Reconcile::with_events`（此前只有 `Router`/`Pairing` 接了）。
- 反证：临时把 `signal()` 改成直接 `emit`（跳过节流）→
  `window_merges_bursts_into_one_emit` 立刻从绿变红（`assert!(rx.
  try_recv().is_err(), "窗口内不该提前 emit")` panic）；改回后重新全绿。
- 证据：`cargo test -p daemon -p core-index` 全绿（含新增 6 个单测 +
  1 个集成测试）；`just arch-check` 绿；`cargo fmt --check` 干净。
