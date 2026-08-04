//! T-070 故障剧本：进程内集成剧本（时钟前跳 / 吊销中断传输）。
//! 进程级剧本（磁盘满 / 4GB 大文件 / daemon 崩溃恢复）在 tools/scenarios/。
//!
//! #[path] 说明：cargo 的集成测试自动发现只认 tests/*.rs 顶层文件；
//! tests/scenarios/mod.rs 不会被当作测试目标。用 #[path] 显式挂载
//! 子目录模块，保住卡面约定的 tests/scenarios/ 布局。

#[path = "scenarios/clock_jump.rs"]
mod clock_jump;
#[path = "scenarios/revoke_before_commit.rs"]
mod revoke_before_commit;
