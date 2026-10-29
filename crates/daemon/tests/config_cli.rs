//! #1042 / #1115：daemon 是 config 的唯一写者。#1115 起写入口从 CLI 子命令换成 IPC
//! `config.set_library`（只对签名窗口程序开放），写入逻辑在 `library_location::LibraryLocation`。
//!
//! 两组测试：
//!
//! 1. **与桌面壳现行实现逐字节等价**（验收标准 5）。`data/shell_config_golden.json`
//!    是拿壳 `apps/desktop/src-tauri/src/lib.rs` 里的 `render_config` /
//!    `merge_library_dir` / `normalize_separators` 原样代码、在壳锁定的
//!    `toml 0.8.2` 下跑出来的输出（两个 workspace 互不依赖，只能用 golden 对照；
//!    daemon 这边是 `toml 0.8.23`，序列化选单 / 双 / 三引号的规则若有漂移，
//!    这里会红）。覆盖：Unix 路径、中文、Windows 路径（健康 / 翻倍两次 /
//!    翻倍四次）、UNC、verbatim、含单引号、含双引号；合并覆盖空文档、带注释
//!    与 `[telemetry]` 段的真实形态、缩进的 `data_dir` 行、CRLF。
//! 2. **写入契约**（`LibraryLocation::set`，IPC `config.set_library` 的本体）：
//!    - 成功返回 `<平台目录>/config.toml`；首启写整份模板并建库目录，改库只改 `data_dir`；
//!    - 失败：校验类是壳 `ui_err` 同款 `{"key":"ui.err_…","params":{…}}`，建库失败是
//!      `"<库目录>: <io 错误>"`；失败不写文件；
//!    - 不碰任何 daemon 机制（不建 `.ppf`、不写 ipc.token）。
//! 3. **CLI 写入口已删除**：`daemon config …` 一律 exit 2、什么都不写。
//!
//! 平台目录一律在 tempdir 里，绝不碰本机真实的 P-Pass 数据目录。

// DESK-33 (#325)：测试框架 spawn 被测二进制，不是产品进程。
#![allow(clippy::disallowed_methods)]

use std::path::Path;
use std::process::Command;

use daemon::config::{merge_library_dir, render_first_run_config};
use daemon::library_location::LibraryLocation;

const GOLDEN: &str = include_str!("data/shell_config_golden.json");

#[test]
fn first_run_template_is_byte_identical_to_the_shell() {
    let golden: serde_json::Value = serde_json::from_str(GOLDEN).unwrap();
    let cases = golden["render"].as_array().unwrap();
    assert!(cases.len() >= 10, "golden 用例太少：{}", cases.len());
    for case in cases {
        let input = case[0].as_str().unwrap();
        let want = case[1].as_str().unwrap();
        assert_eq!(
            render_first_run_config(input),
            want,
            "首启模板与壳不一致，输入：{input:?}"
        );
        assert!(want.contains("bind_addr = \"0.0.0.0:41145\""), "{want}");
    }
}

#[test]
fn set_library_merge_is_byte_identical_to_the_shell() {
    let golden: serde_json::Value = serde_json::from_str(GOLDEN).unwrap();
    let cases = golden["merge"].as_array().unwrap();
    assert!(cases.len() >= 40, "golden 用例太少：{}", cases.len());
    for case in cases {
        let doc = case[0].as_str().unwrap();
        let input = case[1].as_str().unwrap();
        let want = case[2].as_str().unwrap();
        assert_eq!(
            merge_library_dir(doc, input),
            want,
            "换库合并与壳不一致，doc={doc:?} 输入={input:?}"
        );
    }
}

// ── 写入契约（LibraryLocation::set）──────────────────────────────────

/// 没有安全存储的写法（config.toml 即正本）：契约与 CLI 时代逐项相同。
fn location(home: &Path) -> LibraryLocation {
    LibraryLocation::with(None, home.join("platform"))
}

