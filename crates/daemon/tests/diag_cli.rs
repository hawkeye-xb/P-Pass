//! #1042：`diag export` 子命令——二进制级契约（#1045 壳改调依赖它）。
//!
//! 契约：
//! - `diag export --out <zip> [--app-version <v>]`；`--out` 必填，导出位置只由
//!   调用方决定（父目录不存在就建）；
//! - 成功 exit 0，stdout 恰好一行 `{"zip":"<out>","daemon_reachable":bool}`，
//!   stderr 为空；常驻服务不在线**不是失败**（DESK-10），`daemon_reachable=false`；
//! - zip 写不出来 exit 1，stdout 空，stderr 一行错误；用法错误 exit 2；
//! - 不启动任何 daemon 机制：不开库（不建 `.ppf`）、不起 IPC、不铸身份。
//!
//! 平台目录经 HOME / XDG_DATA_HOME / APPDATA / LOCALAPPDATA 全部指进 tempdir；
//! 用 `config init` 的 stdout 拿到平台目录在哪（不在测试里重算平台规则）。

#![allow(clippy::disallowed_methods)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

fn daemon_in(home: &Path) -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_daemon"));
    c.env("HOME", home)
        .env("USERPROFILE", home)
        .env("XDG_DATA_HOME", home.join("xdg"))
        .env("APPDATA", home.join("roaming"))
        .env("LOCALAPPDATA", home.join("local"))
        .env_remove("PPF_DATA_DIR")
        .env_remove("PPF_LOG_FILE");
    c
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).to_string()
}

/// 用 `config init` 建好平台目录 + 库，返回 (平台目录, 库目录)。
fn init_platform(home: &Path) -> (PathBuf, PathBuf) {
    let library = home.join("Pictures").join("lib");
    let o = daemon_in(home)
        .args(["config", "init", "--library", library.to_str().unwrap()])
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(0), "{}", text(&o.stderr));
    let v: serde_json::Value = serde_json::from_str(text(&o.stdout).trim()).unwrap();
    let cfg = PathBuf::from(v["config"].as_str().unwrap());
    (cfg.parent().unwrap().to_path_buf(), library)
}

fn read_zip(path: &Path) -> Vec<(String, String)> {
    let mut z = zip::ZipArchive::new(std::fs::File::open(path).unwrap()).unwrap();
    (0..z.len())
        .map(|i| {
            use std::io::Read as _;
            let mut f = z.by_index(i).unwrap();
            let name = f.name().unwrap().to_string();
            let mut s = String::new();
            f.read_to_string(&mut s).unwrap();
            (name, s)
        })
        .collect()
}

/// 契约检查：exit 0、stderr 空、stdout 一行 JSON 且键集合恰为 zip / daemon_reachable。
fn ok_json(o: &Output, out: &Path) -> bool {
    assert_eq!(o.status.code(), Some(0), "stderr: {}", text(&o.stderr));
    assert_eq!(text(&o.stderr), "", "成功时 stderr 必须为空");
    let stdout = text(&o.stdout);
    assert_eq!(stdout.lines().count(), 1, "stdout 必须恰好一行：{stdout:?}");
    let v: serde_json::Value = serde_json::from_str(stdout.trim()).unwrap();
    let mut keys: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    assert_eq!(keys, ["daemon_reachable", "zip"], "键集合是契约：{v}");
    assert_eq!(v["zip"].as_str().unwrap(), out.to_str().unwrap());
    v["daemon_reachable"].as_bool().unwrap()
}

