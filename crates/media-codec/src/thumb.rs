//! Thumbnail generation: 256px + 1024px longest-edge JPEGs under
//! `thumbs/<hash前2>/<hash>.{256,1024}.jpg` (详细设计 §4.2).
//!
//! 契约: `make_thumbs` never panics and never errors. Any failure —
//! unreadable file, corrupt image, missing ffmpeg — says so in the outcome
//! and the caller records `thumb_state = 2`.
//!
//! DESK-35 (#441): a failure writes **nothing** at the final thumb paths.
//! It used to write the placeholder JPEG there, and since a file at the
//! final path is a cache hit, one transient failure (qlmanage timing out
//! behind a permission prompt) froze that asset on the gray placeholder
//! forever. Now "a file at the final path" means "real pixels", and the
//! placeholder is served from memory ([`placeholder_jpeg`]) by whoever
//! answers the request, leaving the retry decision to the caller.

use std::fs;
use std::path::{Path, PathBuf};

use image::DynamicImage;

use crate::{ffmpeg, quicklook, sandbox, CodecError, Result};

pub const THUMB_SIZES: [u32; 2] = [256, 1024];
pub const JPEG_QUALITY: u8 = 85;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThumbPaths {
    pub t256: PathBuf,
    pub t1024: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ThumbOutcome {
    /// Real pixels. Caller records thumb_state = 1.
    Generated,
    /// Decode failed — nothing was written; `reason` is the human-readable
    /// cause. Caller serves [`placeholder_jpeg`] and records thumb_state = 2.
    Placeholder { reason: String },
    /// 解码子进程本机不可用（系统性问题）：nothing written，也**不**记
    /// thumb_state = 2 —— 否则一次系统问题会把整库永久冻成占位图
    /// （DESK-35 同类教训）。调用方走重试，仍先给占位图。
    Unavailable { reason: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThumbResult {
    pub paths: ThumbPaths,
    pub outcome: ThumbOutcome,
}

/// Where the thumbs of `hash` live under `thumbs_root` (§4.2 layout:
/// two-hex-char fan-out directory, then `<hash>.<size>.jpg`).
pub fn thumb_paths(thumbs_root: &Path, hash: &[u8; 32]) -> ThumbPaths {
    let hex: String = hash.iter().map(|b| format!("{b:02x}")).collect();
    let dir = thumbs_root.join(&hex[..2]);
    ThumbPaths {
        t256: dir.join(format!("{hex}.256.jpg")),
        t1024: dir.join(format!("{hex}.1024.jpg")),
    }
}

/// Generate both thumbnails for `src_path`, whose content hash is `hash`.
/// Video first-frame goes through ffmpeg; stills decode directly.
pub fn make_thumbs(hash: &[u8; 32], src_path: &Path, thumbs_root: &Path) -> ThumbResult {
    let paths = thumb_paths(thumbs_root, hash);
    match generate(src_path, &paths) {
        Ok(()) => ThumbResult {
            paths,
            outcome: ThumbOutcome::Generated,
        },
        Err(CodecError::SandboxUnavailable(reason)) => ThumbResult {
            paths,
            outcome: ThumbOutcome::Unavailable { reason },
        },
        // DESK-35 (#441): no placeholder at the final paths — see module doc.
        Err(e) => ThumbResult {
            paths,
            outcome: ThumbOutcome::Placeholder {
                reason: e.to_string(),
            },
        },
    }
}

fn generate(src_path: &Path, paths: &ThumbPaths) -> Result<()> {
    // #1044 B3：图/视频的判定只问 core-index 的唯一口径。
    let img = if core_index::media_kind(src_path) == Some(core_index::MediaKind::Video) {
        first_frame(src_path)?
    } else {
        sandbox::decode_image(src_path)?
    };
    // 先合成白底再缩放：非预乘 alpha 直接缩放会把透明像素里的黑色带进边缘。
    let img = flatten_on_white(img);
    write_thumb(&img, 256, &paths.t256)?;
    write_thumb(&img, 1024, &paths.t1024)?;
    Ok(())
}

fn first_frame(src: &Path) -> Result<DynamicImage> {
    // MOB-74 B (user decision 2026-09-13: 「能用系统的就先用系统的」):
    // ffmpeg keeps priority when the release pipeline ships or the operator
    // configures one (PPF_FFMPEG / bundled / PATH); otherwise macOS videos
    // fall through to the system Quick Look thumbnailer — zero bundle size,
    // zero license. Both fail -> Err -> make_thumbs reports Placeholder
    // (nothing on disk), and thumb_state=2 stays the durable evidence.
    match ffmpeg::ffmpeg_path() {
        Some(ff) => {
            let tmp = tempfile::Builder::new()
                .suffix(".jpg")
                .tempfile()
                .map_err(|source| CodecError::Io {
                    path: src.to_path_buf(),
                    source,
                })?;
            ffmpeg::extract_frame(&ff, src, tmp.path())?;
            sandbox::decode_image(tmp.path())
        }
        None => {
            // DESK-16 (#165)：系统兜底两半，按「本平台有没有这个能力」依次问。
            // macOS：qlmanage（探测固定路径，见 quicklook.rs）。
            if let Some(ql) = quicklook::qlmanage_path() {
                let dir = tempfile::Builder::new()
                    .tempdir()
                    .map_err(|source| CodecError::Io {
                        path: src.to_path_buf(),
                        source,
                    })?;
                let png = quicklook::extract_frame(&ql, src, dir.path())?;
                return sandbox::decode_image(&png);
            }
            // 没有系统兜底的平台（Windows）⇒ 只剩 ffmpeg 一条路，而它不在，
            // 视频给占位图。
            Err(CodecError::FfmpegMissing)
        }
    }
}

/// JPEG 没有透明通道：带 alpha 的图（透明 PNG、ICO、贴纸）按行业做法合成到
/// 白色背景上。直接丢掉 alpha 会露出透明像素里存的 RGB（多数是黑），照片墙
/// 上就成了黑块。不透明的图原样返回。
fn flatten_on_white(img: DynamicImage) -> DynamicImage {
    if !img.color().has_alpha() {
        return img;
    }
    let rgba = img.to_rgba8();
    let flat = image::RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
        let [r, g, b, a] = rgba.get_pixel(x, y).0;
        let a = u16::from(a);
        let over = |c: u8| ((u16::from(c) * a + 255 * (255 - a) + 127) / 255) as u8;
        image::Rgb([over(r), over(g), over(b)])
    });
    DynamicImage::ImageRgb8(flat)
}

/// Downscale to `size` longest edge (never upscale) and write atomically:
/// temp file in the target dir, then rename — a crash never leaves a
/// half-written thumb at the final path.
fn write_thumb(img: &DynamicImage, size: u32, dest: &Path) -> Result<()> {
    let scaled = if img.width() <= size && img.height() <= size {
        img.clone()
    } else {
        img.thumbnail(size, size)
    };
    write_jpeg_atomic(&scaled.to_rgb8(), dest)
}

/// The built-in placeholder: a neutral gray square with a darker inner
/// frame — obviously "no preview", deterministic, no bundled asset.
fn placeholder_image(size: u32) -> image::RgbImage {
    let mut img = image::RgbImage::from_pixel(size, size, image::Rgb([224, 224, 224]));
    let margin = size / 8;
    for x in margin..size - margin {
        for y in [margin, size - margin - 1] {
            img.put_pixel(x, y, image::Rgb([160, 160, 160]));
            img.put_pixel(y, x, image::Rgb([160, 160, 160]));
        }
    }
    img
}

/// The built-in placeholder as encoded JPEG bytes — what `thumb.get`
/// answers when generation can't finish in time (T-033's 5 s budget).
pub fn placeholder_jpeg(size: u32) -> Vec<u8> {
    let img = placeholder_image(size);
    let mut out = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY);
    // Encoding an in-memory RGB image into a Vec cannot fail for the
    // sizes we use; a hypothetical failure yields an empty (still
    // harmless) payload rather than a panic.
    let _ = enc.encode_image(&img);
    out
}

