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

use platform::PlatformAdapter as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

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

/// #1167：服务形态的常驻管道整台机器只有一份（`ppf-svc`），改 HOME 的沙箱隔离不掉它。开发 /
/// 测试机上真装着、真在跑 P-Pass 服务时，导出会如实连上它——那是产品该有的行为，不是「离线」
/// 场景，测试跳过、不去打扰它（同 cli_flow 的做法）。
fn a_real_resident_daemon_answers() -> bool {
    let platform::ResidentIpc::UserPipe(pipe) = platform::adapter().resident_ipc() else {
        return false;
    };
    let endpoint = daemon::ipc::PeerEndpoint::Pipe(pipe);
    tokio::runtime::Runtime::new()
        .expect("tokio runtime")
        .block_on(endpoint.connect())
        .is_ok()
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).to_string()
}

/// [`daemon_in`] 的环境下，子进程的平台数据目录在三种平台上分别是这几个之一。
/// #1115 之前靠 `config init` 的输出拿到它；那个 CLI 写入口删掉了，于是把三处都备好
/// （测试里不写平台分支——arch-check B.2）。
fn platform_dir_candidates(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join("Library/Application Support/P-Pass"), // macOS
        home.join("xdg").join("p-pass"),                 // Linux（XDG_DATA_HOME）
        home.join("local").join("com.hawkeyexb.ppass.desktop"), // Windows（LOCALAPPDATA）
    ]
}

/// 建好平台目录 + 库（写入经 daemon 的唯一写者 `LibraryLocation::set`），返回
/// (平台目录候选, 库目录)。
fn init_platform(home: &Path) -> (Vec<PathBuf>, PathBuf) {
    let library = home.join("Pictures").join("lib");
    let dirs = platform_dir_candidates(home);
    for dir in &dirs {
        daemon::library_location::LibraryLocation::with(None, dir.clone())
            .set(library.to_str().unwrap())
            .unwrap();
    }
    (dirs, library)
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
    if a_real_resident_daemon_answers() {
        eprintln!(
            "跳过：这台机器上真有常驻 P-Pass 服务在线，导出会如实连上它，不是本测试的离线场景"
        );
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let (platform_dirs, library) = init_platform(home.path());
    let home_s = home.path().display().to_string();
    for platform_dir in &platform_dirs {
        let logs = platform_dir.join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(
            logs.join("daemon.log"),
            format!("INFO current run at {home_s}/x\n"),
        )
        .unwrap();
        std::fs::write(logs.join("daemon.log.1"), "INFO previous run\n").unwrap();
        std::fs::write(logs.join("desktop.log"), "event=state to=running\n").unwrap();
    }
    let platform_dir = platform_dirs[0].clone();
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
    // daemon 日志文件是否存在由平台端口决定：桌面平台落 `<平台目录>/logs/daemon.log`；
    // 无桌面托管的 Linux 只写 stderr（交给 systemd / Docker），包里如实写缺失说明。
    let daemon_logs_to_file = platform::adapter()
        .daemon_log_paths(&platform_dir)
        .log_file
        .is_some();
    for want in [
        "README.txt",
        "versions.txt",
        "config-summary.txt",
        "log-sources.txt",
        "desktop.log",
        "daemon-unreachable.txt",
    ] {
        assert!(names.contains(&want), "缺 {want}：{names:?}");
    }
    if daemon_logs_to_file {
        assert!(get("daemon.log").unwrap().contains("current run"));
        assert!(get("daemon.log.1").unwrap().contains("previous run"));
    } else {
        assert!(names.contains(&"daemon-log-missing.txt"), "{names:?}");
        assert!(!names.contains(&"daemon.log"), "{names:?}");
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
    assert!(get("desktop.log").unwrap().contains("to=running"));
    let all: String = entries.iter().map(|(_, v)| v.as_str()).collect();
    assert!(!all.contains(&home_s), "家目录不得出包");
    assert!(get("config-summary.txt")
        .unwrap()
        .contains("bind_addr = 0.0.0.0:41145"));

    // 不启动任何 daemon 机制。
    // `.ppf/` 本身是写库位置时建出的空库标记（#1253）；开库才会在里面建索引。
    assert!(!library.join(".ppf/index.sqlite").exists(), "不得开库");
    assert!(!library.join("ipc.token").exists());
    for platform_dir in &platform_dirs {
        assert!(!platform_dir.join("ipc.token").exists());
    }
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

// 「常驻服务在线」那条已挪到 tests/ipc_roles.rs（进程内）：#1115 之后测试沙盒不收
// `PPF_DATA_DIR`、诊断导出也不认它，子进程版的指向方式不复存在。
