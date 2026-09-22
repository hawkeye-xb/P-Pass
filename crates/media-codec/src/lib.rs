//! Media codec — decode (JPEG/PNG via image-rs, HEIC via libheif, video
//! first-frame via ffmpeg) and the thumbnail pipeline (T-013).
//!
//! 契约: `make_thumbs` never panics and never errors — a file we cannot
//! decode yields the built-in placeholder (caller records thumb_state=2).

use std::path::PathBuf;

mod decode;
mod ffmpeg;
mod pool;
mod quicklook;
// DESK-16 (#165)：同一条回退链的 Windows 那半（薄封装，零 cfg）。
mod system_thumb;
mod thumb;

pub use decode::decode_image;
pub use ffmpeg::{extract_frame, ffmpeg_path};
// DESK-16 (#165)：与 `ffmpeg_path` 同样公开，理由相同 —— 回退链的集成测试
// 必须能把「本机有没有这个能力」写成显式前提，而不是靠条件编译分叉。
pub use pool::ThumbPool;
pub use system_thumb::capable as system_thumbnail_capable;
pub use thumb::{
    make_thumbs, placeholder_jpeg, thumb_paths, ThumbOutcome, ThumbPaths, ThumbResult, THUMB_SIZES,
};

/// Codec-layer errors. Like core-index, every I/O failure names its path —
/// these become human-readable diagnostics (msg_key 体系).
#[derive(Debug, thiserror::Error)]
pub enum CodecError {
    #[error("file {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("decode {path}: {msg}")]
    Decode { path: PathBuf, msg: String },

    #[error("ffmpeg not found (set PPF_FFMPEG, or run tools/fetch-ffmpeg.sh)")]
    FfmpegMissing,

    #[error("ffmpeg on {path}: {msg}")]
    Ffmpeg { path: PathBuf, msg: String },

    // MOB-74 B: the macOS system thumbnailer (Quick Look) — the fallback
    // when no ffmpeg binary is discoverable. Distinct from Ffmpeg so the
    // diagnostic says which tool actually failed.
    #[error("quicklook on {path}: {msg}")]
    QuickLook { path: PathBuf, msg: String },

    // DESK-16 (#165): the Windows system thumbnailer (Shell
    // IShellItemImageFactory) — the other half of the same fallback chain.
    // Separate variant for the same reason QuickLook is separate: the
    // diagnostic must say which tool actually failed, not blame ffmpeg for
    // something ffmpeg was never asked to do.
    #[error("shell thumbnail on {path}: {msg}")]
    ShellThumbnail { path: PathBuf, msg: String },
}

pub type Result<T> = std::result::Result<T, CodecError>;
