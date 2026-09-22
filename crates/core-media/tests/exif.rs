//! T-013 acceptance for the EXIF reader: full field set, and hostile
//! input degrades to defaults instead of erroring.

use std::fs;

use core_media::{read_meta, read_meta_with_local_offset, MediaMeta};
use time::{Date, Month, OffsetDateTime, PrimitiveDateTime, Time, UtcOffset};

/// 把 `taken_at_ms` 换回「在 `offset` 这个时区里的墙钟」。
///
/// IDX-03 的断言都走这里，而不是硬编一个 unix ms：本卡的不变量是
/// **没有 offset 标签时，EXIF 里的墙钟数字在 daemon 本机时区里原样成立**
/// ——「09-16 18:18:25 拍的，在本机就该读回 09-16 18:18:25」。直接比
/// unix ms 只能对一个写死的偏移成立，换个偏移就要重算一遍期望值，
/// 而那正是本卡最容易写错的地方（见 #330 验收评论）。
fn wall_clock_in(taken_at_ms: i64, offset: UtcOffset) -> PrimitiveDateTime {
    let odt = OffsetDateTime::from_unix_timestamp_nanos(i128::from(taken_at_ms) * 1_000_000)
        .unwrap()
        .to_offset(offset);
    PrimitiveDateTime::new(odt.date(), odt.time())
}

/// `YYYY-MM-DD HH:MM:SS` 的字面量写法，只为让期望值一眼可读。
fn wall(y: i32, mo: u8, d: u8, h: u8, mi: u8, s: u8) -> PrimitiveDateTime {
    PrimitiveDateTime::new(
        Date::from_calendar_date(y, Month::try_from(mo).unwrap(), d).unwrap(),
        Time::from_hms(h, mi, s).unwrap(),
    )
}

/// 本卡用来注入的几个偏移：跨越东西半球和半小时时区，确保结论不是
/// 「在 +08:00 上碰巧成立」。
const INJECTED_OFFSETS: [(i8, i8); 5] = [(8, 0), (0, 0), (-5, 0), (5, 30), (-11, 0)];

fn off(hours: i8, minutes: i8) -> UtcOffset {
    UtcOffset::from_hms(hours, minutes, 0).unwrap()
}

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

    // IDX-03：这张没有 `OffsetTime*` 标签，所以 `taken_at` 取决于 daemon
    // 本机偏移——注入 UTC 才能让这条断言与跑测机器的 TZ 无关。
    let meta = read_meta_with_local_offset(&p, Some(UtcOffset::UTC));
    // 墙钟 2025-12-31 23:59:58，本机偏移 +00:00 ⇒ 1_767_225_598 s.
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

// ── IDX-03：无 `OffsetTime*` 标签的墙钟按 daemon 本机偏移解释 ──────────
//
// 这一组用例全部**注入**本机偏移（`read_meta_with_local_offset`），
// 一个期望值都不依赖跑测机器的真实 `TZ`：同一份断言在 UTC runner 和
// UTC+8 开发机上跑出同一个结果。唯一读真实本机偏移的是
// `public_read_meta_uses_the_real_local_offset`，它按当前偏移**推导**
// 期望值，而不是硬编。

/// 本卡的真实样本：`Screenshot_20260916_181825_com.sankuai.meituan.jpg`
/// ——EXIF `DateTimeOriginal = 2026:09:16 18:18:25`、**无** `OffsetTime*`
/// （安卓系统截图不写这个标签）。修复前 `assume_utc()` 把它存成
/// 1_789_582_705_000，在 UTC+8 换算回本地是 09-17 02:18:25，查看器显示
/// 09-17，而系统相册显示 09-16。
#[test]
fn real_sample_without_offset_keeps_its_capture_date() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir
        .path()
        .join("Screenshot_20260916_181825_com.sankuai.meituan.jpg");
    fs::write(
        &p,
        jpeg_with_offset("2026:09:16 18:18:25", None, 1, 1080, 2340),
    )
    .unwrap();

    for (h, m) in INJECTED_OFFSETS {
        let local = off(h, m);
        let meta = read_meta_with_local_offset(&p, Some(local));
        let ms = meta
            .taken_at_ms
            .expect("DateTimeOriginal 在，必须算得出时间");
        assert_eq!(
            wall_clock_in(ms, local),
            wall(2026, 9, 16, 18, 18, 25),
            "本机偏移 {local}：墙钟 18:18:25 必须仍是 09-16，不许漂到 09-17"
        );
    }

    // 同一条结论的绝对值形式：+08:00 下 = 2026-09-16T10:18:25Z。修复前
    // 这里存的是 1_789_582_705_000（把 18:18:25 当成了 UTC）。
    assert_eq!(
        read_meta_with_local_offset(&p, Some(off(8, 0))).taken_at_ms,
        Some(1_789_553_905_000)
    );
}

