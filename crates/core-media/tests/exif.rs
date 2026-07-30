//! T-013 acceptance for the EXIF reader: full field set, and hostile
//! input degrades to defaults instead of erroring.

use std::fs;

use core_media::{read_meta, MediaMeta};

/// Hand-built JPEG: SOI + APP1(EXIF TIFF, little-endian) + EOI.
/// IFD0 carries Orientation + the Exif sub-IFD pointer; the sub-IFD
/// carries DateTimeOriginal and pixel dimensions.
fn jpeg_full_exif(datetime: &str, orientation: u16, w: u32, h: u32) -> Vec<u8> {
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

    // Exif sub-IFD @38: 3 entries, ends at 38 + 2 + 36 + 4 = 80.
    t.extend_from_slice(&3u16.to_le_bytes());
    // DateTimeOriginal (0x9003, ASCII×20) → data at 80.
    t.extend_from_slice(&0x9003u16.to_le_bytes());
    t.extend_from_slice(&2u16.to_le_bytes());
    t.extend_from_slice(&20u32.to_le_bytes());
    t.extend_from_slice(&80u32.to_le_bytes());
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

    t.extend_from_slice(datetime.as_bytes()); // @80
    t.push(0);
    assert_eq!(t.len(), 100);

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
