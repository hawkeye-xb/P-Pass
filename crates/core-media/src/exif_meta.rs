//! Best-effort EXIF reader: capture time, pixel dimensions, orientation.
//!
//! EXIF 2.31+ 的 `OffsetTimeOriginal`/`OffsetTime` 标签携带真实时区偏移
//! （现代手机——包括本仓真机验证过的三星/华为机型——都会写）；有它时按
//! 该偏移换算真实 UTC 瞬间。**没有**偏移标签时（安卓系统截图、微信/QQ
//! 保存的图、大量老照片都不写），按 **daemon 本机当前 UTC 偏移** 解释那
//! 串墙钟数字。
//!
//! IDX-03（#330）：这里以前是 `assume_utc()`——T-011 的历史兜底。它不是
//! 「不知道时区时的中性选择」，而是**主动声称时区是 0**，于是在 UTC+8，
//! 16:00 之后拍的照片全部显示成次日（实测样本：截图
//! `Screenshot_20260916_181825`，EXIF `18:18:25` 无 offset，库里存成
//! 1789582705000，本地换算 09-17 02:18:25，查看器显示 09-17，系统相册
//! 显示 09-16）。改成本机偏移后两条路径都存「真 UTC」，显示端
//! （`SimpleDateFormat` / `new Date()` 都转本地）一个字不用改。
//!
//! **已知缺陷，不掩盖**：旅行时拍的照片（拍摄地时区 ≠ daemon 所在时区）
//! 回家入库会按家里的时区解释，偏差 = 两地时差。没有 offset 标签的照片
//! 任何做法都在猜，这个猜法至少和用户所在时区一致，而 `assume_utc()`
//! 猜的是格林威治（在中国恒错 8 小时）。根治要靠 Android 上传时带上拍照
//! 当时的手机时区——手机知道、daemon 不知道——那要改协议，属另一张卡，
//! 本卡不做、也不为它预留抽象。
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
    /// `DateTimeOriginal`（回退 `DateTime`）换算成的 unix ms，始终是
    /// **真实 UTC 瞬间**。有 `OffsetTimeOriginal`/`OffsetTime` 标签时按
    /// 照片自带的偏移换算；没有时按 daemon 本机当前偏移换算（IDX-03）。
    /// 本机偏移也取不到时是 `None`——「不知道」不会被伪装成某个值。
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
    read_meta_with_local_offset(path, UtcOffset::current_local_offset().ok())
}

/// [`read_meta`] with the「本机当前 UTC 偏移」作为显式入参，而不是在函数
/// 内部去问操作系统。
///
/// 本机偏移是**运行时输入**，不是常量：把它留在内部就等于让每个用例的
/// 期望值依赖跑测机器的 `TZ`——同一个用例在开发机（UTC+8）绿、在 CI 的
/// UTC runner 上假绿或假红。所以把它提到边界上，由调用方注入。
///
/// `None` 表示「取本机偏移失败」（见 [`read_meta`]），**不是**「偏移为
/// 零」——两者的处置完全不同，见 [`taken_at_ms`]。
pub fn read_meta_with_local_offset(path: &Path, local_offset: Option<UtcOffset>) -> MediaMeta {
    try_read(path, local_offset).unwrap_or_default()
}

fn try_read(path: &Path, local_offset: Option<UtcOffset>) -> Option<MediaMeta> {
    let file = fs::File::open(path).ok()?;
    let mut reader = std::io::BufReader::new(file);
    let exif = exif::Reader::new().read_from_container(&mut reader).ok()?;

    Some(MediaMeta {
        taken_at_ms: taken_at_ms(&exif, local_offset),
        width: dimension(&exif, exif::Tag::PixelXDimension, exif::Tag::ImageWidth),
        height: dimension(&exif, exif::Tag::PixelYDimension, exif::Tag::ImageLength),
        orientation: orientation(&exif),
    })
}

fn taken_at_ms(exif: &exif::Exif, local_offset: Option<UtcOffset>) -> Option<i64> {
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
        // 没有偏移标签：按 daemon 本机当前偏移解释这串墙钟（IDX-03，
        // 取舍见模块头）。本机偏移也取不到时**放弃**这个值而不是回退
        // `assume_utc()`——那就是本卡要修的 bug，而且会静默地把错误结果
        // 混进时间线。`taken_at_ms` 为 `None` 时 ingest 会退到上传方的
        // capture-time hint 或文件 mtime，两者都是真实 UTC 瞬间，和带
        // offset 的那条路径口径一致。其余字段（尺寸/朝向）照常返回。
        None => naive.assume_offset(local_offset.or_else(|| {
            eprintln!(
                "core-media: EXIF 没有 OffsetTime* 且取不到本机 UTC 偏移，\
                 放弃这张的 taken_at（改用 hint/mtime），不做 UTC 假设"
            );
            None
        })?),
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
