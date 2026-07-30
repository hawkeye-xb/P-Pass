//! Shared test fixtures for core-index integration tests.

/// Minimal-but-valid JPEG carrying one EXIF DateTimeOriginal field.
/// Layout: SOI + APP1("Exif\0\0" + little-endian TIFF) + EOI.
pub fn jpeg_with_exif(datetime: &str) -> Vec<u8> {
    assert_eq!(datetime.len(), 19, "YYYY:MM:DD HH:MM:SS");
    let mut tiff = Vec::new();
    tiff.extend_from_slice(b"II*\0");
    tiff.extend_from_slice(&8u32.to_le_bytes()); // IFD0 offset

    // IFD0: one entry — pointer to the Exif sub-IFD.
    tiff.extend_from_slice(&1u16.to_le_bytes());
    tiff.extend_from_slice(&0x8769u16.to_le_bytes());
    tiff.extend_from_slice(&4u16.to_le_bytes()); // LONG
    tiff.extend_from_slice(&1u32.to_le_bytes());
    tiff.extend_from_slice(&26u32.to_le_bytes()); // sub-IFD offset
    tiff.extend_from_slice(&0u32.to_le_bytes()); // no next IFD

    // Exif sub-IFD at 26: one entry — DateTimeOriginal (0x9003).
    tiff.extend_from_slice(&1u16.to_le_bytes());
    tiff.extend_from_slice(&0x9003u16.to_le_bytes());
    tiff.extend_from_slice(&2u16.to_le_bytes()); // ASCII
    tiff.extend_from_slice(&20u32.to_le_bytes()); // 19 chars + NUL
    tiff.extend_from_slice(&44u32.to_le_bytes()); // value offset
    tiff.extend_from_slice(&0u32.to_le_bytes());
    tiff.extend_from_slice(datetime.as_bytes()); // value at 44
    tiff.push(0);
    assert_eq!(tiff.len(), 64);

    let mut jpeg = vec![0xFF, 0xD8]; // SOI
    jpeg.extend_from_slice(&[0xFF, 0xE1]); // APP1
    jpeg.extend_from_slice(&((2 + 6 + tiff.len()) as u16).to_be_bytes());
    jpeg.extend_from_slice(b"Exif\0\0");
    jpeg.extend_from_slice(&tiff);
    jpeg.extend_from_slice(&[0xFF, 0xD9]); // EOI
    jpeg
}
