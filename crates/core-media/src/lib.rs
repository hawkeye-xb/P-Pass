//! Core media — EXIF metadata for the photo domain (T-013).
//!
//! Pure parsing, no pixels: decoding and thumbnailing live in
//! `media-codec`. `read_meta` is best-effort by contract — media files
//! from the wild are hostile input, and a photo with broken EXIF is
//! still a photo (missing fields, never errors).

mod exif_meta;

pub use exif_meta::{read_meta, MediaMeta};

// PROBE (CI-07 #189 negative control) — 故意留一个 unused 变量，
// 用来验证「改 crates/** 的 PR 现在真的会触发 Rust lane 且 clippy 会红」。
// 这个分支永不合入，观察完即关闭。
pub fn ci07_negative_control_probe() -> u8 {
    let deliberately_unused = 42u8;
    7
}
