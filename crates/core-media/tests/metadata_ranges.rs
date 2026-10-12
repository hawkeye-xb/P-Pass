//! #851：真机抹地点样本（tests/fixtures/redaction）里，原文件与抹过的副本之间每一个不同的字节
//! 都必须落在 `metadata_ranges` 给出的区间里——桌面只取这些区间，取漏一个字节拼出来的文件就对不上。

use std::fs;
use std::path::Path;

fn pair(name: &str) -> (Vec<u8>, Vec<u8>) {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/redaction");
    let ext = name.rsplit('.').next().unwrap();
    let stem = name.trim_end_matches(&format!(".{ext}"));
    (
        fs::read(dir.join(format!("{stem}.original.{ext}"))).unwrap(),
        fs::read(dir.join(format!("{stem}.redacted.{ext}"))).unwrap(),
    )
}

fn check(name: &str) {
    let (original, redacted) = pair(name);
    assert_eq!(original.len(), redacted.len(), "{name}: 抹地点不改长度");
    // 区间按**抹过的那份**算（桌面手里只有它）。
    let ranges =
        core_media::metadata_ranges(&redacted).unwrap_or_else(|| panic!("{name}: 认不出格式"));
    let diffs: Vec<usize> = (0..original.len())
        .filter(|&i| original[i] != redacted[i])
        .collect();
    assert!(!diffs.is_empty(), "{name}: 样本里确实有被抹的字节");
    for i in diffs {
        assert_eq!(redacted[i], 0, "{name}: 偏移 {i} 被抹成了非 0");
        assert!(
            ranges
                .iter()
                .any(|r| r.start <= i as u64 && (i as u64) < r.end),
            "{name}: 偏移 {i} 不在元数据区间 {ranges:?} 里"
        );
    }
    let covered: u64 = ranges.iter().map(|r| r.end - r.start).sum();
    assert!(
        covered < original.len() as u64 || original.len() < 4096,
        "{name}: 区间不应覆盖整个文件 ({covered})"
    );
}

#[test]
fn jpeg_redaction_is_inside_the_app_segments() {
    check("jpeg.jpg");
}

#[test]
fn heic_redaction_is_inside_the_exif_item_extent() {
    check("heic.heic");
}

#[test]
fn mp4_redaction_is_inside_moov() {
    check("mp4.mp4");
}

#[test]
fn unknown_formats_and_truncated_boxes_are_not_guessed() {
    assert_eq!(core_media::metadata_ranges(b"GIF89a....."), None);
    let (original, _) = pair("heic.heic");
    assert_eq!(
        core_media::metadata_ranges(&original[..200]),
        None,
        "截断在 meta 盒子中间"
    );
}
