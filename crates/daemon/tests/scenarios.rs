//! T-070 故障剧本：进程内集成剧本（时钟前跳 / 吊销中断传输）。
//! 进程级故障剧本（大文件 / 崩溃恢复 / 磁盘满）的进程内版本在
//! scenarios/process_failures.rs（#[ignore]，显式运行，见该文件头）。
//!
//! #[path] 说明：cargo 的集成测试自动发现只认 tests/*.rs 顶层文件；
//! tests/scenarios/mod.rs 不会被当作测试目标。用 #[path] 显式挂载
//! 子目录模块，保住卡面约定的 tests/scenarios/ 布局。

#[path = "scenarios/clock_jump.rs"]
mod clock_jump;
#[path = "common/mod.rs"]
mod common;
#[path = "scenarios/process_failures.rs"]
mod process_failures;
#[path = "scenarios/revoke_before_commit.rs"]
mod revoke_before_commit;
