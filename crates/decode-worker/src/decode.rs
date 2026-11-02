//! 静态图解码：HEIC/HEIF 走 libheif，其余走 image-rs。输入是内存字节
//! （子进程里没有文件系统可读），输出是已摆正方向的像素。

use std::io::Cursor;

use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits};
use libheif_rs::{ColorSpace, HeifContext, LibHeif, RgbChroma};

/// 单张静态图的像素上限（宽 × 高）。覆盖 1 亿像素级传感器与拼接全景；
/// 再大的给占位图（原图照常存储）。按头部声明的尺寸在分配像素缓冲前检查。
pub const MAX_IMAGE_PIXELS: u64 = 120_000_000;

/// image-rs 的分配上限：`MAX_IMAGE_PIXELS` 的 RGBA8（480 MB）放得下。
pub const MAX_DECODE_ALLOC: u64 = 512 * 1024 * 1024;

/// image-rs 单边上限；JPEG 自身的格式上限。
const MAX_IMAGE_EDGE: u32 = 65_535;

/// 解码失败的两类：内容解不开 / 超限被拒。
#[derive(Debug)]
pub enum DecodeError {
    Failed(String),
    Rejected(String),
}

fn failed(e: impl ToString) -> DecodeError {
    DecodeError::Failed(e.to_string())
}

/// 解码为方向已摆正的像素。
pub fn decode_bytes(bytes: &[u8], ext: &str) -> Result<DynamicImage, DecodeError> {
    match ext {
        // libheif 自己应用容器里的旋转/镜像，HEIC 出来已经是正的。
        "heic" | "heif" => decode_heic(bytes),
        _ => decode_with_limits(bytes, ext),
    }
}