/// 写入不得触发任何 daemon 机制：不开库（`.ppf/` 只许是 #1253 的库标记，里面只有 #1260 的库 ID、
/// 没有索引）、没有 ipc.token，平台目录只有 config.toml 与记库 ID 的 `libraries/`。
fn assert_no_daemon_side_effects(platform_dir: &Path, library: &Path) {
    let marker = library.join(".ppf");
    assert!(marker.is_dir(), "#1253：写位置时要建出库标记");
    let inside: Vec<_> = std::fs::read_dir(&marker)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    assert_eq!(inside, vec!["library-id"], "不得开库：库标记里只有库 ID");
    let id = daemon::layout::read_library_id(library).expect("#1260：写位置时生成库 ID");
    assert_eq!(
        daemon::layout::recorded_library_id(platform_dir),
        Some(id),
        "#1260：库 ID 记进本机"
    );
    assert!(!library.join("ipc.token").exists(), "不得起 IPC");
    let mut entries: Vec<_> = std::fs::read_dir(platform_dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    entries.sort();
    assert_eq!(
        entries,
        vec!["config.toml", "libraries"],
        "平台目录只许多出 config.toml 与记库 ID 的 libraries/"
    );
    let libraries: Vec<_> = std::fs::read_dir(platform_dir.join("libraries"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    assert_eq!(
        libraries,
        vec!["current-library-id"],
        "不得开库：本机没有建出库数据"
    );
}

#[test]
fn first_set_writes_the_shell_template() {
    let home = tempfile::tempdir().unwrap();
    let library = home.path().join("Pictures").join("P-Pass 家庭照片库");
    let loc = location(home.path());
    let cfg = loc.set(library.to_str().unwrap()).unwrap();
    assert_eq!(cfg, home.path().join("platform/config.toml"));
    assert!(library.is_dir(), "首启必须把库目录建出来（DESK-57）");
    assert_eq!(
        std::fs::read_to_string(&cfg).unwrap(),
        render_first_run_config(library.to_str().unwrap()),
        "写盘内容就是模板"
    );
    assert_no_daemon_side_effects(cfg.parent().unwrap(), &library);
}

#[test]
fn uncreatable_library_fails_and_writes_nothing() {
    let home = tempfile::tempdir().unwrap();
    let blocker = home.path().join("not-a-dir");
    std::fs::write(&blocker, b"file").unwrap();
    let library = blocker.join("P-Pass 家庭照片库");
    let err = location(home.path())
        .set(library.to_str().unwrap())
        .unwrap_err();
    assert!(
        err.starts_with(&format!("{}: ", library.display())),
        "建库失败的错误串与壳一致（\"<库目录>: <io 错误>\"）：{err}"
    );
    assert!(!home.path().join("platform/config.toml").exists());
}

#[test]
fn changing_the_library_rewrites_one_line() {
    let home = tempfile::tempdir().unwrap();
    let old = home.path().join("old-lib");
    let new = home.path().join("new-lib");
    std::fs::create_dir_all(&new).unwrap();
    let loc = location(home.path());
    let cfg = loc.set(old.to_str().unwrap()).unwrap();
    // 用户 / 发版流程留下的其它内容必须逐字节保留。
    let mut doc = std::fs::read_to_string(&cfg).unwrap();
    doc.push_str("\n[telemetry]\nenabled = false\n");
    std::fs::write(&cfg, &doc).unwrap();
    assert_eq!(loc.set(new.to_str().unwrap()).unwrap(), cfg);
    assert_eq!(
        std::fs::read_to_string(&cfg).unwrap(),
        merge_library_dir(&doc, new.to_str().unwrap())
    );
    assert_no_daemon_side_effects(cfg.parent().unwrap(), &new);
}

#[test]
fn verdict_errors_are_keyed_json_and_write_nothing() {
    let home = tempfile::tempdir().unwrap();
    let lib = home.path().join("lib");
    let loc = location(home.path());
    let cfg = loc.set(lib.to_str().unwrap()).unwrap();
    let before = std::fs::read(&cfg).unwrap();
    let missing = home.path().join("nope");
    let nested = lib.join("sub");
    std::fs::create_dir_all(&nested).unwrap();
    for (target, key, params) in [
        (
            missing.clone(),
            "ui.err_library_target_missing",
            serde_json::json!({ "dir": missing.to_str().unwrap() }),
        ),
        (
            nested.clone(),
            "ui.err_library_nested",
            serde_json::json!({}),
        ),
    ] {
        let err = loc.set(target.to_str().unwrap()).unwrap_err();
        let v: serde_json::Value = serde_json::from_str(err.trim()).expect("keyed JSON");
        assert_eq!(v, serde_json::json!({ "key": key, "params": params }));
        assert_eq!(std::fs::read(&cfg).unwrap(), before, "校验失败不得写文件");
    }
}

// ── CLI 写入口已删除（#1115）──────────────────────────────────────────

/// 签名的 daemon 谁都能带参数运行：CLI 上不许有任何写照片库位置的入口。
/// 反证：把 `config init` 子命令加回 cli.rs ⇒ exit 0 且写出 config.toml，红。
#[test]
fn config_subcommands_are_rejected_and_write_nothing() {
    let home = tempfile::tempdir().unwrap();
    for args in [
        &["config", "init", "--library", "/tmp/x"][..],
        &["config", "set-library", "/tmp/x"],
        &["config"],
    ] {
        let o = Command::new(env!("CARGO_BIN_EXE_daemon"))
            .env("HOME", home.path())
            .env("USERPROFILE", home.path())
            .env("XDG_DATA_HOME", home.path().join("xdg"))
            .env("APPDATA", home.path().join("roaming"))
            .env("LOCALAPPDATA", home.path().join("local"))
            .args(args)
            .output()
            .expect("spawn daemon");
        assert_eq!(o.status.code(), Some(2), "{args:?}");
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(err.contains("#1115"), "{args:?}: {err}");
        assert!(o.stdout.is_empty());
    }
    assert_eq!(
        std::fs::read_dir(home.path()).unwrap().count(),
        0,
        "什么都不许写"
    );
}
