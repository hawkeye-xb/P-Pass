//! IDX-01 验收：`adopt_orphans` 是 ADR-006 缺失的那一半——「文件在、索引
//! 行没了 → 补回来」，而且**不许清表**。
//!
//! 与 `rebuild.rs`（T-012）的分工：那边守的是「清表重建能逐字段复原」，
//! 这边守的是「增量收编不碰已在册的行」。两套判据都要在，因为它们现在
//! 共用同一个扫描循环——哪天有人为了让其中一条过而改动循环，另一条会
//! 当场拦住。

use std::path::Path;

use core_index::{adopt_orphans, hash_file};
use storage::{Asset, Db};

const LOCAL: [u8; 32] = [0xcc; 32];

fn write(root: &Path, rel: &str, content: &[u8]) -> std::path::PathBuf {
    let p = root.join(rel);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(&p, content).unwrap();
    p
}

async fn setup() -> (tempfile::TempDir, Db) {
    (
        tempfile::tempdir().unwrap(),
        Db::open_in_memory().await.unwrap(),
    )
}

/// 本卡的核心判据：索引空了、文件还在 → 收编必须把它们全部找回来，
/// 且归属从 `originals/<64hex>/` 反推，而不是一律记成本机。
#[tokio::test(flavor = "multi_thread")]
async fn orphans_on_disk_come_back_with_their_original_owner() {
    let (dir, db) = setup().await;
    let root = dir.path().join("library");
    let dev = "ab".repeat(32);
    write(&root, &format!("originals/{dev}/2026/09/a.jpg"), b"aaa");
    write(&root, &format!("originals/{dev}/2026/09/b.jpg"), b"bbb");
    write(&root, "originals/hand-dropped.jpg", b"ccc");

    let report = adopt_orphans(&db, &root, &LOCAL).await.unwrap();

    assert_eq!(report.adopted, 3);
    assert_eq!(report.already_indexed, 0);
    let page = db.timeline_page(None, 10).await.unwrap();
    assert_eq!(page.assets.len(), 3);
    let owners: Vec<Vec<u8>> = page.assets.iter().map(|a| a.src_device.clone()).collect();
    assert_eq!(
        owners.iter().filter(|o| *o == &LOCAL.to_vec()).count(),
        1,
        "只有不在 <deviceId>/ 布局里的那一个算本机（与 rebuild 同一口径）"
    );
}

/// 反证②的单元版：收编跑第二遍不能改动第一遍留下的任何字段。
/// 若有人把 `adopt_orphans` 实现成 clear+rebuild，`added_at` 会变，这条必红。
#[tokio::test(flavor = "multi_thread")]
async fn a_second_pass_is_a_no_op_and_rewrites_nothing() {
    let (dir, db) = setup().await;
    let root = dir.path().join("library");
    let p = write(&root, "originals/a.jpg", b"aaa");
    let hash = hash_file(&p).unwrap().to_vec();

    assert_eq!(adopt_orphans(&db, &root, &LOCAL).await.unwrap().adopted, 1);
    let first = db.get_asset(&hash).await.unwrap().unwrap();

    let second = adopt_orphans(&db, &root, &LOCAL).await.unwrap();
    assert_eq!(second.adopted, 0, "第二遍没有新东西可收");
    assert_eq!(second.already_indexed, 1);

    let after = db.get_asset(&hash).await.unwrap().unwrap();
    assert_eq!(after.added_at, first.added_at, "added_at 不许被重写");
    assert_eq!(after.rel_path, first.rel_path);
    assert_eq!(after.thumb_state, first.thumb_state);
}

/// 已有行必须原封不动，只补缺的那一条——这是「不清表」最直接的表述。
#[tokio::test(flavor = "multi_thread")]
async fn existing_rows_survive_untouched_while_the_missing_one_is_added() {
    let (dir, db) = setup().await;
    let root = dir.path().join("library");
    let kept = write(&root, "originals/kept.jpg", b"kept");
    write(&root, "originals/missing.jpg", b"missing");
    let kept_hash = hash_file(&kept).unwrap().to_vec();
    db.insert_asset(&Asset {
        hash: kept_hash.clone(),
        rel_path: "originals/kept.jpg".into(),
        media_type: "image/jpeg".into(),
        bytes: 4,
        taken_at: Some(999),
        width: Some(1920),
        height: Some(1080),
        src_device: vec![7u8; 32],
        added_at: 4242,
        thumb_state: 1,
    })
    .await
    .unwrap();

    let report = adopt_orphans(&db, &root, &LOCAL).await.unwrap();

    assert_eq!(report.adopted, 1);
    assert_eq!(report.already_indexed, 1);
    let row = db.get_asset(&kept_hash).await.unwrap().unwrap();
    assert_eq!(
        (row.added_at, row.width, row.height, row.thumb_state),
        (4242, Some(1920), Some(1080), 1),
        "在册行的每个字段都不许动"
    );
    assert_eq!(row.src_device, vec![7u8; 32], "归属也不许被反推覆盖");
}

/// WATCH-07 的噪声纪律：这个函数每小时跑一轮，稳态就是一条都没收。
/// 那种情况写审计 = 每小时刷一行屏。只有真收编了才准记。
#[tokio::test(flavor = "multi_thread")]
async fn an_empty_pass_writes_no_audit_row() {
    let (dir, db) = setup().await;
    let root = dir.path().join("library");
    write(&root, "originals/a.jpg", b"aaa");

    adopt_orphans(&db, &root, &LOCAL).await.unwrap();
    let after_first = db.list_audit(50).await.unwrap();
    assert_eq!(
        after_first
            .iter()
            .filter(|r| r.entry.kind == "index.adopted")
            .count(),
        1,
        "真收编了就该留一条痕"
    );

    adopt_orphans(&db, &root, &LOCAL).await.unwrap();
    let after_second = db.list_audit(50).await.unwrap();
    assert_eq!(
        after_second
            .iter()
            .filter(|r| r.entry.kind == "index.adopted")
            .count(),
        1,
        "空跑一轮不许再加一行——否则每小时刷屏"
    );
}

/// 磁盘上两份相同内容只占一行，且计入 `already_indexed` 而不是 `adopted`
/// （字典序在前的那份赢，与 rebuild 同一规则）。
#[tokio::test(flavor = "multi_thread")]
async fn duplicate_content_counts_as_already_indexed_not_adopted() {
    let (dir, db) = setup().await;
    let root = dir.path().join("library");
    write(&root, "originals/a.jpg", b"same");
    write(&root, "originals/z.jpg", b"same");

    let report = adopt_orphans(&db, &root, &LOCAL).await.unwrap();

    assert_eq!(report.adopted, 1);
    assert_eq!(report.already_indexed, 1);
    let page = db.timeline_page(None, 10).await.unwrap();
    assert_eq!(page.assets.len(), 1);
    assert_eq!(page.assets[0].rel_path, "originals/a.jpg");
}
