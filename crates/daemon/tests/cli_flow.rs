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

/// DAE-08 (#304)：`--version` 的输出前缀是**桌面壳的探活判据**，不是文案。
///
/// 桌面壳在注册开机自启之前会跑一次 `ppf-daemon --version`，用这个前缀确认
/// 「这确实是我们的 daemon」（DESK-29 / #268）：
///
/// ```text
/// apps/desktop/src-tauri/src/lib.rs
///   const DAEMON_VERSION_MARKER: &str = "P-Pass daemon";
/// ```
///
/// **改 `main.rs` 里那句 `println!("P-Pass daemon {}", ...)` 等于改桌面壳的
/// 探活判据**：壳会开始把好的 daemon 判成坏的，向导第 3 步「设为常驻服务」
/// 对所有人失败。错误方向是安全的（向导明确报错，不是静默放行），但 CI 里
/// 没有任何 job 会跑向导——所以这条断言就是那个耦合关系唯一的守卫。
///
/// 真要改文案，两边一起改，别只改一边。
///
/// 为什么断言前缀而不是整行相等：版本号那半会被 `PPF_DAEMON_VERSION` /
/// `PPF_BUILD_VERSION` 覆盖（这也正是桌面壳刻意不比对版本号的原因）。
/// 钉死整行会造出一个隔三差五自己红的判据；前缀才是真正的契约。
#[test]
fn version_prefix_is_the_desktop_probe_contract() {
    let out = daemon_bin()
        .arg("--version")
        .output()
        .expect("spawn daemon --version");
    assert!(out.status.success(), "status: {:?}", out.status);
    let stdout = String::from_utf8_lossy(&out.stdout);
    // 带尾空格：`println!("P-Pass daemon {}", ...)` 的实际形状。少了这个空格
    // 就漏掉了「前缀后面紧跟版本号」这半，`P-Pass daemonX` 也能过。
    assert!(
        stdout.starts_with("P-Pass daemon "),
        "--version 的 stdout 必须以 `P-Pass daemon ` 开头——\
         apps/desktop/src-tauri/src/lib.rs 的 DAEMON_VERSION_MARKER 依赖它。\
         实际输出:\n{stdout}"
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