/// 跨日边界：「差一天」最容易复发的地方。23:30 不许溜到次日，00:30
/// 不许退回前一天——在东西两侧的偏移上各验一次。
#[test]
fn day_boundaries_do_not_shift_across_midnight() {
    let dir = tempfile::tempdir().unwrap();
    let late = dir.path().join("late.jpg");
    fs::write(
        &late,
        jpeg_with_offset("2026:09:16 23:30:00", None, 1, 10, 10),
    )
    .unwrap();
    let early = dir.path().join("early.jpg");
    fs::write(
        &early,
        jpeg_with_offset("2026:09:17 00:30:00", None, 1, 10, 10),
    )
    .unwrap();

    for (h, m) in INJECTED_OFFSETS {
        let local = off(h, m);
        let late_ms = read_meta_with_local_offset(&late, Some(local))
            .taken_at_ms
            .unwrap();
        assert_eq!(
            wall_clock_in(late_ms, local),
            wall(2026, 9, 16, 23, 30, 0),
            "本机偏移 {local}：23:30 拍的仍是 09-16"
        );
        let early_ms = read_meta_with_local_offset(&early, Some(local))
            .taken_at_ms
            .unwrap();
        assert_eq!(
            wall_clock_in(early_ms, local),
            wall(2026, 9, 17, 0, 30, 0),
            "本机偏移 {local}：00:30 拍的仍是 09-17"
        );
    }
}

/// 取本机偏移失败（`current_local_offset()` 返回 `Err`）时的回退：
/// `taken_at_ms` 为 `None`，让 ingest 走 hint/mtime（两者都是真实 UTC
/// 瞬间）。**绝不许悄悄退回 `assume_utc()`** —— 那正是本卡要修的 bug，
/// 而且会静默地把错误结果混进时间线。
///
/// 同时锁住：只有 `taken_at_ms` 受影响，尺寸/朝向照常返回——
/// `media-codec/src/decode.rs` 靠 `orientation` 做旋转，整体退回
/// `MediaMeta::default()` 会顺手把旋转弄坏。
#[test]
fn unknown_local_offset_yields_no_taken_at_instead_of_silent_utc() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("no_offset.jpg");
    fs::write(
        &p,
        jpeg_with_offset("2026:09:16 18:18:25", None, 6, 1080, 2340),
    )
    .unwrap();

    let meta = read_meta_with_local_offset(&p, None);
    assert_eq!(
        meta.taken_at_ms, None,
        "本机偏移未知时不许假装知道——尤其不许退回把裸值当 UTC"
    );
    assert_eq!(meta.orientation, Some(6));
    assert_eq!(meta.width, Some(1080));
    assert_eq!(meta.height, Some(2340));
}

/// 有 `OffsetTimeOriginal` 时，本机偏移**一点都不参与**——照片自带的
/// 偏移才是真相。注入任何本机偏移，结果都必须是同一个 UTC 瞬间。
#[test]
fn explicit_offset_tag_ignores_the_local_offset() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("offset_plus8.jpg");
    fs::write(
        &p,
        jpeg_with_offset("2026:09:15 15:52:36", Some("+08:00"), 1, 10, 10),
    )
    .unwrap();

    for (h, m) in INJECTED_OFFSETS {
        assert_eq!(
            read_meta_with_local_offset(&p, Some(off(h, m))).taken_at_ms,
            Some(1_789_458_756_000),
            "自带 +08:00 的照片不受 daemon 本机偏移影响"
        );
    }
    // 本机偏移取不到也一样：这条路径压根不需要它。
    assert_eq!(
        read_meta_with_local_offset(&p, None).taken_at_ms,
        Some(1_789_458_756_000)
    );
}

/// 公开入口 `read_meta` 确实把真实本机偏移接了进去。期望值**按当前
/// 偏移推导**（不是硬编 +08:00），所以在任何 `TZ` 下都确定性通过。
#[test]
fn public_read_meta_uses_the_real_local_offset() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("no_offset_real_path.jpg");
    fs::write(&p, jpeg_with_offset("2026:09:16 18:18:25", None, 1, 10, 10)).unwrap();

    let meta = read_meta(&p);
    match UtcOffset::current_local_offset() {
        Ok(local) => {
            let ms = meta.taken_at_ms.expect("本机偏移可取时必须算得出 taken_at");
            assert_eq!(wall_clock_in(ms, local), wall(2026, 9, 16, 18, 18, 25));
            assert_eq!(
                read_meta_with_local_offset(&p, Some(local)).taken_at_ms,
                Some(ms),
                "read_meta 必须等价于注入当前本机偏移"
            );
        }
        // 取不到就只能是 None——不许有第三种结局。
        Err(_) => assert_eq!(meta.taken_at_ms, None),
    }
}

/// 查证记录（#330 要求「自己查证当前依赖版本的实际行为」）：
/// time 0.3.54 的 `sys/local_offset_at/unix.rs::local_offset_at` 直接调
/// `libc::localtime_r` 取 `tm_gmtoff`，**没有**线程数闸门——
/// `num_threads::is_single_threaded()` 在 0.3.54 里只剩
/// `sys/refresh_tz/unix.rs` 一处（判断能否调 `tzset`），`src/` 里搜不到
/// `unsound_local_offset`。cargo 的测试 harness 默认多线程，所以这条
/// 绿 = 多线程下 `current_local_offset()` 可用的实测证据，而不是读源码
/// 的推论。`Err` 分支仍然可达（`localtime_r` 失败），它的处置见
/// `unknown_local_offset_yields_no_taken_at_instead_of_silent_utc`。
#[test]
fn current_local_offset_is_obtainable_under_the_multithreaded_test_harness() {
    assert!(
        UtcOffset::current_local_offset().is_ok(),
        "time 0.3.54 在多线程进程里也应能取到本机偏移"
    );
}