fn check_pixels(w: u32, h: u32) -> Result<(), DecodeError> {
    let pixels = u64::from(w) * u64::from(h);
    if pixels > MAX_IMAGE_PIXELS {
        return Err(DecodeError::Rejected(format!(
            "{w}x{h} = {pixels} pixels exceeds the {MAX_IMAGE_PIXELS}-pixel limit"
        )));
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

/// 带显式上限的 image-rs 解码：先解析头部，声明的尺寸通过检查才分配像素缓冲。
fn decode_with_limits(bytes: &[u8], ext: &str) -> Result<DynamicImage, DecodeError> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(failed)?;
    if reader.format().is_none() {
        if let Some(f) = ImageFormat::from_extension(ext) {
            reader.set_format(f);
        }
    }
    reader.limits(image_limits());
    let mut decoder = reader.into_decoder().map_err(failed)?;
    let (w, h) = decoder.dimensions();
    check_pixels(w, h)?;
    if decoder.total_bytes() > MAX_DECODE_ALLOC {
        return Err(DecodeError::Rejected(format!(
            "{w}x{h} needs {} bytes, over the {MAX_DECODE_ALLOC}-byte limit",
            decoder.total_bytes()
        )));
    }
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(decoder).map_err(failed)?;
    img.apply_orientation(orientation);
    Ok(img)
}

fn decode_heic(bytes: &[u8]) -> Result<DynamicImage, DecodeError> {
    let lib = LibHeif::new();
    let ctx = HeifContext::read_from_bytes(bytes).map_err(failed)?;
    let handle = ctx.primary_image_handle().map_err(failed)?;
    // 尺寸来自容器头部；libheif 分配解码平面之前先拒。
    check_pixels(handle.width(), handle.height())?;
    let img = lib
        .decode(&handle, ColorSpace::Rgb(RgbChroma::Rgb), None)
        .map_err(failed)?;

    let planes = img.planes();
    let plane = planes
        .interleaved
        .ok_or_else(|| failed("no interleaved RGB plane"))?;
    let (w, h, stride) = (plane.width, plane.height, plane.stride);

    // stride 可能大于 width*3：逐行拷进紧凑缓冲。
    let mut rgb = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h as usize {
        let row = plane
            .data
            .get(y * stride..y * stride + (w as usize) * 3)
            .ok_or_else(|| failed("plane shorter than its declared size"))?;
        rgb.extend_from_slice(row);
    }
    let buf = image::RgbImage::from_raw(w, h, rgb).ok_or_else(|| failed("plane size mismatch"))?;
    Ok(DynamicImage::ImageRgb8(buf))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bmp_header(w: u32, h: u32) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(b"BM");
        b.extend_from_slice(&0u32.to_le_bytes());
        b.extend_from_slice(&0u32.to_le_bytes());
        b.extend_from_slice(&54u32.to_le_bytes());
        b.extend_from_slice(&40u32.to_le_bytes());
        b.extend_from_slice(&(w as i32).to_le_bytes());
        b.extend_from_slice(&(h as i32).to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&24u16.to_le_bytes());
        b.extend_from_slice(&[0u8; 24]);
        b
    }

    fn msg(e: DecodeError) -> String {
        match e {
            DecodeError::Failed(m) | DecodeError::Rejected(m) => m,
        }
    }

    fn tiny_heic() -> Vec<u8> {
        std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/tiny.heic")).unwrap()
    }

    #[test]
    fn pixel_limit_boundary() {
        assert!(check_pixels(10_000, 12_000).is_ok());
        assert!(check_pixels(10_000, 12_001).is_err());
        assert!(check_pixels(u32::MAX, u32::MAX).is_err());
    }

    #[test]
    fn oversized_image_is_rejected_from_its_header() {
        let err = decode_bytes(&bmp_header(12_000, 11_000), "bmp").unwrap_err();
        assert!(matches!(&err, DecodeError::Rejected(m) if m.contains("pixel limit")));
        // 对照：同样的头在上限内，只会因缺像素数据失败。
        let err = decode_bytes(&bmp_header(64, 48), "bmp").unwrap_err();
        assert!(matches!(err, DecodeError::Failed(_)));
    }

    #[test]
    fn edge_past_limit_is_refused_by_image_rs() {
        let err = decode_bytes(&bmp_header(MAX_IMAGE_EDGE + 1, 1), "bmp").unwrap_err();
        assert!(!msg(err).contains("pixel limit"));
    }

    #[test]
    fn oversized_heic_is_rejected_before_decode() {
        let mut bytes = tiny_heic();
        let at = bytes.windows(4).position(|w| w == b"ispe").unwrap();
        bytes[at + 8..at + 12].copy_from_slice(&12_000u32.to_be_bytes());
        bytes[at + 12..at + 16].copy_from_slice(&11_000u32.to_be_bytes());
        let err = decode_bytes(&bytes, "heic").unwrap_err();
        assert!(msg(err).contains("pixel limit"));
        // 对照：原夹具能解。
        assert_eq!(decode_bytes(&tiny_heic(), "heic").unwrap().width(), 64);
    }

    /// 2×1 的 JPEG（左红右蓝），在 SOI 后插一段 EXIF 方向 = `orientation`。
    fn jpeg_with_orientation(orientation: u16) -> Vec<u8> {
        let mut buf = image::RgbImage::new(2, 1);
        buf.put_pixel(0, 0, image::Rgb([255, 0, 0]));
        buf.put_pixel(1, 0, image::Rgb([0, 0, 255]));
        let mut jpg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpg, 100)
            .encode_image(&buf)
            .unwrap();
        let mut exif = b"Exif\0\0MM\0\x2a\0\0\0\x08".to_vec();
        exif.extend_from_slice(&1u16.to_be_bytes()); // 1 个 IFD 条目
        exif.extend_from_slice(&0x0112u16.to_be_bytes()); // Orientation
        exif.extend_from_slice(&3u16.to_be_bytes()); // SHORT
        exif.extend_from_slice(&1u32.to_be_bytes());
        exif.extend_from_slice(&orientation.to_be_bytes());
        exif.extend_from_slice(&[0, 0]);
        exif.extend_from_slice(&0u32.to_be_bytes()); // 无下一个 IFD
        let mut out = jpg[..2].to_vec();
        out.extend_from_slice(&[0xFF, 0xE1]);
        out.extend_from_slice(&((exif.len() + 2) as u16).to_be_bytes());
        out.extend_from_slice(&exif);
        out.extend_from_slice(&jpg[2..]);
        out
    }

    #[test]
    fn exif_orientation_is_applied() {
        let img = decode_bytes(&jpeg_with_orientation(6), "jpg").unwrap();
        // 方向 6：顺时针转 90°，2×1 → 1×2，红在上。
        assert_eq!((img.width(), img.height()), (1, 2));
        let p = img.to_rgb8().get_pixel(0, 0).0;
        assert!(p[0] > 200 && p[2] < 60, "{p:?}");
        let img = decode_bytes(&jpeg_with_orientation(1), "jpg").unwrap();
        assert_eq!((img.width(), img.height()), (2, 1));
    }
}
