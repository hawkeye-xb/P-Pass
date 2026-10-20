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

/// #1042：`--version --json` 是给桌面壳（#1045）与免 GUI 控制面（#749）用的
/// **机读契约**，取代对纯文本前缀 `P-Pass daemon ` 的字面量匹配：
///
/// - exit 0，stdout 恰好一行 JSON，stderr 为空；
/// - 键集合恰好是 `product` / `schema` / `version`；
/// - `product == "P-Pass daemon"`，`schema == 1`（只增字段不升，改/删字段才升）；
/// - `version` 与纯文本 `--version` 报的是同一个值；
/// - `--json` 写在 `--version` 前后都一样；
/// - 与 `--version` 一样在一切 daemon 机制之前短路。
#[test]
fn version_json_is_the_machine_readable_contract() {
    let plain = daemon_bin().arg("--version").output().expect("spawn");
    let plain = String::from_utf8_lossy(&plain.stdout).trim().to_string();
    let plain_version = plain
        .strip_prefix("P-Pass daemon ")
        .expect("纯文本 --version 形状不变")
        .to_string();
    for args in [["--version", "--json"], ["--json", "--version"]] {
        let out = daemon_bin().args(args).output().expect("spawn");
        assert_eq!(out.status.code(), Some(0), "{args:?}: {:?}", out.status);
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(stderr, "", "{args:?}: stderr 必须为空");
        assert_eq!(
            stdout.lines().count(),
            1,
            "{args:?}: 必须恰好一行：{stdout:?}"
        );
        let v: serde_json::Value = serde_json::from_str(stdout.trim()).expect("必须是 JSON");
        let mut keys: Vec<_> = v.as_object().expect("必须是对象").keys().cloned().collect();
        keys.sort();
        assert_eq!(keys, ["product", "schema", "version"], "键集合是契约：{v}");
        assert_eq!(v["product"], "P-Pass daemon");
        assert_eq!(v["schema"], 1);
        assert_eq!(
            v["version"],
            plain_version.as_str(),
            "与纯文本 --version 同源"
        );
        for marker in ["IPC:", "身份密钥已铸造", "已启动"] {
            assert!(!stdout.contains(marker), "不得启动 daemon：{stdout}");
        }
    }
}

