//! Core media — EXIF metadata for the photo domain (T-013).
//!
//! Pure parsing, no pixels: decoding and thumbnailing live in
//! `media-codec`. `read_meta` is best-effort by contract — media files
//! from the wild are hostile input, and a photo with broken EXIF is
//! still a photo (missing fields, never errors).

mod exif_meta;

pub use exif_meta::{read_meta, MediaMeta};
