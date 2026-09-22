//! DESK-16 (#165)：回退链 Windows 那半的端到端证明。
//!
//! 与 `ql_fallback.rs`（macOS 那半）是同一个形状、同一个理由：**发布产物从未
//! 在任何平台携带 ffmpeg**，所以「机器上没有 ffmpeg」才是真实的用户处境，
//! 而不是边缘情况。MOB-74 给 macOS 补了 Quick Look 兜底，本卡给 Windows 补
//! Shell 缩略图兜底 —— 在此之前 Windows 上每个视频缩略图都静默降级成灰色
//! 占位图（`thumb_state=2`）。
//!
//! 单独的集成测试：它要改进程环境变量，不能和 lib 里那些"优先用 ffmpeg"的
//! 测试抢同一个进程。**不带任何平台条件编译**（红线 B.2）：测试把自己的环境
//! 前提显式写出来，前提不成立就早退并说明原因 —— 在没有系统缩略图能力的机器
//! 上，这条兜底根本不是可达路径，测试如实说出这件事，而不是假装通过。

use std::path::Path;

use image::GenericImageView;
use media_codec::{make_thumbs, ThumbOutcome};

#[test]
fn video_thumbs_survive_a_machine_without_ffmpeg_on_windows() {
    // 把 ffmpeg 从所有发现渠道里拿掉：env 覆盖、PATH。
    // PATH 设成两个 unix 系统目录 —— 在 Windows 上它们压根不存在，等价于
    // 「PATH 上没有任何可执行文件」，这正是我们要的；在 unix 上它是系统目录，
    // 与 ql_fallback.rs 的做法一致。一行代码在两个平台上都达到"擦干净"的效果。
    std::env::remove_var("PPF_FFMPEG");
    std::env::set_var("PATH", "/usr/bin:/bin");

    if media_codec::ffmpeg_path().is_some() {
        eprintln!("擦过 PATH 后仍能解析到 ffmpeg —— 本机上这条兜底不是可达路径，跳过");
        return;
    }
    if !media_codec::system_thumbnail_capable() {
        eprintln!("本平台没有系统缩略图能力（非 Windows）—— 跳过");
        return;
    }

    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/tiny.mp4");
    let dir = tempfile::tempdir().unwrap();
    let r = make_thumbs(&[0x16; 32], &fixture, &dir.path().join("t"));

    // 本卡的全部意义：Windows 上占位图不再是可接受结果。
    assert_eq!(
        r.outcome,
        ThumbOutcome::Generated,
        "没有 ffmpeg 时，Shell 缩略图必须把视频缩略图接住（实得 {:?}）",
        r.outcome
    );
    for p in [&r.paths.t256, &r.paths.t1024] {
        let img = image::open(p).unwrap_or_else(|e| panic!("{p:?} 必须可解码: {e}"));
        let (w, h) = img.dimensions();
        assert!(w > 0 && h > 0, "缩略图必须是真像素");
    }
    let (w, h) = image::open(&r.paths.t256).unwrap().dimensions();
    assert!(w.max(h) <= 256, "256 档必须被缩小，实得 {w}x{h}");
}
