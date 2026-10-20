//! #1042：daemon 成为 config 的唯一写者——`config init` / `config set-library`
//! 子命令的等价性与 CLI 契约。
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
//! 2. **CLI 契约**（#1045 壳改调依赖它）：
//!    - 成功：exit 0，stdout 一行 `{"config":"<平台目录>/config.toml"}`，stderr 空；
//!    - 操作失败：exit 1，stdout 空，stderr 一行错误原文——校验类是壳
//!      `ui_err` 同款 `{"key":"ui.err_…","params":{…}}`，建库失败是
//!      `"<库目录>: <io 错误>"`（与壳现行返回值一致）；
//!    - 用法错误：exit 2，stderr 带用法；
//!    - 不启动任何 daemon 机制（不建 `.ppf`、不铸身份、不写 ipc.token、不起日志）。
//!
//! 平台目录经 HOME / XDG_DATA_HOME / APPDATA / LOCALAPPDATA 全部指进 tempdir，
//! 绝不碰本机真实的 P-Pass 数据目录。

// DESK-33 (#325)：测试框架 spawn 被测二进制，不是产品进程。
#![allow(clippy::disallowed_methods)]

use std::path::Path;
use std::process::{Command, Output};

use daemon::config::{merge_library_dir, render_first_run_config};

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

// ── CLI 契约 ─────────────────────────────────────────────────────────

/// 把所有平台的数据目录来源都指进 `home`。
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

fn run(home: &Path, args: &[&str]) -> Output {
    daemon_in(home).args(args).output().expect("spawn daemon")
}

fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).to_string()
}
fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).to_string()
}

/// 成功输出：恰好一行 JSON，`config` 指向 tempdir 里的 config.toml。
fn config_path_from(o: &Output, home: &Path) -> std::path::PathBuf {
    let out = stdout(o);
    assert_eq!(out.lines().count(), 1, "stdout 必须恰好一行：{out:?}");
    let v: serde_json::Value = serde_json::from_str(out.trim()).expect("stdout 必须是 JSON");
    let obj = v.as_object().unwrap();
    assert_eq!(
        obj.keys().collect::<Vec<_>>(),
        vec!["config"],
        "键集合是契约：{v}"
    );
    let p = std::path::PathBuf::from(v["config"].as_str().unwrap());
    assert!(p.starts_with(home), "config 必须落在被测平台目录里：{p:?}");
    assert_eq!(p.file_name().unwrap(), "config.toml");
    p
}

