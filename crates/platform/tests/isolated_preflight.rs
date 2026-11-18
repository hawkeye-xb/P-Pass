//! macOS：沙箱预检三态（docs/decisions/2026-11-18-sandbox-preflight-unknown-state.md）。
//! 「没跑起来」（被信号杀，dyld 缺库 / 被沙箱拦住时 worker 会 abort）必须是拉起失败
//! （明确拒绝，系统性失败），不是「这张图坏了」；worker 自己以任何码退出算证明能跑；
//! 预检超时（期限内没拿到结论）必须报「未知」（`ErrorKind::TimedOut`）且**不进成功缓存**，
//! 不是「已起来」——超时不许被折叠成成功（#1312）。

#![cfg(target_os = "macos")]
#![allow(clippy::disallowed_methods)]

use std::io::ErrorKind;
use std::time::Instant;

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

/// 编一个真二进制（shell 脚本会被沙箱直接拒掉，走不到超时分支）：睡 `secs` 秒再返回 0。
fn slow_binary(dir: &std::path::Path, secs: u64) -> std::path::PathBuf {
    let exe = dir.join("slow-worker");
    let src = dir.join("slow-worker.c");
    std::fs::write(
        &src,
        format!("#include <unistd.h>\nint main(void){{sleep({secs});return 0;}}\n"),
    )
    .unwrap();
    let out = std::process::Command::new("clang")
        .arg("-x")
        .arg("c")
        .arg("-o")
        .arg(&exe)
        .arg(&src)
        .output()
        .expect("clang 不可用");
    assert!(
        out.status.success(),
        "编译假 worker 失败：{}",
        String::from_utf8_lossy(&out.stderr)
    );
    exe
}

#[test]
fn preflight_separates_not_started_from_started() {
    std::env::set_var(
        "PPF_SEATBELT_TEST_EXEC",
        "/bin/sh:/bin/bash:/private/var/select/sh",
    );
    // 放宽时限：本用例判的是结论归类，不是期限长短；高负载下默认 5s 可能不够（#1312 现场）。
    std::env::set_var("PPF_PREFLIGHT_TIMEOUT_SECS", "30");
    let lim = Limits {
        memory_bytes: 1 << 30,
        win32k_lockdown: true,
    };
    let d = tempfile::tempdir().unwrap();
    // SIGKILL：不触发系统崩溃报告，退出不会慢过期限（SIGABRT 会，#1312 首发现场）。
    let killed = script(d.path(), "kill -KILL $$");
    let err = spawn_isolated(&killed, &lim)
        .err()
        .expect("被信号杀应判拉起失败");
    assert_eq!(
        err.kind(),
        ErrorKind::Other,
        "被信号杀是「明确拒绝」，不是超时未知：{err}"
    );
    let exits3 = script(d.path(), "exit 3");
    assert!(spawn_isolated(&exits3, &lim).is_ok(), "自行退出算起来了");
}

#[test]
fn preflight_timeout_is_unknown_and_not_cached() {
    let lim = Limits {
        memory_bytes: 1 << 30,
        win32k_lockdown: true,
    };
    let d = tempfile::tempdir().unwrap();
    let slow = slow_binary(d.path(), 6);
    // 注入 1s 期限（worker 睡 6s 必超）；用例跑完由 nextest 独立进程结束，不影响其它用例。
    std::env::set_var("PPF_PREFLIGHT_TIMEOUT_SECS", "1");

    let t = Instant::now();
    let first = spawn_isolated(&slow, &lim);
    let first_ms = t.elapsed().as_millis();
    let err = first
        .err()
        .expect("预检超时必须报错，不许宣称成功（ok=true 即把未知写成了成功，#1312）");
    assert_eq!(
        err.kind(),
        ErrorKind::TimedOut,
        "超时应报「未知」（TimedOut），不是明确拒绝：{err}"
    );

    // 没进成功缓存：第二次重新预检，又一次等到期限（远大于缓存命中会有的 0ms）。
    let t = Instant::now();
    let second = spawn_isolated(&slow, &lim);
    let second_ms = t.elapsed().as_millis();
    let err2 = second
        .err()
        .expect("第二次同样应报错（未知不许被缓存成成功）");
    assert_eq!(err2.kind(), ErrorKind::TimedOut);
    assert!(
        second_ms >= 900,
        "第二次调用耗时 {second_ms}ms（第一次 {first_ms}ms）——预检被缓存跳过：超时不许写成功缓存"
    );
}
