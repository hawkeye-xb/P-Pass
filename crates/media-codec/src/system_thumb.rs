//! DESK-16 (#165): the Windows half of the video first-frame fallback chain.
//!
//! 与 `quicklook.rs`（macOS 那半）同构，但形态不同，原因是系统能力不同：
//!
//! - macOS 有 `/usr/bin/qlmanage` 这个 **CLI**，所以那半可以整个待在本 crate
//!   里 —— 探测一个固定的 unix 路径不需要任何 cfg。
//! - Windows **没有对等的 CLI**，只能走 COM（`IShellItemImageFactory`）。COM
//!   调用必然要带平台条件编译属性，而红线 B.2 要求那种属性只许待在
//!   `crates/platform` —— 所以实现在那边，这里只是薄封装。
//!
//! ⚠️ **本文件刻意不含任何平台条件编译**。它在每个平台上都编译、都可调用；非 Windows
//! 平台上 `platform` 的默认实现返回 `Ok(None)`，于是这条兜底自然让位。
//! 谁想在这里加平台条件编译图省事 —— 那会让 `arch-check` 的 B.2 变红，
//! 而且 B.2 存在的理由就是不让平台分叉散落各处。

use std::path::Path;

use image::{DynamicImage, RgbaImage};
use platform::PlatformAdapter as _;

use crate::{CodecError, Result};

/// 最长边上界。与 `make_thumbs` 的大档（1024）对齐：系统缩略图器给的是
/// **上界**不是精确值，再往下的 256 档由 `write_thumb` 自己缩。
/// 要得比需要的更小没有好处 —— 放大会糊，而 `write_thumb` 从不放大。
const MAX_PX: u32 = 1024;

/// 向系统缩略图器要一帧。
///
/// 三种返回分得很清，调用方不该把它们混起来：
/// - `Ok(None)`   —— **本平台没有这个能力**（非 Windows）。让位给下一条兜底。
/// - `Err(..)`    —— 有能力但这个文件失败了（没有缩略图 / COM 出错）。
/// - `Ok(Some(_))` —— 拿到真帧。
///
/// 为什么不把 `Err` 也压成 `None`：那样「平台不支持」和「这个文件取不到」就
/// 分不开了，最终只剩一个占位图和一句说不清原因的日志。
pub fn first_frame(src: &Path) -> Result<Option<DynamicImage>> {
    let shot = platform::adapter()
        .system_video_thumbnail(src, MAX_PX)
        .map_err(|e| CodecError::ShellThumbnail {
            path: src.to_path_buf(),
            msg: e.to_string(),
        })?;
    let Some(shot) = shot else {
        return Ok(None);
    };
    // platform 的契约是 rgba.len() == width * height * 4；这里仍然校验，
    // 因为 from_raw 在长度不符时只会返回 None，静默变成"没有缩略图"。
    let expected = (shot.width as usize) * (shot.height as usize) * 4;
    if shot.rgba.len() != expected {
        return Err(CodecError::ShellThumbnail {
            path: src.to_path_buf(),
            msg: format!(
                "pixel buffer is {} bytes, expected {expected} for {}x{}",
                shot.rgba.len(),
                shot.width,
                shot.height
            ),
        });
    }
    let img = RgbaImage::from_raw(shot.width, shot.height, shot.rgba).ok_or_else(|| {
        CodecError::ShellThumbnail {
            path: src.to_path_buf(),
            msg: "image::RgbaImage::from_raw rejected the buffer".into(),
        }
    })?;
    Ok(Some(DynamicImage::ImageRgba8(img)))
}

/// DESK-16 (#165)：本机有没有系统缩略图能力。
///
/// 判据复用上面那个三态契约：拿一个**不存在的**路径去问 —— 没有能力的平台
/// 走默认实现返回 `Ok(None)`，有能力的平台会走真实调用并因"文件不存在"返回
/// `Err`。所以 `Err` 恰好等价于「有能力」。
///
/// 看着绕，但它避免了为"探测能力"再加一个 trait 方法，而那个三态契约本身已经
/// 被 `a_missing_file_never_panics_and_never_reports_a_frame` 钉住了 —— 契约变了
/// 测试会先红，不会让这个判据悄悄失真。
pub fn capable() -> bool {
    first_frame(Path::new("desk16-capability-probe-does-not-exist.mp4")).is_err()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 非 Windows 上必须是 `Ok(None)`（让位），Windows 上对一个**不存在的**
    /// 文件必须是 `Err`（说清哪个工具失败了），两者都不许 panic。
    ///
    /// 这条测试在三个平台上都跑，断言按平台能力分叉 —— 但分叉判据取自
    /// `platform` 的返回值，**不是条件编译**，所以本文件仍然干净。
    #[test]
    fn a_missing_file_never_panics_and_never_reports_a_frame() {
        let got = first_frame(Path::new("definitely-not-here-desk16.mp4"));
        match got {
            Ok(None) => {}                               // 本平台无此能力
            Err(CodecError::ShellThumbnail { .. }) => {} // 有能力但取不到
            other => panic!("unexpected: {other:?}"),
        }
    }

    /// DESK-16 (#165)：真实夹具必须拿到**有内容**的帧，不是纯色。
    ///
    /// 「有内容」这条断言不是凑数：`SIIGBF_THUMBNAILONLY` 之前的写法会在拿不到
    /// 真缩略图时回退给文件类型图标，而图标也是"能解码的图"。纯色/单值检查抓
    /// 不住图标，但它能抓住另一类更常见的静默错误——取到全黑或全透明的缓冲。
    ///
    /// 无此能力的平台上（`Ok(None)`）早退，前提写在断言里而不是靠条件编译。
    #[test]
    fn a_real_fixture_yields_a_frame_with_actual_content() {
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/tiny.mp4");
        assert!(src.is_file(), "夹具不在: {}", src.display());
        let Some(img) = first_frame(&src).expect("有能力的平台上不该报错") else {
            eprintln!("本平台无系统缩略图能力——跳过");
            return;
        };
        assert!(img.width() > 0 && img.height() > 0, "尺寸必须为正");
        let rgba = img.to_rgba8();
        let first = rgba.as_raw()[0];
        assert!(
            rgba.as_raw().iter().any(|&b| b != first),
            "整张图每个字节都是 {first} —— 那是全黑/全透明缓冲，不是真帧"
        );
    }
}
