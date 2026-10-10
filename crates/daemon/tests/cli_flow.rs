//! DAE-03 CLI 纪律——真实二进制级冒烟。
//!
//! --help/--version 必须在任何 daemon 机制（config/数据库/身份/claim/bind）
//! 之前短路退出：8/6 事故就是 `daemon --help` 被当普通启动一路走到单实例
//! claim 触发误接管、常驻停机数分钟。这里直接 spawn 二进制验证退出码与
//! 输出，并断言**没有**任何启动期副作用（IPC 行 / 身份铸造 / 已启动）。

// DESK-33 (#325)：这是开发者手动 / 测试框架跑的集成测试，不是产品进程，
// clippy.toml 的「禁止直接 Command::new」不适用。
#![allow(clippy::disallowed_methods)]

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

/// SEC-11 (#496)：stdout 不是终端时，配对链接（含 10 分钟有效的令牌）
/// **一个字都不能出现在任何流里**，也不能出现在数据目录下的任何文件里。
///
/// 背景：macOS launchd 的 `StandardOutPath` 就是 `~/Library/Logs/p-pass-daemon.log`，
/// DEVLOG-03 那句「只进 stdout」在托管下等于「进日志文件」。这里用 piped
/// stdout（天然非终端）起一个真的 `--ephemeral` daemon，等到 stdout 上出现
/// 配对那一行的位置（门控点确实执行过），再关 stdin 让它自己退出，然后查
/// stdout / stderr / 数据目录三处 `ppf://pair` 计数为 0。
///
/// 终端分支（打印完整链接）在 cargo test 里拿不到 pty，由
/// `cli::tests::pair_link_printed_only_to_a_terminal` 单测 + `just dev-daemon` 人工确认。
#[test]
fn pair_link_never_printed_when_stdout_is_not_a_terminal() {
    use std::io::{BufRead, BufReader, Read};
    use std::process::Stdio;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    struct KillOnDrop(std::process::Child);
    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    let dir = tempfile::tempdir().expect("tempdir");
    let child = daemon_bin()
        .arg("--ephemeral")
        .env("PPF_DATA_DIR", dir.path())
        .env("PPF_TELEMETRY_ENABLED", "false")
        .env("PPF_RELAY_URLS", "")
        .env("PPF_BIND_ADDR", "127.0.0.1:0")
        .env_remove("PPF_LOG_FILE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn daemon --ephemeral");
    let mut child = KillOnDrop(child);

    let mut stderr_pipe = child.0.stderr.take().expect("stderr piped");
    let stderr_reader = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = stderr_pipe.read_to_string(&mut s);
        s
    });
    let (tx, rx) = mpsc::channel::<String>();
    let stdout_pipe = child.0.stdout.take().expect("stdout piped");
    let stdout_reader = std::thread::spawn(move || {
        for line in BufReader::new(stdout_pipe).lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    // 同步点：配对那一行（无论门控哪边）在 stdout 上出现 = 门控点已执行。
    // wait_online 最多 10 秒，留足余量。
    let deadline = Instant::now() + Duration::from_secs(40);
    let mut stdout = String::new();
    let mut reached = false;
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(line) => {
                stdout.push_str(&line);
                stdout.push('\n');
                if line.contains("配对") {
                    reached = true;
                    break;
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    // 关 stdin → --ephemeral 自己退出（UX-07），stdout/stderr 随之 EOF。
    drop(child.0.stdin.take());
    let exit_deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < exit_deadline {
        if child.0.try_wait().expect("try_wait").is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = child.0.kill();
    let _ = child.0.wait();
    stdout_reader.join().expect("stdout reader");
    while let Ok(line) = rx.try_recv() {
        stdout.push_str(&line);
        stdout.push('\n');
    }
    let stderr = stderr_reader.join().expect("stderr reader");

    // 失败信息里也不回显令牌（CI 日志同样是持久文件）。
    fn redact(s: &str) -> String {
        s.split("&t=")
            .enumerate()
            .map(|(i, part)| {
                if i == 0 {
                    part.to_string()
                } else {
                    let rest = part.trim_start_matches(|c: char| c.is_ascii_hexdigit());
                    format!("&t=<REDACTED>{rest}")
                }
            })
            .collect()
    }
    let (stdout, stderr) = (redact(&stdout), redact(&stderr));
    let (stdout_hits, stderr_hits) = (
        stdout.matches("ppf://pair").count(),
        stderr.matches("ppf://pair").count(),
    );

    assert!(
        reached,
        "40 秒内 stdout 上没等到配对那一行，daemon 没走到门控点:\n\
         stdout:\n{stdout}\nstderr:\n{stderr}"
    );
    assert_eq!(
        stdout_hits, 0,
        "stdout 非终端时不许打印配对链接（launchd 下 stdout 就是日志文件）:\n{stdout}"
    );
    assert_eq!(stderr_hits, 0, "stderr 里也不许有配对链接:\n{stderr}");
    assert!(
        stdout.contains("pairing.start"),
        "stdout 应提示改走 IPC pairing.start:\n{stdout}"
    );

    // 数据目录下任何文件（日志、令牌文件以外的一切）也不许有配对链接。
    fn scan(dir: &std::path::Path, hits: &mut Vec<String>) {
        let Ok(rd) = std::fs::read_dir(dir) else {
            return;
        };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                scan(&p, hits);
            } else if let Ok(bytes) = std::fs::read(&p) {
                if bytes.windows(10).any(|w| w == b"ppf://pair") {
                    hits.push(p.display().to_string());
                }
            }
        }
    }
    let mut hits = Vec::new();
    scan(dir.path(), &mut hits);
    assert!(hits.is_empty(), "数据目录里的文件含配对链接: {hits:?}");
}
