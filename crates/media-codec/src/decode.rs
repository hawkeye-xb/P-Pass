//! Still-image decoding: HEIC/HEIF through libheif, everything else
//! through image-rs. EXIF orientation is applied here so callers always
//! receive upright pixels.

use std::path::Path;

use image::{DynamicImage, ImageDecoder, ImageReader, Limits};
use libheif_rs::{ColorSpace, HeifContext, LibHeif, RgbChroma};

use crate::{CodecError, Result};

/// Largest still image we decode, in pixels (width × height). Covers
/// 100 MP-class phone sensors and stitched panoramas; anything larger gets
/// the placeholder thumb (the original is still stored untouched). Checked
/// against the header's declared size, before any pixel buffer exists.
pub const MAX_IMAGE_PIXELS: u64 = 120_000_000;

/// image-rs allocation ceiling: RGBA8 at [`MAX_IMAGE_PIXELS`] (480 MB) fits.
pub const MAX_DECODE_ALLOC: u64 = 512 * 1024 * 1024;

/// Per-edge ceiling for image-rs; JPEG's own format limit.
const MAX_IMAGE_EDGE: u32 = 65_535;

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
            let img = decode_with_limits(path)?;
            Ok(apply_orientation(
                img,
                core_media::read_meta(path).orientation.unwrap_or(1),
            ))
        }
    }
}

/// `Err(msg)` when `w × h` exceeds [`MAX_IMAGE_PIXELS`].
fn check_pixels(w: u32, h: u32) -> std::result::Result<(), String> {
    let pixels = u64::from(w) * u64::from(h);
    if pixels > MAX_IMAGE_PIXELS {
        return Err(format!(
            "{w}x{h} = {pixels} pixels exceeds the {MAX_IMAGE_PIXELS}-pixel limit"
        ));
    }
    Ok(())
}

fn image_limits() -> Limits {
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_IMAGE_EDGE);
    limits.max_image_height = Some(MAX_IMAGE_EDGE);
    limits.max_alloc = Some(MAX_DECODE_ALLOC);
    limits
}

/// image-rs decode with explicit limits: the header is parsed first and
/// its declared size checked before the pixel buffer is allocated.
fn decode_with_limits(path: &Path) -> Result<DynamicImage> {
    let decode_err = |msg: String| CodecError::Decode {
        path: path.to_path_buf(),
        msg,
    };
    let mut reader = ImageReader::open(path).map_err(|source| CodecError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    reader.limits(image_limits());
    let decoder = reader
        .into_decoder()
        .map_err(|e| decode_err(e.to_string()))?;
    let (w, h) = decoder.dimensions();
    check_pixels(w, h).map_err(decode_err)?;
    if decoder.total_bytes() > MAX_DECODE_ALLOC {
        return Err(decode_err(format!(
            "{w}x{h} needs {} bytes, over the {MAX_DECODE_ALLOC}-byte limit",
            decoder.total_bytes()
        )));
    }
    DynamicImage::from_decoder(decoder).map_err(|e| decode_err(e.to_string()))
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
    // The handle's size comes from the container header; refuse before
    // libheif allocates the decoded planes.
    check_pixels(handle.width(), handle.height()).map_err(decode_err)?;
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

    /// A BMP header declaring `w × h` at 24 bpp, with no pixel data: enough
    /// for the decoder to report dimensions, nothing to actually decode.
    fn bmp_header(w: u32, h: u32) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(b"BM");
        b.extend_from_slice(&0u32.to_le_bytes()); // file size (unchecked)
        b.extend_from_slice(&0u32.to_le_bytes()); // reserved
        b.extend_from_slice(&54u32.to_le_bytes()); // pixel data offset
        b.extend_from_slice(&40u32.to_le_bytes()); // BITMAPINFOHEADER
        b.extend_from_slice(&(w as i32).to_le_bytes());
        b.extend_from_slice(&(h as i32).to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes()); // planes
        b.extend_from_slice(&24u16.to_le_bytes()); // bpp
        b.extend_from_slice(&[0u8; 24]); // BI_RGB, sizes, palette counts
        b
    }

    #[test]
    fn pixel_limit_boundary() {
        assert!(check_pixels(10_000, 12_000).is_ok(), "exactly the limit");
        assert!(check_pixels(10_000, 12_001).is_err());
        assert!(check_pixels(u32::MAX, u32::MAX).is_err(), "no overflow");
    }

    #[test]
    fn oversized_image_is_rejected_from_its_header() {
        // 12000 × 11000 = 132 MP: within the per-edge and allocation
        // limits (RGB8 ≈ 396 MB), so only the pixel limit can refuse it.
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("huge.bmp");
        std::fs::write(&p, bmp_header(12_000, 11_000)).unwrap();
        let err = decode_image(&p).unwrap_err().to_string();
        assert!(err.contains("pixel limit"), "{err}");

        // Counter-proof: the same header under the limit gets past the
        // size check and fails only for its missing pixel data.
        std::fs::write(&p, bmp_header(64, 48)).unwrap();
        let err = decode_image(&p).unwrap_err().to_string();
        assert!(!err.contains("pixel limit"), "{err}");
    }

    #[test]
    fn image_rs_limits_cap_edge_and_allocation() {
        let l = image_limits();
        assert_eq!(l.max_image_width, Some(MAX_IMAGE_EDGE));
        assert_eq!(l.max_image_height, Some(MAX_IMAGE_EDGE));
        assert_eq!(l.max_alloc, Some(MAX_DECODE_ALLOC));
        // An edge past the limit is refused by image-rs itself.
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("wide.bmp");
        std::fs::write(&p, bmp_header(MAX_IMAGE_EDGE + 1, 1)).unwrap();
        let err = decode_image(&p).unwrap_err().to_string();
        assert!(
            !err.contains("pixel limit"),
            "image-rs must refuse first: {err}"
        );
    }

    fn tiny_heic() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/tiny.heic")
    }

    #[test]
    fn oversized_heic_is_rejected_before_decode() {
        // tiny.heic (64 × 48) with its `ispe` box rewritten to declare
        // 12000 × 11000.
        let mut bytes = std::fs::read(tiny_heic()).unwrap();
        let at = bytes.windows(4).position(|w| w == b"ispe").unwrap();
        bytes[at + 8..at + 12].copy_from_slice(&12_000u32.to_be_bytes());
        bytes[at + 12..at + 16].copy_from_slice(&11_000u32.to_be_bytes());
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("huge.heic");
        std::fs::write(&p, &bytes).unwrap();
        let err = decode_image(&p).unwrap_err().to_string();
        assert!(err.contains("pixel limit"), "{err}");
        // Counter-proof: the unmodified fixture decodes.
        assert_eq!(decode_image(&tiny_heic()).unwrap().width(), 64);
    }

    #[test]
    fn unknown_orientation_is_identity() {
        let buf = image::RgbImage::new(3, 2);
        let out = apply_orientation(DynamicImage::ImageRgb8(buf), 0);
        assert_eq!((out.width(), out.height()), (3, 2));
    }
}
