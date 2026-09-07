# DESK-13 大文件 ingest 在 tokio worker 线程同步阻塞，冻结桌面 UI（L0）

> 🟢 状态：代码已合并（`block_in_place` 修复 + 3 个测试文件配套 runtime
> flavor 修复），本地全绿 · 当前节点：等真机复核（大文件/视频传输时观察
> 桌面 UI 是否仍卡顿）· 下一步：真机验证 · 协同分支：`main`
> 级别：**L0**（阻塞级：核心传输路径冻结整个桌面 async 运行时，表现为
> "刷新会卡死很久"）· 阻塞：无

## 问题

2026-09-07 真机黑盒回归反馈："desktop 传输过程中照片不实时展示、手动
刷新会卡死很久"。

根因（源码核实，`crates/core-index/src/ingest.rs`）：`Ingestor::ingest()`
的哈希计算（`dedup::hash_file`）与 `place()`（跨卷 move 退化为整文件拷贝）
都是同步 CPU/IO 密集操作，直接跑在 tokio worker 线程上——大文件（尤其是
Flow 传来的视频）哈希/拷贝耗时越长，就把同一个 worker 线程上排队的所有
其他 async 任务（包括桌面本地 IPC：照片墙刷新、暂停/取消按钮响应）一起
饿死，表现为整个桌面 UI 卡死到拷贝完成为止。

## 修复

本卡合入时发现：`ingest.rs`/`Cargo.toml` 里已经有一份**未提交的
`block_in_place` 修复**（`hash_file` 和 `place()` 分别套
`tokio::task::block_in_place`，让同步阻塞脱离 async 调度），但配套的三个
测试文件（`crates/core-index/tests/ingest.rs`、`props.rs`、`rebuild.rs`）
仍用默认单线程 `#[tokio::test]`/`new_current_thread()`——`block_in_place`
要求 multi-thread runtime，一跑就 18+3+3 个测试全 panic
（`can call blocking only when running on the multi-threaded runtime`）。
这是一次「生产代码修完但测试标注没跟上」的半成品状态，本卡把三个测试文件
统一改成 `flavor = "multi_thread"` / `new_multi_thread()`，让这份已有的
真实修复真正生效并被测试覆盖。

## 验收标准

- [x] `Ingestor::ingest()`/`place()` 的同步哈希/拷贝套 `block_in_place`
- [x] `ingest.rs`/`props.rs`/`rebuild.rs` 全部改用 multi-thread runtime
- [x] `cargo nextest run --all-features` 全绿
- [x] `just ci` 全绿
- [ ] 真机验证：传输大文件（如视频）期间桌面照片墙/暂停/取消按钮响应
      不再卡顿

## 实施记录

- `crates/core-index/Cargo.toml`：`tokio` 生产依赖加 `rt-multi-thread`
  feature（此前只在 dev-dependencies 里有）
- `crates/core-index/src/ingest.rs`：`hash_file` 调用套
  `tokio::task::block_in_place`；`place()` 拆成 `place()`（套
  `block_in_place`）+ `place_blocking()`（原逻辑）
- `crates/core-index/tests/ingest.rs`：18 处 `#[tokio::test]` →
  `#[tokio::test(flavor = "multi_thread")]`
- `crates/core-index/tests/props.rs`：`rt()` helper 从
  `new_current_thread()` 改为 `new_multi_thread()`
- `crates/core-index/tests/rebuild.rs`：6 处同上
- `crates/daemon/tests/flow_delivery.rs`：5 处同上（daemon 侧调用
  `Ingestor` 的测试同样受影响）
