//! Best-effort EXIF reader: capture time, pixel dimensions, orientation.
//!
//! The wall-clock in EXIF carries no zone; it is interpreted as UTC so the
//! timeline key is stable across machines (T-011 裁决, unchanged here).

use std::fs;
use std::path::Path;

use time::{Date, Month, PrimitiveDateTime, Time};

/// What EXIF told us about a media file. Every field is optional — a
/// missing or broken EXIF block yields `MediaMeta::default()`, never an
/// error.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MediaMeta {
    /// `DateTimeOriginal` (fallback `DateTime`) as unix ms, UTC-interpreted.
    pub taken_at_ms: Option<i64>,
    /// `PixelXDimension` (fallback `ImageWidth`).
    pub width: Option<u32>,
    /// `PixelYDimension` (fallback `ImageLength`).
    pub height: Option<u32>,
    /// EXIF orientation 1–8; `None` when absent (treat as 1 = upright).
    pub orientation: Option<u16>,
}

/// Read EXIF metadata from a file. Missing file, missing EXIF, or garbage
/// all come back as defaults — callers fall back (e.g. ingest uses mtime).
pub fn read_meta(path: &Path) -> MediaMeta {
    try_read(path).unwrap_or_default()
}

fn try_read(path: &Path) -> Option<MediaMeta> {
    let file = fs::File::open(path).ok()?;
    let mut reader = std::io::BufReader::new(file);
    let exif = exif::Reader::new().read_from_container(&mut reader).ok()?;

    Some(MediaMeta {
        taken_at_ms: taken_at_ms(&exif),
        width: dimension(&exif, exif::Tag::PixelXDimension, exif::Tag::ImageWidth),
        height: dimension(&exif, exif::Tag::PixelYDimension, exif::Tag::ImageLength),
        orientation: orientation(&exif),
    })
}

fn taken_at_ms(exif: &exif::Exif) -> Option<i64> {
    let field = exif
        .get_field(exif::Tag::DateTimeOriginal, exif::In::PRIMARY)
        .or_else(|| exif.get_field(exif::Tag::DateTime, exif::In::PRIMARY))?;
    let raw = match &field.value {
        exif::Value::Ascii(v) => v.first()?,
        _ => return None,
    };
    let dt = exif::DateTime::from_ascii(raw).ok()?;
    let date =
        Date::from_calendar_date(i32::from(dt.year), Month::try_from(dt.month).ok()?, dt.day)
            .ok()?;
    let tod = Time::from_hms(dt.hour, dt.minute, dt.second).ok()?;
    Some(
        PrimitiveDateTime::new(date, tod)
            .assume_utc()
            .unix_timestamp()
            * 1000,
    )
}

fn dimension(exif: &exif::Exif, primary: exif::Tag, fallback: exif::Tag) -> Option<u32> {
    let field = exif
        .get_field(primary, exif::In::PRIMARY)
        .or_else(|| exif.get_field(fallback, exif::In::PRIMARY))?;
    let v = field.value.get_uint(0)?;
    (v > 0).then_some(v)
}

fn orientation(exif: &exif::Exif) -> Option<u16> {
    let v = exif
        .get_field(exif::Tag::Orientation, exif::In::PRIMARY)?
        .value
        .get_uint(0)?;
    u16::try_from(v).ok().filter(|o| (1..=8).contains(o))
}