/// `--json` 单独出现是用法错误（exit 2），不能当成普通启动。
#[test]
fn json_without_version_is_a_usage_error() {
    let out = daemon_bin().arg("--json").output().expect("spawn");
    assert_eq!(out.status.code(), Some(2), "status: {:?}", out.status);
    assert!(String::from_utf8_lossy(&out.stderr).contains("用法"));
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

/// 起一个真的 `--ephemeral` daemon（数据目录隔离、不连 relay、随机端口），
/// 等到 stdout 上出现「配对」那一行（= 启动序列走到了 stdin 循环之前），
/// 返回 `(退出前的 stdout, stderr, 关 stdin 到进程退出的耗时)`。
/// 关 stdin 后 15 秒内没退出则返回 `None` 耗时（调用方据此断言失败）。
fn run_ephemeral_until_stdin_eof(
    extra_args: &[&str],
) -> (String, String, Option<std::time::Duration>) {
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
        .args(extra_args)
        .env("PPF_DATA_DIR", dir.path())
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

    let deadline = Instant::now() + Duration::from_secs(40);
    let mut stdout = String::new();
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(line) => {
                stdout.push_str(&line);
                stdout.push('\n');
                if line.contains("配对") {
                    break;
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    // 关 stdin（写入端 EOF）→ --ephemeral 自己退出。
    let closed_at = Instant::now();
    drop(child.0.stdin.take());
    let mut exited_after = None;
    while closed_at.elapsed() < Duration::from_secs(15) {
        if child.0.try_wait().expect("try_wait").is_some() {
            exited_after = Some(closed_at.elapsed());
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = child.0.kill();
    let _ = child.0.wait();
    stdout_reader.join().expect("stdout reader");
    while let Ok(line) = rx.try_recv() {
        stdout.push_str(&line);
        stdout.push('\n');
    }
    let stderr = stderr_reader.join().expect("stderr reader");
    (stdout, stderr, exited_after)
}

/// #1041 E2：删掉 stdin 的 y/n 确认器后，**EOF → 退出**这条契约必须原样保留——
/// `tools/` 下所有脚本（dogfood-smoke / ios e2e / testclient）都靠「关掉 stdin 写入端」
/// 收掉 `--ephemeral` daemon（UX-07：3 秒内）。
/// 反证：让 main.rs 的 stdin 循环不再在 EOF 时发退出信号（EOF 分支永不触发）→ daemon
/// 不退出，本测试必红（已手工验证）。
#[test]
fn ephemeral_daemon_exits_on_stdin_eof() {
    let (stdout, stderr, exited_after) = run_ephemeral_until_stdin_eof(&[]);
    assert!(
        stdout.contains("配对"),
        "daemon 没走到启动序列的配对那一步:\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
    let exited_after = exited_after.unwrap_or_else(|| {
        panic!("关 stdin 后 15 秒内 daemon 没退出:\nstdout:\n{stdout}\nstderr:\n{stderr}")
    });
    assert!(
        exited_after < std::time::Duration::from_secs(5),
        "UX-07 要求 3 秒内退出，实测 {exited_after:?}"
    );
}

/// #1041 E2：`--post-update` 已退役（接受并忽略，下一个版本删除）。旧版桌面壳升级后
/// 仍会带它拉起新 daemon：必须**不报未知参数、照常启动**，且行为与不带它相同
/// （同样走到配对那一步、同样在 stdin EOF 时退出）。
/// 反证：从 `cli::parse_cli` 删掉 `--post-update` 分支 → exit 2 + 未知参数，本测试必红。
#[test]
fn retired_post_update_flag_does_not_stop_daemon_from_starting() {
    let (stdout, stderr, exited_after) = run_ephemeral_until_stdin_eof(&["--post-update"]);
    assert!(
        !stderr.contains("未知参数"),
        "--post-update 必须被接受:\nstderr:\n{stderr}"
    );
    assert!(
        stdout.contains("配对"),
        "带 --post-update 的 daemon 没有照常启动:\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
    assert!(
        exited_after.is_some(),
        "带 --post-update 的 daemon 在 stdin EOF 后没退出（行为应与不带时相同）"
    );
}

/// SEC-11 (#496)：stdout 不是终端时，配对链接（含 10 分钟有效的令牌）
/// **一个字都不能出现在任何流里**，也不能出现在数据目录下的任何文件里。
///
/// 背景：macOS launchd 的 `StandardOutPath` 就是 `<数据目录>/logs/daemon.out`，
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

/// DESK-58 (#875)：本平台的 stderr 由 daemon 自己接（Windows）时就是那个落点；
/// `None` = stderr 由服务管理器负责（macOS 的 launchd），daemon 不自己接。按
/// 能力分支，不写 `#[cfg]`（arch-check B.2：平台分叉只在 crates/platform）。
fn daemon_captured_stderr(data_dir: &std::path::Path) -> Option<std::path::PathBuf> {
    use platform::PlatformAdapter as _;
    let paths = platform::adapter().daemon_log_paths(data_dir);
    if paths.stdio_by_service_manager {
        None
    } else {
        paths.stderr
    }
}

/// DESK-58 (#875)：Windows 上 stderr 没人接（壳的一次性 spawn 给的是 `NUL`，
/// Run 键登录拉起时干脆没有句柄）⇒ daemon 自己把它接到 `logs\daemon.err`，
/// 文件日志初始化之前的报错原话落在那里，向导和诊断包读的就是它。
///
/// 触发器选 `PPF_LOG_FILE` 指向一个目录：打不开 ⇒ `eprintln!` + exit(2)，
/// 正好发生在文件日志就位之前——与 #871 的「库目录不存在」同一段。
///
/// 反证：去掉 main.rs 里那次 `capture_unattached_stderr` → 文件不存在，红。
#[test]
fn desk58_early_error_lands_in_daemon_err_when_stderr_is_null() {
    use std::process::Stdio;
    let dir = tempfile::tempdir().expect("tempdir");
    let Some(err_file) = daemon_captured_stderr(dir.path()) else {
        return; // 本平台 stderr 由托管方接，daemon 不负责。
    };
    let status = daemon_bin()
        .env("PPF_DATA_DIR", dir.path())
        .env("PPF_LOG_FILE", dir.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("spawn daemon");
    assert_eq!(status.code(), Some(2), "PPF_LOG_FILE 打不开应 exit 2");
    let text = std::fs::read_to_string(&err_file)
        .unwrap_or_else(|e| panic!("{} 读不到：{e}", err_file.display()));
    assert!(
        text.contains("PPF_LOG_FILE="),
        "daemon.err 里没有原话：{text:?}"
    );
}

/// DESK-58 (#875)：有人刻意接的 stderr（这里是测试框架的管道）不许被改接——
/// 原话照旧出现在管道里，也不生成固定落点文件。所有平台都跑。
#[test]
fn desk58_a_piped_stderr_is_left_alone() {
    use std::process::Stdio;
    let dir = tempfile::tempdir().expect("tempdir");
    let out = daemon_bin()
        .env("PPF_DATA_DIR", dir.path())
        .env("PPF_LOG_FILE", dir.path())
        .stdin(Stdio::null())
        .output()
        .expect("spawn daemon");
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("PPF_LOG_FILE="), "stderr: {stderr}");
    if let Some(f) = daemon_captured_stderr(dir.path()) {
        assert!(!f.exists(), "管道 stderr 被改接到了 {}", f.display());
    }
}
