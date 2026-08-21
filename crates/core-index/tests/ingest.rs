//! T-011 acceptance: ingest lands files, dedups by content, audits, and
//! reports errors that name the failing path.

use std::fs;
use std::path::Path;

use core_index::{IncomingFile, IngestOutcome, Ingestor};
use storage::Db;
use time::{Date, Month, PrimitiveDateTime, Time};

const DEV_A: [u8; 32] = [0xaa; 32];
// Full NodeId as hex (§4.2 <deviceId>) — rebuild (T-012) must recover the
// complete 32-byte src_device from the directory name alone (ADR-006).
const DEV_DIR_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

mod common;
use common::jpeg_with_exif;

fn incoming(dir: &Path, name: &str, content: &[u8]) -> IncomingFile {
    let src = dir.join(format!("staging-{}", name.replace(['/', '\\'], "_")));
    fs::write(&src, content).unwrap();
    IncomingFile {
        src_path: src,
        file_name: name.into(),
        media_type: "image/jpeg".into(),
        src_device: DEV_A.to_vec(),
    }
}

async fn setup() -> (tempfile::TempDir, Db, Ingestor) {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let ing = Ingestor::new(db.clone(), dir.path().join("library"));
    (dir, db, ing)
}

#[tokio::test]
async fn new_file_lands_moved_and_indexed() {
    let (dir, db, ing) = setup().await;
    let content = jpeg_with_exif("2024:05:06 07:08:09");
    let f = incoming(dir.path(), "IMG_1.jpg", &content);

    let outcome = ing.ingest(&f).await.unwrap();
    let IngestOutcome::New(rel) = outcome else {
        panic!("expected New, got {outcome:?}");
    };
    assert_eq!(rel, format!("originals/{DEV_DIR_A}/2024/05/IMG_1.jpg"));

    // Moved, not copied — staging file is gone, library file is identical.
    assert!(!f.src_path.exists(), "source must be moved away");
    let landed = fs::read(dir.path().join("library").join(&rel)).unwrap();
    assert_eq!(landed, content);

    let hash = blake3_of(&content);
    let asset = db.get_asset(&hash).await.unwrap().expect("indexed");
    assert_eq!(asset.rel_path, rel);
    assert_eq!(asset.bytes, content.len() as i64);
    assert_eq!(asset.thumb_state, 0, "thumbs are pending until T-013");
    assert_eq!(asset.src_device, DEV_A.to_vec());
}

#[tokio::test]
async fn exif_datetime_original_becomes_taken_at() {
    let (dir, db, ing) = setup().await;
    let content = jpeg_with_exif("2024:05:06 07:08:09");
    let f = incoming(dir.path(), "IMG_2.jpg", &content);
    ing.ingest(&f).await.unwrap();

    let expected = PrimitiveDateTime::new(
        Date::from_calendar_date(2024, Month::May, 6).unwrap(),
        Time::from_hms(7, 8, 9).unwrap(),
    )
    .assume_utc()
    .unix_timestamp()
        * 1000;
    let asset = db.get_asset(&blake3_of(&content)).await.unwrap().unwrap();
    assert_eq!(asset.taken_at, Some(expected), "EXIF wins over mtime");
}

#[tokio::test]
async fn no_exif_falls_back_to_mtime() {
    let (dir, db, ing) = setup().await;
    let content = b"plain bytes, no exif".to_vec();
    let f = incoming(dir.path(), "note.bin", &content);
    let mtime = fs::metadata(&f.src_path).unwrap().modified().unwrap();
    let mtime_ms = mtime
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;

    ing.ingest(&f).await.unwrap();
    let asset = db.get_asset(&blake3_of(&content)).await.unwrap().unwrap();
    assert_eq!(asset.taken_at, Some(mtime_ms));
}

