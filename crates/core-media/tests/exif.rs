//! T-013 acceptance for the EXIF reader: full field set, and hostile
//! input degrades to defaults instead of erroring.

use std::fs;

use core_media::{read_meta, MediaMeta};

/// Hand-built JPEG: SOI + APP1(EXIF TIFF, little-endian) + EOI.
/// IFD0 carries Orientation + the Exif sub-IFD pointer; the sub-IFD
/// carries DateTimeOriginal and pixel dimensions.
fn jpeg_full_exif(datetime: &str, orientation: u16, w: u32, h: u32) -> Vec<u8> {
    jpeg_with_offset(datetime, None, orientation, w, h)
}

/// Same shape as [`jpeg_full_exif`], plus an optional `OffsetTimeOriginal`
/// (ASCII "+HH:MM"/"-HH:MM", always 7 bytes incl. NUL) in the Exif sub-IFD.
fn jpeg_with_offset(
    datetime: &str,
    offset: Option<&str>,
    orientation: u16,
    w: u32,
    h: u32,
) -> Vec<u8> {
    assert_eq!(datetime.len(), 19, "YYYY:MM:DD HH:MM:SS");
    let mut t = Vec::new();
    t.extend_from_slice(b"II*\0");
    t.extend_from_slice(&8u32.to_le_bytes()); // IFD0 offset

    // IFD0 @8: 2 entries, ends at 8 + 2 + 24 + 4 = 38.
    t.extend_from_slice(&2u16.to_le_bytes());
    // Orientation (0x0112, SHORT×1) — value lives inside the entry.
    t.extend_from_slice(&0x0112u16.to_le_bytes());
    t.extend_from_slice(&3u16.to_le_bytes());
    t.extend_from_slice(&1u32.to_le_bytes());
    t.extend_from_slice(&orientation.to_le_bytes());
    t.extend_from_slice(&0u16.to_le_bytes());
    // Exif sub-IFD pointer (0x8769, LONG×1) → offset 38.
    t.extend_from_slice(&0x8769u16.to_le_bytes());
    t.extend_from_slice(&4u16.to_le_bytes());
    t.extend_from_slice(&1u32.to_le_bytes());
    t.extend_from_slice(&38u32.to_le_bytes());
    t.extend_from_slice(&0u32.to_le_bytes()); // no next IFD

    let entry_count: u16 = if offset.is_some() { 4 } else { 3 };
    let sub_ifd_len = 2 + u32::from(entry_count) * 12 + 4;
    let datetime_off = 38 + sub_ifd_len;
    let offset_off = datetime_off + 20;

    // Exif sub-IFD @38.
    t.extend_from_slice(&entry_count.to_le_bytes());
    // DateTimeOriginal (0x9003, ASCII×20) → data at datetime_off.
    t.extend_from_slice(&0x9003u16.to_le_bytes());
    t.extend_from_slice(&2u16.to_le_bytes());
    t.extend_from_slice(&20u32.to_le_bytes());
    t.extend_from_slice(&datetime_off.to_le_bytes());
    if let Some(off) = offset {
        assert_eq!(off.len(), 6, "\"+HH:MM\"/\"-HH:MM\"");
        // OffsetTimeOriginal (0x9011, ASCII×7) → data at offset_off.
        // Must sort between DateTimeOriginal (0x9003) and PixelXDimension
        // (0xA002) — TIFF requires ascending tag order within an IFD.
        t.extend_from_slice(&0x9011u16.to_le_bytes());
        t.extend_from_slice(&2u16.to_le_bytes());
        t.extend_from_slice(&7u32.to_le_bytes());
        t.extend_from_slice(&offset_off.to_le_bytes());
    }
    // PixelXDimension (0xA002, LONG×1).
    t.extend_from_slice(&0xA002u16.to_le_bytes());
    t.extend_from_slice(&4u16.to_le_bytes());
    t.extend_from_slice(&1u32.to_le_bytes());
    t.extend_from_slice(&w.to_le_bytes());
    // PixelYDimension (0xA003, LONG×1).
    t.extend_from_slice(&0xA003u16.to_le_bytes());
    t.extend_from_slice(&4u16.to_le_bytes());
    t.extend_from_slice(&1u32.to_le_bytes());
    t.extend_from_slice(&h.to_le_bytes());
    t.extend_from_slice(&0u32.to_le_bytes()); // no next IFD

    t.extend_from_slice(datetime.as_bytes()); // @datetime_off
    t.push(0);
    if let Some(off) = offset {
        t.extend_from_slice(off.as_bytes()); // @offset_off
        t.push(0);
    }

    let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE1];
    jpeg.extend_from_slice(&((2 + 6 + t.len()) as u16).to_be_bytes());
    jpeg.extend_from_slice(b"Exif\0\0");
    jpeg.extend_from_slice(&t);
    jpeg.extend_from_slice(&[0xFF, 0xD9]);
    jpeg
}

