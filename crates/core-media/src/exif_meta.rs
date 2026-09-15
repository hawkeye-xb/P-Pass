//! Best-effort EXIF reader: capture time, pixel dimensions, orientation.
//!
//! EXIF 2.31+ 的 `OffsetTimeOriginal`/`OffsetTime` 标签携带真实时区偏移
//! （现代手机——包括本仓真机验证过的三星/华为机型——都会写）；有它时按
//! 该偏移换算真实 UTC 瞬间。**没有**偏移标签的老素材才退回 T-011 的
//! 历史裁决：把裸的墙钟数字当 UTC 解释（不精确，但唯一能做的兜底）。
//!
//! 这不是可选的精度优化：不这样做会导致 EXIF 素材与非 EXIF 素材（视频、
//! 部分截屏——它们的 `taken_at` 落到安卓 `capture_at_ms_hint` 或本地
//! mtime，两者都是真实 UTC 瞬间）在时间线排序键上**不可比**——凡是
//! UTC+N 时区，带偏移量的 EXIF 素材会被系统性地灌水 N 小时，在墙上
//! 排到比它更晚拍摄的视频前面（2026-09-15 用户实测复现：同一手机同一
//! 分钟内的照片与视频顺序错乱）。

use std::fs;
use std::path::Path;

use time::{Date, Month, PrimitiveDateTime, Time, UtcOffset};

/// What EXIF told us about a media file. Every field is optional — a
/// missing or broken EXIF block yields `MediaMeta::default()`, never an
/// error.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MediaMeta {
    /// `DateTimeOriginal`（回退 `DateTime`）换算成的 unix ms。有
    /// `OffsetTimeOriginal`/`OffsetTime` 标签时按真实时区偏移换算；没有
    /// 时才退回把裸值当 UTC 解释的历史兜底（T-011）。
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
    let naive = PrimitiveDateTime::new(date, tod);
    // 优先用同一相对标签的 OffsetTimeOriginal（对应 DateTimeOriginal）；
    // 兜底 OffsetTime（对应 DateTime）——EXIF 规范就是这样成对定义的，
    // 混用会把某个相机写的偏移量套到另一个字段的墙钟上，产出错误结果。
    let offset = offset_field(exif, exif::Tag::OffsetTimeOriginal)
        .or_else(|| offset_field(exif, exif::Tag::OffsetTime));
    let utc = match offset {
        Some(off) => naive.assume_offset(off),
        None => naive.assume_utc(), // 没有偏移标签：退回 T-011 的历史裸值兜底
    };
    Some(utc.unix_timestamp() * 1000)
}

/// 解析 `"+HH:MM"` / `"-HH:MM"`（EXIF 2.31 `OffsetTime*` 的唯一合法形状；
/// `"+00:00"` 也是合法值，不当作"缺失"处理）。任何不符合形状的内容
/// （包括规范允许但罕见的空格占位）一律当作没有该标签，退回裸值兜底。
fn offset_field(exif: &exif::Exif, tag: exif::Tag) -> Option<UtcOffset> {
    let field = exif.get_field(tag, exif::In::PRIMARY)?;
    let raw = match &field.value {
        exif::Value::Ascii(v) => v.first()?,
        _ => return None,
    };
    let s = std::str::from_utf8(raw).ok()?.trim();
    let (sign, rest) = s.strip_prefix('+').map_or_else(
        || s.strip_prefix('-').map(|r| (-1i8, r)),
        |r| Some((1i8, r)),
    )?;
    let (h, m) = rest.split_once(':')?;
    let hours: i8 = h.parse().ok()?;
    let minutes: i8 = m.parse().ok()?;
    UtcOffset::from_hms(sign * hours, sign * minutes, 0).ok()
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