#[tokio::test]
async fn same_content_different_name_is_duplicate_and_leaves_source() {
    let (dir, db, ing) = setup().await;
    let content = jpeg_with_exif("2023:01:02 03:04:05");
    let f1 = incoming(dir.path(), "a.jpg", &content);
    let f2 = incoming(dir.path(), "totally-different-name.jpg", &content);

    assert!(matches!(
        ing.ingest(&f1).await.unwrap(),
        IngestOutcome::New(_)
    ));
    assert_eq!(ing.ingest(&f2).await.unwrap(), IngestOutcome::Duplicate);

    // Duplicate writes nothing and leaves the caller's file alone.
    assert!(f2.src_path.exists(), "duplicate source must be untouched");
    let page = core_index::timeline_page(&db, None, 100).await.unwrap();
    assert_eq!(page.assets.len(), 1, "one content, one row");
}

#[tokio::test]
async fn name_conflicts_get_dash_suffixes() {
    let (dir, _db, ing) = setup().await;
    // Three different contents, same file name, no EXIF (all land in the
    // mtime month — the same directory).
    let mut rels = Vec::new();
    for n in 0..3u8 {
        let f = incoming(dir.path(), &format!("v{n}/IMG_9.jpg"), &[n; 100]);
        let IngestOutcome::New(rel) = ing.ingest(&f).await.unwrap() else {
            panic!("distinct contents must all be New");
        };
        rels.push(rel);
    }
    let names: Vec<&str> = rels.iter().map(|r| r.rsplit('/').next().unwrap()).collect();
    assert_eq!(names, ["IMG_9.jpg", "IMG_9-1.jpg", "IMG_9-2.jpg"]);
}

#[tokio::test]
async fn ingest_is_audited_to_device_granularity() {
    let (dir, db, ing) = setup().await;
    let content = b"audited content".to_vec();
    ing.ingest(&incoming(dir.path(), "x.jpg", &content))
        .await
        .unwrap();
    ing.ingest(&incoming(dir.path(), "y.jpg", &content))
        .await
        .unwrap();

    let log = db.list_audit(10).await.unwrap();
    let actions: Vec<&str> = log.iter().map(|r| r.entry.action.as_str()).collect();
    assert!(actions.contains(&"ingest.new"), "got {actions:?}");
    assert!(actions.contains(&"ingest.duplicate"), "got {actions:?}");
    for r in &log {
        assert_eq!(
            r.entry.actor,
            Some(DEV_A.to_vec()),
            "product-path ops are attributed to the device"
        );
        assert_eq!(r.entry.target_hash, Some(blake3_of(&content).to_vec()));
    }
}

#[tokio::test]
async fn missing_source_error_names_the_path() {
    let (dir, _db, ing) = setup().await;
    let f = IncomingFile {
        src_path: dir.path().join("does-not-exist.jpg"),
        file_name: "does-not-exist.jpg".into(),
        media_type: "image/jpeg".into(),
        src_device: DEV_A.to_vec(),
    };
    let msg = ing.ingest(&f).await.unwrap_err().to_string();
    assert!(
        msg.contains("does-not-exist.jpg"),
        "human-readable error must name the file: {msg}"
    );
}

#[tokio::test]
async fn traversal_file_name_cannot_escape_library() {
    let (dir, _db, ing) = setup().await;
    let f = incoming(dir.path(), "../../escape.jpg", b"traversal attempt");
    let IngestOutcome::New(rel) = ing.ingest(&f).await.unwrap() else {
        panic!("expected New");
    };
    assert!(
        rel.ends_with("/escape.jpg") && !rel.contains(".."),
        "sanitized rel_path: {rel}"
    );
    assert!(dir.path().join("library").join(&rel).exists());
}

fn blake3_of(content: &[u8]) -> [u8; 32] {
    *blake3::hash(content).as_bytes()
}

// ---------------------------------------------------------------------------
// WATCH-03：hash 是身份，rel_path 只是当前住址。
// ---------------------------------------------------------------------------

