//! 「什么算照片」的唯一口径（#1044 B3）。
//!
//! 照片库目录 `originals/` 有四条路在问同一个问题：目录监听收不收、
//! adopt/rebuild 补不补行、入库记什么 MIME、缩略图按图还是按视频解。
//! 过去四处各写一份扩展名表，互相矛盾（adopt 收下 `Thumbs.db`、`.avi`
//! 经重建入库变成 octet-stream 再被当成照片……）。现在全部问这里。
//!
//! 判据：扩展名经成熟的扩展名→MIME 表（`mime_guess`）查出的首选类型，
//! 主类型为 `image` 或 `video` 才算媒体，矢量图与图标除外
//! （[`NON_MEDIA_IMAGE_TYPES`]）；其余（含查不到、无扩展名）一律不是。
//! 不手维护格式清单。
//!
//! 不在这里判的：Flow 路径——手机端已按系统的图片/视频类别过滤，
//! MIME 由手机给出，桌面不复检。

use std::path::Path;

/// 媒体大类。`None`（见 [`media_kind`]）= 不是媒体，不入库。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Image,
    Video,
}

/// 文件路径 → 媒体大类；不是媒体返回 `None`。只看扩展名（大小写不敏感），
/// 不读文件内容。
pub fn media_kind(path: &Path) -> Option<MediaKind> {
    let mime = media_type_for(path)?;
    if mime.starts_with("image/") {
        Some(MediaKind::Image)
    } else {
        Some(MediaKind::Video)
    }
}

/// 主类型是 `image` 但不算媒体的 MIME（#1044 追加拍板）：矢量图与图标——
/// 不是照片，缩略图也解不出（照片墙上永远是灰块）。按 MIME 排除而不是按
/// 扩展名，`.svg`/`.svgz`/`.ico` 都经同一张表落到这里。
pub const NON_MEDIA_IMAGE_TYPES: &[&str] =
    &["image/svg+xml", "image/x-icon", "image/vnd.microsoft.icon"];

/// 文件路径 → 入库记录的 MIME（`asset.media_type`）；不是媒体返回 `None`。
pub fn media_type_for(path: &Path) -> Option<&'static str> {
    let ext = path.extension()?.to_str()?;
    let mime = mime_guess::from_ext(ext).first_raw()?;
    ((mime.starts_with("image/") || mime.starts_with("video/"))
        && !NON_MEDIA_IMAGE_TYPES.contains(&mime))
    .then_some(mime)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kind(name: &str) -> Option<MediaKind> {
        media_kind(Path::new(name))
    }

    #[test]
    fn photos_videos_and_raw_are_media() {
        for n in [
            "a.jpg", "B.JPG", "c.jpeg", "d.png", "e.heic", "f.heif", "g.gif", "h.webp", "i.bmp",
            "j.dng", "k.cr2", "l.arw", "m.nef",
        ] {
            assert_eq!(kind(n), Some(MediaKind::Image), "{n}");
        }
        for n in ["a.mp4", "b.MOV", "c.m4v", "d.avi", "e.mkv", "f.3gp"] {
            assert_eq!(kind(n), Some(MediaKind::Video), "{n}");
        }
    }

    #[test]
    fn system_junk_and_documents_are_not_media() {
        for n in [
            "Thumbs.db",
            "desktop.ini",
            "notes.txt",
            "archive.zip",
            "noext",
            "jpg",
            "a.xyz",
        ] {
            assert_eq!(kind(n), None, "{n}");
        }
    }

    /// #1044 追加拍板：矢量图与图标不算媒体（不是照片，缩略图也解不出）；
    /// 其余 image/*、video/*（含 tiff/avif/jxl/各家 RAW）照收。
    #[test]
    fn vector_images_and_icons_are_not_media_but_other_images_are() {
        for n in [
            "logo.svg",
            "logo.SVG",
            "logo.svgz",
            "favicon.ico",
            "favicon.ICO",
        ] {
            assert_eq!(kind(n), None, "{n}");
            assert_eq!(media_type_for(Path::new(n)), None, "{n}");
        }
        for n in [
            "scan.tif",
            "scan.tiff",
            "a.avif",
            "a.jxl",
            "a.raf",
            "a.orf",
            "a.rw2",
            "a.dng",
        ] {
            assert_eq!(kind(n), Some(MediaKind::Image), "{n}");
        }
        assert_eq!(kind("clip.webm"), Some(MediaKind::Video));
    }

    #[test]
    fn mime_comes_from_the_shared_table() {
        assert_eq!(media_type_for(Path::new("a/B.JPG")), Some("image/jpeg"));
        assert_eq!(media_type_for(Path::new("a/b.heic")), Some("image/heic"));
        assert_eq!(
            media_type_for(Path::new("a/b.mov")),
            Some("video/quicktime")
        );
        assert_eq!(
            media_type_for(Path::new("a/b.avi")),
            Some("video/x-msvideo")
        );
        assert_eq!(media_type_for(Path::new("a/noext")), None);
    }
}
