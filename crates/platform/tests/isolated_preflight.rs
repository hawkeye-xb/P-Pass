//! macOS：沙箱里没跑起来（被信号杀，dyld 缺库 / 被沙箱拦住时 worker 会 abort）必须是
//! 拉起失败（系统性失败，调用方重试），不是「这张图坏了」；worker 自己以任何码退出算起来了。

#![cfg(target_os = "macos")]
#![allow(clippy::disallowed_methods)]

use platform::isolated::{spawn_isolated, Limits};

fn script(dir: &std::path::Path, body: &str) -> std::path::PathBuf {
    let p = dir.join("w.sh");
    std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
    assert!(std::process::Command::new("chmod")
        .arg("+x")
        .arg(&p)
        .status()
        .unwrap()
        .success());
    p
}

#[test]
fn preflight_separates_not_started_from_started() {
    std::env::set_var(
        "PPF_SEATBELT_TEST_EXEC",
        "/bin/sh:/bin/bash:/private/var/select/sh",
    );
    let lim = Limits {
        memory_bytes: 1 << 30,
    };
    let d = tempfile::tempdir().unwrap();
    let killed = script(d.path(), "kill -ABRT $$");
    assert!(
        spawn_isolated(&killed, &lim).is_err(),
        "被信号杀应判拉起失败"
    );
    let exits3 = script(d.path(), "exit 3");
    assert!(spawn_isolated(&exits3, &lim).is_ok(), "自行退出算起来了");
}