#[test]
fn offline_export_bundles_own_logs_and_starts_nothing() {
    let home = tempfile::tempdir().unwrap();
    let (platform_dir, library) = init_platform(home.path());
    let logs = platform_dir.join("logs");
    std::fs::create_dir_all(&logs).unwrap();
    let home_s = home.path().display().to_string();
    std::fs::write(
        logs.join("daemon.log"),
        format!("INFO current run at {home_s}/x\n"),
    )
    .unwrap();
    std::fs::write(logs.join("daemon.log.1"), "INFO previous run\n").unwrap();
    std::fs::write(logs.join("desktop.log"), "event=state to=running\n").unwrap();
    let out = home.path().join("exports").join("bundle.zip");

    let o = daemon_in(home.path())
        .args(["diag", "export", "--app-version", "0.9.9-shell", "--out"])
        .arg(&out)
        .output()
        .unwrap();
    assert!(!ok_json(&o, &out), "没有常驻服务 ⇒ daemon_reachable=false");

    let entries = read_zip(&out);
    let get = |n: &str| entries.iter().find(|(k, _)| k == n).map(|(_, v)| v.clone());
    let names: Vec<_> = entries.iter().map(|(k, _)| k.as_str()).collect();
    for want in [
        "README.txt",
        "versions.txt",
        "config-summary.txt",
        "log-sources.txt",
        "daemon.log",
        "daemon.log.1",
        "desktop.log",
        "daemon-unreachable.txt",
    ] {
        assert!(names.contains(&want), "缺 {want}：{names:?}");
    }
    for gone in [
        "diag_events.json",
        "devices.json",
        "audit.json",
        "daemon-stdout.log",
    ] {
        assert!(!names.contains(&gone), "{gone} 不该在离线包里：{names:?}");
    }
    let versions = get("versions.txt").unwrap();
    assert!(
        versions.contains("app_version    = 0.9.9-shell"),
        "{versions}"
    );
    assert!(versions.contains("daemon_reachable = no"), "{versions}");
    assert!(
        versions.contains("daemon_version = P-Pass daemon "),
        "{versions}"
    );
    assert!(get("daemon.log").unwrap().contains("current run"));
    assert!(get("daemon.log.1").unwrap().contains("previous run"));
    assert!(get("desktop.log").unwrap().contains("to=running"));
    let all: String = entries.iter().map(|(_, v)| v.as_str()).collect();
    assert!(!all.contains(&home_s), "家目录不得出包");
    assert!(get("config-summary.txt")
        .unwrap()
        .contains("bind_addr = 0.0.0.0:41145"));

    // 不启动任何 daemon 机制。
    assert!(!library.join(".ppf").exists(), "不得开库");
    assert!(!library.join("ipc.token").exists());
    assert!(!platform_dir.join("ipc.token").exists());
}

#[test]
fn unwritable_out_exits_1_with_one_line_error() {
    let home = tempfile::tempdir().unwrap();
    let blocker = home.path().join("file");
    std::fs::write(&blocker, b"x").unwrap();
    let out = blocker.join("bundle.zip");
    let o = daemon_in(home.path())
        .args(["diag", "export", "--out"])
        .arg(&out)
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(1), "stderr: {}", text(&o.stderr));
    assert_eq!(text(&o.stdout), "");
    assert_eq!(text(&o.stderr).lines().count(), 1, "{}", text(&o.stderr));
}

#[test]
fn diag_usage_errors_exit_2() {
    let home = tempfile::tempdir().unwrap();
    for args in [
        &["diag"][..],
        &["diag", "export"],
        &["diag", "export", "--out"],
        &["diag", "export", "--out", "a.zip", "--bogus"],
    ] {
        let o = daemon_in(home.path()).args(args).output().unwrap();
        assert_eq!(o.status.code(), Some(2), "{args:?}: {}", text(&o.stderr));
        assert!(text(&o.stderr).contains("用法"), "{args:?}");
        assert_eq!(text(&o.stdout), "");
    }
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
}

/// 常驻服务在线：经 IPC `logs.export` 要来三份 JSON 收进包；它写在库目录里的
/// 中间产物 `ppf-logs.zip` 读完即删（导出位置只由 `--out` 决定）。
#[test]
fn online_export_includes_daemon_json_and_leaves_no_second_copy() {
    struct KillOnDrop(std::process::Child);
    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let home = tempfile::tempdir().unwrap();
    let library = tempfile::tempdir().unwrap();
    // 常驻服务用场景脚本同款隔离（与 cli_flow 的 SEC-11 用例一致）。
    let mut child = KillOnDrop(
        Command::new(env!("CARGO_BIN_EXE_daemon"))
            .arg("--ephemeral")
            .env("PPF_DATA_DIR", library.path())
            .env("PPF_RELAY_URLS", "")
            .env("PPF_BIND_ADDR", "127.0.0.1:0")
            .env_remove("PPF_LOG_FILE")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let out = home.path().join("bundle.zip");
    let deadline = Instant::now() + Duration::from_secs(40);
    let reachable = loop {
        if library.path().join("ipc.token").exists() {
            let o = daemon_in(home.path())
                .env("PPF_DATA_DIR", library.path())
                .args(["diag", "export", "--out"])
                .arg(&out)
                .output()
                .unwrap();
            if ok_json(&o, &out) {
                break true;
            }
        }
        if Instant::now() > deadline {
            break false;
        }
        std::thread::sleep(Duration::from_millis(300));
    };
    drop(child.0.stdin.take());
    assert!(reachable, "40 秒内没连上测试用常驻服务");

    let names: Vec<String> = read_zip(&out).into_iter().map(|(k, _)| k).collect();
    for want in ["diag_events.json", "devices.json", "audit.json"] {
        assert!(names.iter().any(|n| n == want), "缺 {want}：{names:?}");
    }
    assert!(!names.iter().any(|n| n == "daemon-unreachable.txt"));
    assert!(
        !library.path().join("ppf-logs.zip").exists(),
        "库目录里不得留下第二份包"
    );
}