#[test]
fn full_exif_reads_every_field() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("full.jpg");
    fs::write(&p, jpeg_full_exif("2025:12:31 23:59:58", 6, 4032, 3024)).unwrap();

    let meta = read_meta(&p);
    // 2025-12-31T23:59:58Z = 1_767_225_598 s.
    assert_eq!(meta.taken_at_ms, Some(1_767_225_598_000));
    assert_eq!(meta.orientation, Some(6));
    assert_eq!(meta.width, Some(4032));
    assert_eq!(meta.height, Some(3024));
}

#[test]
fn garbage_and_missing_files_degrade_to_defaults() {
    let dir = tempfile::tempdir().unwrap();
    let garbage = dir.path().join("garbage.jpg");
    fs::write(&garbage, b"not exif in any way").unwrap();
    assert_eq!(read_meta(&garbage), MediaMeta::default());
    assert_eq!(
        read_meta(&dir.path().join("no-such-file.jpg")),
        MediaMeta::default()
    );
}

#[test]
fn out_of_range_orientation_is_dropped() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("weird.jpg");
    fs::write(&p, jpeg_full_exif("2024:01:01 00:00:00", 99, 10, 10)).unwrap();
    assert_eq!(
        read_meta(&p).orientation,
        None,
        "9+ is not a valid EXIF orientation"
    );
}

/// 2026-09-15 用户实测复现：三星/华为等真机的 EXIF 都带 `OffsetTimeOriginal`
/// （例如 `"+08:00"`），墙钟时间不是 UTC。不按偏移换算，UTC+8 拍摄的照片
/// 会在时间线上被灌水 8 小时，排到明明更晚才到达/拍摄的视频（无 EXIF，
/// `taken_at` 走真实 UTC 的 hint/mtime）前面。
#[test]
fn positive_offset_shifts_taken_at_to_real_utc() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("offset_plus8.jpg");
    // 墙钟 2026-09-15 15:52:36 +08:00 == 2026-09-15 07:52:36 UTC.
    fs::write(
        &p,
        jpeg_with_offset("2026:09:15 15:52:36", Some("+08:00"), 1, 10, 10),
    )
    .unwrap();
    let meta = read_meta(&p);
    assert_eq!(meta.taken_at_ms, Some(1_789_458_756_000));
}

#[test]
fn negative_offset_shifts_taken_at_to_real_utc() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("offset_minus5.jpg");
    // 墙钟 2026-01-01 00:00:00 -05:00 == 2026-01-01 05:00:00 UTC.
    fs::write(
        &p,
        jpeg_with_offset("2026:01:01 00:00:00", Some("-05:00"), 1, 10, 10),
    )
    .unwrap();
    let meta = read_meta(&p);
    assert_eq!(meta.taken_at_ms, Some(1_767_243_600_000));
}

/// 没有偏移标签的老素材必须保持 T-011 的历史行为（裸值当 UTC）——
/// 这条测试就是 `full_exif_reads_every_field` 的意图，这里再显式断言
/// 一次「没有 offset 字段 → 不应用任何偏移」，防止未来重构悄悄改变
/// 这条兜底路径。
#[test]
fn missing_offset_falls_back_to_naive_utc() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("no_offset.jpg");
    fs::write(&p, jpeg_with_offset("2026:01:01 00:00:00", None, 1, 10, 10)).unwrap();
    let meta = read_meta(&p);
    // 裸值当 UTC：2026-01-01T00:00:00Z.
    assert_eq!(meta.taken_at_ms, Some(1_767_225_600_000));
}