#[tokio::test]
async fn move_inside_originals_repoints_the_row_in_place() {
    // 用户在 Finder 里把照片拖进自建目录 = 重新分类。库内位置由用户说了
    // 算，不搬回日期布局；索引改指新位置，行不删。
    let (dir, db, ing) = setup().await;
    let root = dir.path().join("library");
    let content = jpeg_with_exif("2024:05:06 07:08:09");
    let f1 = incoming(dir.path(), "IMG_M.jpg", &content);
    let IngestOutcome::New(rel) = ing.ingest(&f1).await.unwrap() else {
        panic!("first ingest must be New");
    };

    // 模拟 Finder 移动：文件搬到用户自建的相册目录。
    let album = root.join("originals/我的婚礼");
    fs::create_dir_all(&album).unwrap();
    let dest = album.join("IMG_M.jpg");
    fs::rename(root.join(&rel), &dest).unwrap();

    // watcher 在新位置又发现了这份内容。
    let f2 = IncomingFile {
        src_path: dest.clone(),
        file_name: "IMG_M.jpg".into(),
        media_type: "image/jpeg".into(),
        src_device: DEV_A.to_vec(),
    };
    let outcome = ing.ingest(&f2).await.unwrap();
    assert_eq!(
        outcome,
        IngestOutcome::Moved("originals/我的婚礼/IMG_M.jpg".into()),
        "记录的住址空了 + 同内容在库内别处 = 移动，不是重复"
    );
    assert!(dest.exists(), "用户摆的位置不得被搬走");

    let page = core_index::timeline_page(&db, None, 100).await.unwrap();
    assert_eq!(page.assets.len(), 1, "移动不产生第二行");
    assert_eq!(page.assets[0].rel_path, "originals/我的婚礼/IMG_M.jpg");
}

#[tokio::test]
async fn reupload_of_an_externally_deleted_photo_lands_in_canonical_layout() {
    // 手机重传一张曾被外部删掉的照片：来源在库外（staging），按 canonical
    // 布局落位，而不是就地采纳。
    let (dir, db, ing) = setup().await;
    let root = dir.path().join("library");
    let content = jpeg_with_exif("2024:05:06 07:08:09");
    let f1 = incoming(dir.path(), "IMG_R.jpg", &content);
    let IngestOutcome::New(rel) = ing.ingest(&f1).await.unwrap() else {
        panic!("first ingest must be New");
    };
    fs::remove_file(root.join(&rel)).unwrap(); // 用户在 Finder 删了

    let f2 = incoming(dir.path(), "IMG_R.jpg", &content);
    let outcome = ing.ingest(&f2).await.unwrap();
    let IngestOutcome::Moved(new_rel) = outcome else {
        panic!("expected Moved, got {outcome:?}");
    };
    assert!(
        new_rel.starts_with(&format!("originals/{DEV_DIR_A}/")),
        "库外来源必须按日期布局落位，got {new_rel}"
    );
    assert!(root.join(&new_rel).exists(), "文件必须真的落到新位置");
    assert!(!f2.src_path.exists(), "staging 文件已被移走");

    let page = core_index::timeline_page(&db, None, 100).await.unwrap();
    assert_eq!(page.assets.len(), 1);
    assert_eq!(page.assets[0].rel_path, new_rel);
}

#[tokio::test]
async fn duplicate_stays_duplicate_while_the_recorded_file_is_present() {
    // 反向守卫：文件还在位时必须仍然是 Duplicate——否则 Moved 分支会把
    // 正常的重传路径吞掉，源文件被误移走。
    let (dir, _db, ing) = setup().await;
    let content = jpeg_with_exif("2022:03:04 05:06:07");
    let f1 = incoming(dir.path(), "IMG_D.jpg", &content);
    assert!(matches!(
        ing.ingest(&f1).await.unwrap(),
        IngestOutcome::New(_)
    ));
    let f2 = incoming(dir.path(), "IMG_D.jpg", &content);
    assert_eq!(ing.ingest(&f2).await.unwrap(), IngestOutcome::Duplicate);
    assert!(f2.src_path.exists(), "Duplicate 不得动来源文件");
}

