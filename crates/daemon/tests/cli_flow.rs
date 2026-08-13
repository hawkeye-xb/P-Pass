//! DAE-03 CLI 纪律——真实二进制级冒烟。
//!
//! --help/--version 必须在任何 daemon 机制（config/数据库/身份/claim/bind）
//! 之前短路退出：8/6 事故就是 `daemon --help` 被当普通启动一路走到单实例
//! claim 触发误接管、常驻停机数分钟。这里直接 spawn 二进制验证退出码与
//! 输出，并断言**没有**任何启动期副作用（IPC 行 / 身份铸造 / 已启动）。

use std::process::Command;

fn daemon_bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_daemon"))
}

#[test]
fn help_exits_zero_without_starting_anything() {
    let out = daemon_bin()
        .arg("--help")
        .output()
        .expect("spawn daemon --help");
    assert!(out.status.success(), "status: {:?}", out.status);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("用法"), "stdout 应含用法:\n{stdout}");
    assert!(
        stdout.contains("--ephemeral"),
        "stdout 应列出 --ephemeral:\n{stdout}"
    );
    // 关键：--help 绝不能走到 claim/bind——正常启动才有的输出一行都不能有。
    assert!(
        !stdout.contains("IPC:"),
        "--help 不应打印 IPC 行:\n{stdout}"
    );
    assert!(
        !stdout.contains("身份密钥已铸造"),
        "--help 不应铸造身份:\n{stdout}"
    );
    assert!(
        !stdout.contains("已启动"),
        "--help 不应启动 daemon:\n{stdout}"
    );
}

#[test]
fn version_prints_crate_version_and_exits_zero() {
    let out = daemon_bin()
        .arg("--version")
        .output()
        .expect("spawn daemon --version");
    assert!(out.status.success(), "status: {:?}", out.status);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains(env!("CARGO_PKG_VERSION")),
        "stdout 应含当前版本 {}:\n{stdout}",
        env!("CARGO_PKG_VERSION")
    );
}

#[test]
fn unknown_flag_fails_with_usage_on_stderr() {
    let out = daemon_bin()
        .arg("--bogus")
        .output()
        .expect("spawn daemon --bogus");
    // 未知参数 = 用法错误，exit 2（不是 0：绝不能当成普通启动继续跑）。
    assert_eq!(out.status.code(), Some(2), "status: {:?}", out.status);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("未知参数"),
        "stderr 应报未知参数:\n{stderr}"
    );
    assert!(stderr.contains("用法"), "stderr 应附用法:\n{stderr}");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        !stdout.contains("已启动"),
        "未知参数不应启动 daemon:\n{stdout}"
    );
}
