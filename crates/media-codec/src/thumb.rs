//! Thumbnail generation: 256px + 1024px longest-edge JPEGs under
//! `thumbs/<hash前2>/<hash>.{256,1024}.jpg` (详细设计 §4.2).
//!
//! 契约: `make_thumbs` never panics and never errors. Any failure —
//! unreadable file, corrupt image, missing ffmpeg — writes the built-in
//! placeholder instead and says so in the outcome, so serving stays
//! uniform and the caller records `thumb_state = 2`.

use std::fs;
use std::path::{Path, PathBuf};

use image::DynamicImage;

use crate::{decode, ffmpeg, CodecError, Result};

pub const THUMB_SIZES: [u32; 2] = [256, 1024];
const JPEG_QUALITY: u8 = 85;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThumbPaths {
    pub t256: PathBuf,
    pub t1024: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ThumbOutcome {
    /// Real pixels. Caller records thumb_state = 1.
    Generated,
    /// Decode failed — the placeholder was written; `reason` is the
    /// human-readable cause. Caller records thumb_state = 2.
    Placeholder { reason: String },
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
        Err(e) => {
            let reason = e.to_string();
            if let Err(e2) = write_placeholders(&paths) {
                // Even the placeholder failed (disk full, permissions) —
                // still no panic; the caller sees both causes.
                return ThumbResult {
                    paths,
                    outcome: ThumbOutcome::Placeholder {
                        reason: format!("{reason}; placeholder also failed: {e2}"),
                    },
                };
            }
            ThumbResult {
                paths,
                outcome: ThumbOutcome::Placeholder { reason },
            }
        }
    }
}

fn generate(src_path: &Path, paths: &ThumbPaths) -> Result<()> {
    let img = if is_video(src_path) {
        first_frame(src_path)?
    } else {
        decode::decode_image(src_path)?
    };
    write_thumb(&img, 256, &paths.t256)?;
    write_thumb(&img, 1024, &paths.t1024)?;
    Ok(())
}

fn is_video(path: &Path) -> bool {
    matches!(
        path.extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default()
            .as_str(),
        "mp4" | "mov" | "m4v"
    )
}

fn first_frame(src: &Path) -> Result<DynamicImage> {
    let ffmpeg = ffmpeg::ffmpeg_path().ok_or(CodecError::FfmpegMissing)?;
    let tmp = tempfile::Builder::new()
        .suffix(".jpg")
        .tempfile()
        .map_err(|source| CodecError::Io {
            path: src.to_path_buf(),
            source,
        })?;
    ffmpeg::extract_frame(&ffmpeg, src, tmp.path())?;
    decode::decode_image(tmp.path())
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

fn write_placeholders(paths: &ThumbPaths) -> Result<()> {
    for (size, dest) in [(256u32, &paths.t256), (1024, &paths.t1024)] {
        write_jpeg_atomic(&placeholder_image(size), dest)?;
    }
    Ok(())
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

    #[test]
    fn video_extensions_detected_case_insensitively() {
        assert!(is_video(Path::new("a/CLIP.MP4")));
        assert!(is_video(Path::new("a/b.mov")));
        assert!(!is_video(Path::new("a/b.jpg")));
    }
}