fn write_jpeg_atomic(img: &image::RgbImage, dest: &Path) -> Result<()> {
    let dir = dest.parent().unwrap_or(Path::new("."));
    let io_err = |source| CodecError::Io {
        path: dest.to_path_buf(),
        source,
    };
    fs::create_dir_all(dir).map_err(io_err)?;
    let tmp = tempfile::Builder::new()
        .prefix(".thumb-")
        .tempfile_in(dir)
        .map_err(io_err)?;
    {
        use std::io::Write;
        let mut writer = std::io::BufWriter::new(tmp.as_file());
        let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut writer, JPEG_QUALITY);
        enc.encode_image(img).map_err(|e| CodecError::Decode {
            path: dest.to_path_buf(),
            msg: e.to_string(),
        })?;
        writer.flush().map_err(io_err)?;
    }
    tmp.persist(dest).map_err(|e| CodecError::Io {
        path: dest.to_path_buf(),
        source: e.error,
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_is_two_hex_fanout() {
        let paths = thumb_paths(Path::new("/t"), &[0xab; 32]);
        let hex = "ab".repeat(32);
        assert_eq!(paths.t256, PathBuf::from(format!("/t/ab/{hex}.256.jpg")));
        assert_eq!(paths.t1024, PathBuf::from(format!("/t/ab/{hex}.1024.jpg")));
    }

    #[test]
    fn placeholder_is_decodable_and_sized() {
        let img = placeholder_image(256);
        assert_eq!((img.width(), img.height()), (256, 256));
    }
}
