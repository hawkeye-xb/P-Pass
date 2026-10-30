//! 解码子进程的生命周期：时限、崩溃、回包不合法、找不到 worker，
//! 以及「真 worker 能解」的对照。
//!
//! 用环境变量 `PPF_DECODE_WORKER` 换 worker，所以各测试串行（同一进程的环境是共享的）。
//! 假 worker 是 sh 脚本，没有 sh 的机器上这几条跳过（对照测试仍跑）。

#![allow(clippy::disallowed_methods)]

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use media_codec::{decode_image, decode_image_within, CodecError};

static ENV: Mutex<()> = Mutex::new(());

fn real_worker() -> PathBuf {
    // cargo 把同 workspace 的 bin 放在 target/<profile>/，测试二进制在其 deps/ 下。
    let exe = std::env::current_exe().unwrap();
    let name = format!("ppf-decoder{}", std::env::consts::EXE_SUFFIX);
    let p = exe.parent().unwrap().parent().unwrap().join(name);
    assert!(
        p.is_file(),
        "先构建解码子进程：cargo build -p decode-worker --bin ppf-decoder（{}）",
        p.display()
    );
    p
}

fn png(dir: &Path) -> PathBuf {
    let p = dir.join("a.png");
    image::RgbImage::from_pixel(8, 4, image::Rgb([9, 9, 9]))
        .save(&p)
        .unwrap();
    p
}

fn fake_worker(dir: &Path, body: &str) -> Option<PathBuf> {
    if !Path::new("/bin/sh").exists() {
        eprintln!("没有 /bin/sh——跳过");
        return None;
    }
    let p = dir.join("fake-worker.sh");
    std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
    let ok = std::process::Command::new("chmod")
        .arg("+x")
        .arg(&p)
        .status()
        .unwrap()
        .success();
    assert!(ok);
    Some(p)
}

fn with_worker<T>(worker: &Path, f: impl FnOnce() -> T) -> T {
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var("PPF_DECODE_WORKER", worker);
    // macOS 的 Seatbelt 只放行执行 worker 本身；假 worker（sh 脚本）要用到的程序在此点名（仅调试构建认）。
    std::env::set_var(
        "PPF_SEATBELT_TEST_EXEC",
        "/bin/sh:/bin/bash:/private/var/select/sh:/bin/sleep:/bin/cat",
    );
    let out = f();
    std::env::remove_var("PPF_SEATBELT_TEST_EXEC");
    std::env::remove_var("PPF_DECODE_WORKER");
    out
}

#[test]
fn real_worker_decodes_and_caps_the_edge() {
    let dir = tempfile::tempdir().unwrap();
    let big = dir.path().join("big.png");
    image::RgbImage::from_pixel(3000, 1500, image::Rgb([200, 10, 10]))
        .save(&big)
        .unwrap();
    let img = with_worker(&real_worker(), || decode_image(&big)).unwrap();
    assert_eq!((img.width(), img.height()), (1024, 512));
    let small = png(dir.path());
    let img = with_worker(&real_worker(), || decode_image(&small)).unwrap();
    assert_eq!((img.width(), img.height()), (8, 4));
}

#[test]
fn corrupt_file_is_a_file_level_failure() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("bad.jpg");
    std::fs::write(&p, b"not an image").unwrap();
    let err = with_worker(&real_worker(), || decode_image(&p)).unwrap_err();
    assert!(matches!(err, CodecError::Decode { .. }), "{err:?}");
}

#[test]
fn missing_worker_is_unavailable() {
    let dir = tempfile::tempdir().unwrap();
    let p = png(dir.path());
    let err = with_worker(&dir.path().join("nope"), || decode_image(&p)).unwrap_err();
    assert!(matches!(err, CodecError::SandboxUnavailable(_)), "{err:?}");
}

#[test]
fn hung_worker_is_killed_at_the_deadline() {
    let dir = tempfile::tempdir().unwrap();
    let Some(w) = fake_worker(dir.path(), "sleep 60") else {
        return;
    };
    let p = png(dir.path());
    let t = Instant::now();
    let err = with_worker(&w, || decode_image_within(&p, Duration::from_millis(500))).unwrap_err();
    assert!(t.elapsed() < Duration::from_secs(10), "没有按时强杀");
    assert!(err.to_string().contains("timed out"), "{err}");
}

#[test]
fn crashing_worker_is_a_file_level_failure() {
    let dir = tempfile::tempdir().unwrap();
    let Some(w) = fake_worker(dir.path(), "exit 3") else {
        return;
    };
    let p = png(dir.path());
    let err = with_worker(&w, || decode_image(&p)).unwrap_err();
    assert!(matches!(err, CodecError::Decode { .. }), "{err:?}");
}

#[test]
fn garbage_answer_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let Some(w) = fake_worker(dir.path(), "cat >/dev/null; printf 'PPDRxxxxxxxxxxxxxxxx'") else {
        return;
    };
    let p = png(dir.path());
    let err = with_worker(&w, || decode_image(&p)).unwrap_err();
    assert!(matches!(err, CodecError::Decode { .. }), "{err:?}");
}

/// 被信号杀（dyld 缺库 / 被沙箱拦住时 worker 会 abort）= 沙箱里没跑起来 = 系统性失败，
/// 不是「这张图坏了」：否则一次环境问题会把整库永久冻成灰图。仅 macOS 的预检这样判。
#[cfg(target_os = "macos")]
#[test]
fn worker_killed_by_signal_is_unavailable_not_file_level() {
    let dir = tempfile::tempdir().unwrap();
    let Some(w) = fake_worker(dir.path(), "kill -ABRT $$") else {
        return;
    };
    let p = png(dir.path());
    let err = with_worker(&w, || decode_image(&p)).unwrap_err();
    assert!(matches!(err, CodecError::SandboxUnavailable(_)), "{err:?}");
}
