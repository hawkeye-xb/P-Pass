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
    //
    // DEVLOG-03：必须**两条流一起查**。这些行原来都走 println!（stdout），
    // 现在启动期的诊断行改走 tracing（stderr）——只查 stdout 的话这三条断言
    // 照样通过，但**失去判别力**：万一哪天 --help 真的走到了 claim/bind，
    // 那些行会打在 stderr 上而这里看不见。
    let stderr = String::from_utf8_lossy(&out.stderr);
    let both = format!("{stdout}{stderr}");
    assert!(
        !both.contains("IPC:"),
        "--help 不应打印 IPC 行:\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
    assert!(
        !both.contains("身份密钥已铸造"),
        "--help 不应铸造身份:\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
    assert!(
        !both.contains("已启动"),
        "--help 不应启动 daemon:\nstdout:\n{stdout}\nstderr:\n{stderr}"
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

// PROBE (CI-06 #164 验收标准 2) — 只在 Windows 存在、且**必定失败**的测试。
// 上一版探针用的是 unused 变量，但 `cargo nextest run` 不把警告当错误，
// 所以那是个用错的工具（顺带挖出主工作区 Windows 侧零 lint 覆盖的缺口）。
// 测试 lane 的正确探针是「让一个测试真的失败」。
// 期望：test (windows) 红，Linux 侧的 test / clippy 全绿。
// 这个分支永不合入，观察完即关闭。
#[cfg(windows)]
#[test]
fn ci06_probe_deliberately_fails_on_windows_only() {
    assert_eq!(1, 2, "PROBE: 故意失败，用来证明 test (windows) 真的在跑断言");
}
