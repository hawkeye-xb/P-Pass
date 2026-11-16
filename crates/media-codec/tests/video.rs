//! 视频首帧解码子进程（`ppf-video-decoder`，Windows Media Foundation）的契约：
//! 真 worker 能解、畸形输入归类 Decode、缺失归类 SandboxUnavailable。
//!
//! 只在 Windows 上有真实 worker；非 Windows 端这些测试跳过（worker 是桩）。

#![allow(clippy::disallowed_methods)]

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use media_codec::{decode_video, make_thumbs, CodecError, ThumbOutcome};

/// 串行化对 `PPF_VIDEO_DECODE_WORKER` 的读写：cargo test 默认并行跑，
/// 一个测试改环境变量会污染另一个测试的 worker 解析（与 sandbox.rs 同款）。
static ENV: Mutex<()> = Mutex::new(());

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// 本平台没有视频解码能力时跳过（不写 `#[cfg]`，问 platform 的能力接口，B.2）。
fn skip_if_no_video_decode() -> bool {
    if platform::video_decode::video_decode_available() {
        return false;
    }
    eprintln!("本平台无视频解码能力（非 Windows），跳过");
    true
}

/// 断言像素不是纯色占位块（真实画面至少有不同颜色）。
fn assert_non_flat(img: &image::DynamicImage) {
    let rgba = img.to_rgba8();
    let first = rgba.get_pixel(0, 0);
    let distinct = rgba.pixels().any(|p| p != first);
    assert!(distinct, "解码出的帧必须是真实画面，不是纯色块");
}

#[test]
fn video_decoder_decodes_first_frame() {
    if skip_if_no_video_decode() {
        return;
    }
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let img = decode_video(&fixture("tiny.mp4")).expect("视频 decoder 应能解 H.264 MP4 首帧");
    assert_eq!((img.width(), img.height()), (64, 48), "fixture 是 64x48");
    assert_non_flat(&img);
}

#[test]
fn video_decoder_malformed_input_is_a_file_level_failure() {
    if skip_if_no_video_decode() {
        return;
    }
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("bad.mp4");
    std::fs::write(&p, b"this is not an mp4 at all").unwrap();
    let err = decode_video(&p).unwrap_err();
    assert!(matches!(err, CodecError::Decode { .. }), "{err:?}");
}

#[test]
fn video_decoder_missing_worker_is_unavailable() {
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("clip.mp4");
    std::fs::write(&p, b"whatever").unwrap();
    // debug 构建认环境变量，指向一个不存在的 worker → 拉起失败 = 系统性问题。
    std::env::set_var("PPF_VIDEO_DECODE_WORKER", dir.path().join("nope"));
    let err = decode_video(&p).unwrap_err();
    std::env::remove_var("PPF_VIDEO_DECODE_WORKER");
    assert!(matches!(err, CodecError::SandboxUnavailable(_)), "{err:?}");
}

/// 根因入口（卡「修复 E3」/ ADR 决定 6 的可判红判据）：无 ffmpeg 的 Windows 上，
/// `make_thumbs` 经 `thumb.rs::first_frame` 必须走新 video decoder 出真图。
/// 反证：把 `first_frame` 的 video 分支改回 `Err(FfmpegMissing)` → 本测试红。
#[test]
fn make_thumbs_without_ffmpeg_uses_video_decoder() {
    if skip_if_no_video_decode() {
        return;
    }
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    // 把 ffmpeg 摘出 PATH（并清 PPF_FFMPEG），让 ffmpeg_path() 返回 None；只留
    // System32（不含 ffmpeg）。video decoder 由绝对路径拉起，不依赖 PATH。
    let saved_path = std::env::var("PATH").unwrap_or_default();
    std::env::remove_var("PPF_FFMPEG");
    std::env::set_var("PATH", r"C:\Windows\System32");
    let dir = tempfile::tempdir().unwrap();
    let r = make_thumbs(&[0x46; 32], &fixture("tiny.mp4"), &dir.path().join("t"));
    std::env::set_var("PATH", saved_path);
    assert_eq!(
        r.outcome,
        ThumbOutcome::Generated,
        "无 ffmpeg 的 Windows 上 mp4 必须经 first_frame 的 video decoder 分支出真图，而不是占位图"
    );
    assert_non_flat(&image::open(&r.paths.t256).unwrap());
}
