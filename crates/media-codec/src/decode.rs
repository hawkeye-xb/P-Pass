//! Still-image decoding: HEIC/HEIF through libheif, everything else
//! through image-rs. EXIF orientation is applied here so callers always
//! receive upright pixels.

use std::path::Path;

use image::DynamicImage;
use libheif_rs::{ColorSpace, HeifContext, LibHeif, RgbChroma};

use crate::{CodecError, Result};

/// Decode a still image to upright RGB pixels.
pub fn decode_image(path: &Path) -> Result<DynamicImage> {
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        // libheif applies the container's rotation/mirror transforms
        // itself, so HEIC comes out upright already.
        "heic" | "heif" => decode_heic(path),
        _ => {
            let img = image::open(path).map_err(|e| CodecError::Decode {
                path: path.to_path_buf(),
                msg: e.to_string(),
            })?;
            Ok(apply_orientation(
                img,
                core_media::read_meta(path).orientation.unwrap_or(1),
            ))
        }
    }
}

fn decode_heic(path: &Path) -> Result<DynamicImage> {
    let decode_err = |msg: String| CodecError::Decode {
        path: path.to_path_buf(),
        msg,
    };
    let lib = LibHeif::new();
    let ctx = HeifContext::read_from_file(&path.to_string_lossy())
        .map_err(|e| decode_err(e.to_string()))?;
    let handle = ctx
        .primary_image_handle()
        .map_err(|e| decode_err(e.to_string()))?;
    let img = lib
        .decode(&handle, ColorSpace::Rgb(RgbChroma::Rgb), None)
        .map_err(|e| decode_err(e.to_string()))?;

    let planes = img.planes();
    let plane = planes
        .interleaved
        .ok_or_else(|| decode_err("no interleaved RGB plane".into()))?;
    let (w, h, stride) = (plane.width, plane.height, plane.stride);

    // The stride may exceed width*3 — copy row by row into a tight buffer.
    let mut rgb = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h as usize {
        let row = &plane.data[y * stride..y * stride + (w as usize) * 3];
        rgb.extend_from_slice(row);
    }
    let buf = image::RgbImage::from_raw(w, h, rgb)
        .ok_or_else(|| decode_err("plane size mismatch".into()))?;
    Ok(DynamicImage::ImageRgb8(buf))
}

/// Map EXIF orientation 1–8 onto rotate/flip operations.
fn apply_orientation(img: DynamicImage, orientation: u16) -> DynamicImage {
    match orientation {
        2 => img.fliph(),
        3 => img.rotate180(),
        4 => img.flipv(),
        5 => img.rotate90().fliph(),
        6 => img.rotate90(),
        7 => img.rotate270().fliph(),
        8 => img.rotate270(),
        _ => img,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orientation_6_rotates_90_clockwise() {
        // 2×1 image: red then blue. Orientation 6 → 1×2, red on top.
        let mut buf = image::RgbImage::new(2, 1);
        buf.put_pixel(0, 0, image::Rgb([255, 0, 0]));
        buf.put_pixel(1, 0, image::Rgb([0, 0, 255]));
        let out = apply_orientation(DynamicImage::ImageRgb8(buf), 6);
        assert_eq!((out.width(), out.height()), (1, 2));
        assert_eq!(out.to_rgb8().get_pixel(0, 0), &image::Rgb([255, 0, 0]));
    }

    #[test]
    fn unknown_orientation_is_identity() {
        let buf = image::RgbImage::new(3, 2);
        let out = apply_orientation(DynamicImage::ImageRgb8(buf), 0);
        assert_eq!((out.width(), out.height()), (3, 2));
    }
}