/// 子命令不得触发任何 daemon 机制：库目录里没有 `.ppf`（数据库 / 身份 /
/// ipc.token 都在那里），平台目录里只有 config.toml（没有日志目录）。
fn assert_no_daemon_side_effects(platform_dir: &Path, library: &Path, o: &Output) {
    assert!(!library.join(".ppf").exists(), "不得开库");
    assert!(!library.join("ipc.token").exists(), "不得起 IPC");
    let entries: Vec<_> = std::fs::read_dir(platform_dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    assert_eq!(entries, vec!["config.toml"], "平台目录只许多出 config.toml");
    let both = format!("{}{}", stdout(o), stderr(o));
    for marker in ["IPC:", "身份密钥已铸造", "已启动"] {
        assert!(
            !both.contains(marker),
            "不得启动 daemon（{marker}）：{both}"
        );
    }
}

#[test]
fn config_init_writes_the_shell_template_and_starts_nothing() {
    let home = tempfile::tempdir().unwrap();
    let library = home.path().join("Pictures").join("P-Pass 家庭照片库");
    let o = run(
        home.path(),
        &["config", "init", "--library", library.to_str().unwrap()],
    );
    assert_eq!(o.status.code(), Some(0), "stderr: {}", stderr(&o));
    assert_eq!(stderr(&o), "", "成功时 stderr 必须为空");
    let cfg = config_path_from(&o, home.path());
    assert!(library.is_dir(), "首启必须把库目录建出来（DESK-57）");
    assert_eq!(
        std::fs::read_to_string(&cfg).unwrap(),
        render_first_run_config(library.to_str().unwrap()),
        "写盘内容就是模板"
    );
    assert_no_daemon_side_effects(cfg.parent().unwrap(), &library, &o);
}

#[test]
fn config_init_uncreatable_library_exits_1_and_writes_nothing() {
    let home = tempfile::tempdir().unwrap();
    let blocker = home.path().join("not-a-dir");
    std::fs::write(&blocker, b"file").unwrap();
    let library = blocker.join("P-Pass 家庭照片库");
    let o = run(
        home.path(),
        &["config", "init", "--library", library.to_str().unwrap()],
    );
    assert_eq!(o.status.code(), Some(1), "stderr: {}", stderr(&o));
    assert_eq!(stdout(&o), "", "失败时 stdout 必须为空");
    let err = stderr(&o);
    assert_eq!(err.lines().count(), 1, "stderr 必须恰好一行：{err:?}");
    assert!(
        err.starts_with(&format!("{}: ", library.display())),
        "建库失败的错误串与壳一致（\"<库目录>: <io 错误>\"）：{err}"
    );
}

#[test]
fn config_set_library_rewrites_one_line_and_starts_nothing() {
    let home = tempfile::tempdir().unwrap();
    let old = home.path().join("old-lib");
    let new = home.path().join("new-lib");
    std::fs::create_dir_all(&new).unwrap();
    let o = run(
        home.path(),
        &["config", "init", "--library", old.to_str().unwrap()],
    );
    assert_eq!(o.status.code(), Some(0), "stderr: {}", stderr(&o));
    let cfg = config_path_from(&o, home.path());
    // 用户 / 发版流程留下的其它内容必须逐字节保留。
    let mut doc = std::fs::read_to_string(&cfg).unwrap();
    doc.push_str("\n[telemetry]\nenabled = false\n");
    std::fs::write(&cfg, &doc).unwrap();

    let o = run(
        home.path(),
        &["config", "set-library", new.to_str().unwrap()],
    );
    assert_eq!(o.status.code(), Some(0), "stderr: {}", stderr(&o));
    assert_eq!(stderr(&o), "");
    assert_eq!(config_path_from(&o, home.path()), cfg);
    assert_eq!(
        std::fs::read_to_string(&cfg).unwrap(),
        merge_library_dir(&doc, new.to_str().unwrap())
    );
    assert_no_daemon_side_effects(cfg.parent().unwrap(), &new, &o);
}

#[test]
fn config_set_library_verdict_errors_are_keyed_json_on_stderr() {
    let home = tempfile::tempdir().unwrap();
    let lib = home.path().join("lib");
    let o = run(
        home.path(),
        &["config", "init", "--library", lib.to_str().unwrap()],
    );
    assert_eq!(o.status.code(), Some(0));
    let cfg = config_path_from(&o, home.path());
    let before = std::fs::read(&cfg).unwrap();

    let missing = home.path().join("nope");
    let nested = lib.join("sub");
    std::fs::create_dir_all(&nested).unwrap();
    for (target, key, params) in [
        (
            missing.to_str().unwrap().to_string(),
            "ui.err_library_target_missing",
            serde_json::json!({ "dir": missing.to_str().unwrap() }),
        ),
        (
            nested.to_str().unwrap().to_string(),
            "ui.err_library_nested",
            serde_json::json!({}),
        ),
    ] {
        let o = run(home.path(), &["config", "set-library", &target]);
        assert_eq!(o.status.code(), Some(1), "{target}: {}", stderr(&o));
        assert_eq!(stdout(&o), "");
        let err = stderr(&o);
        assert_eq!(err.lines().count(), 1, "stderr 必须恰好一行：{err:?}");
        let v: serde_json::Value = serde_json::from_str(err.trim()).expect("keyed JSON");
        assert_eq!(v, serde_json::json!({ "key": key, "params": params }));
        assert_eq!(std::fs::read(&cfg).unwrap(), before, "校验失败不得写文件");
    }
}

#[test]
fn config_usage_errors_exit_2_with_usage() {
    let home = tempfile::tempdir().unwrap();
    for args in [
        &["config"][..],
        &["config", "init"],
        &["config", "init", "/x"],
        &["config", "set-library"],
        &["config", "frobnicate"],
    ] {
        let o = run(home.path(), args);
        assert_eq!(o.status.code(), Some(2), "{args:?}: {}", stderr(&o));
        assert!(stderr(&o).contains("用法"), "{args:?}: {}", stderr(&o));
        assert_eq!(stdout(&o), "");
    }
    // 用法错误什么都不写。
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
}
