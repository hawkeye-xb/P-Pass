//! Media codec — decode (JPEG/PNG via image-rs, HEIC via libheif, video
//! first-frame via ffmpeg) and the thumbnail pipeline (T-013).
//!
//! 契约: `make_thumbs` never panics and never errors — a file we cannot
//! decode yields the built-in placeholder (caller records thumb_state=2).

use std::path::PathBuf;

mod decode;
mod ffmpeg;
mod pool;
mod thumb;

pub use decode::decode_image;
pub use ffmpeg::{extract_frame, ffmpeg_path};
pub use pool::ThumbPool;
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
}

pub type Result<T> = std::result::Result<T, CodecError>;