// ---------------------------------------------------------------------------
// 2026-08-21 宽容落位 + 路径唯一性
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_file_already_inside_originals_is_adopted_where_it_lies() {
    // 用户在 Finder 里建了「我的婚礼」并把照片放进去 —— 我们只索引，不搬。
    let (dir, db, ing) = setup().await;
    let root = dir.path().join("library");
    let album = root.join("originals/我的婚礼");
    fs::create_dir_all(&album).unwrap();
    let placed = album.join("IMG_W.jpg");
    fs::write(&placed, jpeg_with_exif("2024:06:01 10:00:00")).unwrap();

    let outcome = ing
        .ingest(&IncomingFile {
            src_path: placed.clone(),
            file_name: "IMG_W.jpg".into(),
            media_type: "image/jpeg".into(),
            src_device: DEV_A.to_vec(),
        })
        .await
        .unwrap();

    assert_eq!(
        outcome,
        IngestOutcome::New("originals/我的婚礼/IMG_W.jpg".into()),
        "库内文件就地采纳"
    );
    assert!(placed.exists(), "用户摆的位置不得被动");
    assert!(
        !root.join(format!("originals/{DEV_DIR_A}")).exists(),
        "不该为库内文件建 canonical 目录"
    );
    let page = core_index::timeline_page(&db, None, 10).await.unwrap();
    assert_eq!(page.assets[0].rel_path, "originals/我的婚礼/IMG_W.jpg");
}

#[tokio::test]
async fn a_file_from_outside_still_lands_in_the_canonical_layout() {
    // 反向守卫：手机上传落在 staging（库外），必须由我们找个家——否则
    // 宽容落位会把「谁都不搬」当成默认，上传的文件永远留在中转区。
    let (dir, _db, ing) = setup().await;
    let f = incoming(
        dir.path(),
        "IMG_U.jpg",
        &jpeg_with_exif("2024:06:02 10:00:00"),
    );
    let IngestOutcome::New(rel) = ing.ingest(&f).await.unwrap() else {
        panic!("expected New");
    };
    assert!(
        rel.starts_with(&format!("originals/{DEV_DIR_A}/")),
        "库外来源必须按日期布局落位，got {rel}"
    );
    assert!(!f.src_path.exists(), "staging 文件已被移走");
}

#[tokio::test]
async fn editing_an_indexed_file_leaves_exactly_one_row_at_that_path() {
    // 用户在 Finder 里改了一张已入库的照片：内容变了 → hash 变了 → 在我们
    // 眼里是另一张照片。老那条行还指着同一个路径（文件存在，对账不会清它）
    // —— 必须让位，否则同一个文件被两条行占着，照片墙上出现两次，其中一张
    // 的缩略图取不出来（thumb 按 hash 存）。
    let (dir, db, ing) = setup().await;
    let root = dir.path().join("library");
    let originals = root.join("originals");
    fs::create_dir_all(&originals).unwrap();
    let path = originals.join("IMG_X.jpg");

    fs::write(&path, jpeg_with_exif("2024:06:03 10:00:00")).unwrap();
    let f = IncomingFile {
        src_path: path.clone(),
        file_name: "IMG_X.jpg".into(),
        media_type: "image/jpeg".into(),
        src_device: DEV_A.to_vec(),
    };
    assert!(matches!(
        ing.ingest(&f).await.unwrap(),
        IngestOutcome::New(_)
    ));
    let first_hash = db.list_asset_paths().await.unwrap()[0].0.clone();

    // 就地编辑（内容变了，路径没变）。
    // 改内容（换个合法的 EXIF 时间即可——字节不同就是另一份内容）。
    fs::write(&path, jpeg_with_exif("2024:06:03 11:22:33")).unwrap();
    assert!(matches!(
        ing.ingest(&f).await.unwrap(),
        IngestOutcome::New(_)
    ));

    let rows = db.list_asset_paths().await.unwrap();
    assert_eq!(rows.len(), 1, "一个路径只能被一条索引行占用");
    assert_eq!(rows[0].1, "originals/IMG_X.jpg");
    assert_ne!(rows[0].0, first_hash, "留下的必须是新内容那条");
    // 审计如实记「原地被替换」，不是「外部删除」。
    let n: i64 = sqlx_count(&db, "asset.replaced_in_place").await;
    assert_eq!(n, 1, "让位必须留审计");
}

async fn sqlx_count(db: &Db, action: &str) -> i64 {
    db.list_audit(500)
        .await
        .unwrap()
        .iter()
        .filter(|r| r.entry.action == action)
        .count() as i64
}
