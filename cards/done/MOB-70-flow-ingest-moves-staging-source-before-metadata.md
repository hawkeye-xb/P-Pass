# MOB-70 Flow 新资产入库在落索引前搬走 staging 源（L2）

> ✅ 状态：归档（2026-09-11 三星真机验收通过）
> 级别：L2 · 阻塞：无

## 问题

三星真实 Flow 传输一个新内容的大视频时，daemon 已完成 native iroh-blobs fetch 与 staging export，随后 `core_index::Ingestor::ingest` 报“staging 源文件不存在”。手机把该项从短重试推进到 `FAILED_NEEDS_USER`，实际照片/视频无法入库。

根因是同一手机的 retry 可以在前一次 daemon fetch 仍进行 staging materialize 时抵达；两次 fetch 共用同一个 staging 路径，后一轮会删除/重导出该路径，前一轮随后在 `Ingestor::ingest` 读取源文件时得到 ENOENT。

## 期望行为

同一手机的同一 Flow item 在 daemon 侧只能有一个 materialize fetch；并发 retry 必须等待并复用前一轮的持久 receipt。新内容获得确认回执，重复内容仍按既有 Duplicate 语义清除 staging。

## 验收标准

- [x] 设备反证：未串行的当前 main 在同一 grant retry 重叠时复现 staging 源 ENOENT。
- [x] GREEN：并发 retry 只得到同一持久 receipt；新内容成功入库、staging 源被移动到 `originals/`。
- [x] 回归：并发 retry 的 daemon 测试锁定“同一持久 receipt”不变量。
- [x] Android 真机：隔离 72 MB 视频 Flow 确认，不进入 `FAILED_NEEDS_USER`。

## 范围

- 只准动：`crates/core-index/src/ingest.rs`、Flow delivery 对应回归测试、此卡与队列/进度/路线图。
- 不准动：Flow 严格消费者重试语义、staging 回收策略、NET-04/NET-05 UI 状态契约。

## 阻塞与依赖

无。

---

## 实施记录

- 2026-09-11 三星真机：大视频 Flow 在旧 daemon 上触发 `MaterializeIngest` ENOENT，三次尝试后进入 `FAILED_NEEDS_USER`。根因初判的“place 顺序”被源码核对推翻：metadata 在 place 之前；实际是并发 retry 共用 staging 文件。
- 修复：`FlowDelivery` 按 control peer 串行 fetch；等待中的 retry 在前一轮完成后读取相同的持久 receipt，不会第二次删除/重导出 staging。
- 验证：新增 `concurrent_retries_of_one_grant_share_the_durable_receipt`；`cargo test -p daemon --test flow_delivery` 与 `just ci` 全绿。当前 main daemon 下，三星 72 MB 隔离视频三秒内 `CONFIRMED`、attempt 0。
