//! Media codec — decode (JPEG/PNG via image-rs, HEIC via libheif, video
//! first-frame via ffmpeg) and the thumbnail pipeline (T-013).
//!
//! 契约: `make_thumbs` never panics and never errors — a file we cannot
//! decode yields a `Placeholder` outcome and writes nothing at the final
//! thumb paths (DESK-35 #441); the caller serves `placeholder_jpeg` from
//! memory and records thumb_state=2.

// DESK-33 (#325)：clippy.toml 禁止产品代码直接 `Command::new`；单元测试
// 里的子进程（拉起测试二进制自身等）不面向用户，统一放行。
#![cfg_attr(test, allow(clippy::disallowed_methods))]

use std::path::PathBuf;

mod ffmpeg;
mod pool;
mod quicklook;
// 静态图解码：交给独立的解码子进程（协议见 decode-worker，隔离拉起在 platform）。
mod sandbox;
mod thumb;

pub use ffmpeg::{extract_frame, ffmpeg_path};
pub use pool::{ThumbGenerator, ThumbPool};
pub use sandbox::{decode_image, decode_image_within, DECODE_MAX_EDGE};
pub use thumb::{
    make_thumbs, placeholder_jpeg, thumb_paths, ThumbOutcome, ThumbPaths, ThumbResult,
    JPEG_QUALITY, THUMB_SIZES,
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

    /// 解码子进程不可用（找不到、起不来）：本机的系统性问题，不是这个文件的错。
    /// 调用方据此不把资产标成「永久失败」，留给重试。
    #[error("decode sandbox unavailable: {0}")]
    SandboxUnavailable(String),
}

pub type Result<T> = std::result::Result<T, CodecError>;
