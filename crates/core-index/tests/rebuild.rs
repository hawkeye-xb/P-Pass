//! T-012 acceptance: the ADR-006 guard. Wipe the index, rebuild from
//! `originals/` alone, and the index must come back identical (modulo
//! `thumb_state` per the card, and `added_at` — both index metadata, not
//! content truth).

mod common;

use std::fs;
use std::path::Path;

use common::jpeg_with_exif;
use core_index::{rebuild, timeline_page, IncomingFile, Ingestor};
use storage::Db;

const DEV_A: [u8; 32] = [0xaa; 32];
const DEV_B: [u8; 32] = [0xbb; 32];

/// The content-derived view of an asset row — everything a rebuild must
/// reproduce exactly.
type Dump = Vec<(
    Vec<u8>,     // hash
    String,      // rel_path
    String,      // media_type
    i64,         // bytes
    Option<i64>, // taken_at
    Option<i64>, // width
    Option<i64>, // height
    Vec<u8>,     // src_device
)>;

/// Full index dump via the paged timeline (small pages on purpose — the
/// dump itself exercises the cursor), sorted by hash for comparison.
async fn dump(db: &Db) -> Dump {
    let mut rows = Dump::new();
    let mut cursor: Option<String> = None;
    loop {
        let page = timeline_page(db, cursor.as_deref(), 7).await.unwrap();
        rows.extend(page.assets.into_iter().map(|a| {
            (
                a.hash,
                a.rel_path,
                a.media_type,
                a.bytes,
                a.taken_at,
                a.width,
                a.height,
                a.src_device,
            )
        }));
        match page.next_cursor {
            Some(c) => cursor = Some(c),
            None => break,
        }
    }
    rows.sort();
    rows
}

/// Tiny deterministic PRNG (xorshift64*) — "random 50-file library" that
/// is identical on every run and every machine.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0.wrapping_mul(0x2545F4914F6CDD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

async fn setup() -> (tempfile::TempDir, Db, Ingestor) {
    let dir = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let ing = Ingestor::new(db.clone(), dir.path().join("library"));
    (dir, db, ing)
}

async fn ingest_one(
    ing: &Ingestor,
    dir: &Path,
    tag: u32,
    name: &str,
    content: &[u8],
    dev: [u8; 32],
) {
    let src = dir.join(format!("staging-{tag}"));
    fs::write(&src, content).unwrap();
    let media_type = match name.rsplit_once('.').map(|(_, e)| e) {
        Some("jpg") => "image/jpeg",
        Some("mp4") => "video/mp4",
        _ => "application/octet-stream",
    };
    ing.ingest(&IncomingFile {
        src_path: src,
        file_name: name.into(),
        media_type: media_type.into(),
        src_device: dev.to_vec(),
    })
    .await
    .unwrap();
}

/// 契约测试: 随机 50 文件库 → ingest → dump → 删库 → rebuild → dump 一致。
#[tokio::test]
async fn rebuild_reproduces_the_index_exactly() {
    let (dir, db, ing) = setup().await;
    let mut rng = Rng(0x5EED_2026_0730_0012);

    for i in 0..50u32 {
        let dev = if rng.below(2) == 0 { DEV_A } else { DEV_B };
        // A small name pool forces -N suffix collisions; EXIF-bearing JPEGs
        // and EXIF-less "videos" cover both taken_at legs.
        if rng.below(2) == 0 {
            let dt = format!(
                "20{:02}:{:02}:{:02} {:02}:{:02}:{:02}",
                rng.below(25),
                1 + rng.below(12),
                1 + rng.below(28),
                rng.below(24),
                rng.below(60),
                rng.below(60)
            );
            let name = format!("IMG_{}.jpg", rng.below(5));
            ingest_one(&ing, dir.path(), i, &name, &jpeg_with_exif(&dt), dev).await;
        } else {
            let mut content = i.to_le_bytes().to_vec();
            for _ in 0..rng.below(512) {
                content.push(rng.next() as u8);
            }
            let name = format!("clip_{}.mp4", rng.below(4));
            ingest_one(&ing, dir.path(), i, &name, &content, dev).await;
        }
    }

    let before = dump(&db).await;
    assert!(!before.is_empty());

    // "删库": the index is gone; a brand-new empty database takes its place.
    let fresh = Db::open_in_memory().await.unwrap();
    let report = rebuild(&fresh, &dir.path().join("library")).await.unwrap();

    let after = dump(&fresh).await;
    assert_eq!(report.indexed, before.len() as u64);
    assert_eq!(
        after, before,
        "rebuild must re-derive every content field (ADR-006)"
    );
}

/// 验收点: 用户手工塞进 originals 的文件（不在规范布局里）rebuild 能收录。
#[tokio::test]
async fn hand_dropped_files_are_picked_up() {
    let (dir, db, ing) = setup().await;
    ingest_one(
        &ing,
        dir.path(),
        0,
        "IMG_0.jpg",
        &jpeg_with_exif("2024:01:02 03:04:05"),
        DEV_A,
    )
    .await;

    let originals = dir.path().join("library/originals");
    fs::write(originals.join("dropped.jpg"), b"hand-dropped bytes").unwrap();
    fs::create_dir_all(originals.join("from-old-nas/2019")).unwrap();
    fs::write(
        originals.join("from-old-nas/2019/scan.png"),
        b"foreign layout",
    )
    .unwrap();

    let report = rebuild(&db, dir.path().join("library").as_path())
        .await
        .unwrap();
    assert_eq!(report.indexed, 3);

    let rows = dump(&db).await;
    let dropped = rows
        .iter()
        .find(|r| r.1 == "originals/dropped.jpg")
        .expect("hand-dropped file must be indexed");
    assert_eq!(dropped.2, "image/jpeg");
    assert_eq!(dropped.7, Vec::<u8>::new(), "origin unknown → empty device");
    assert!(
        dropped.4.is_some(),
        "mtime fallback still keys the timeline"
    );
    assert!(rows
        .iter()
        .any(|r| r.1 == "originals/from-old-nas/2019/scan.png"));
}

/// Rebuild over a live index is a full reconciliation — clear then rescan,
/// so running it twice is idempotent.
#[tokio::test]
async fn rebuild_is_idempotent_on_a_live_index() {
    let (dir, db, ing) = setup().await;
    for i in 0..3u32 {
        ingest_one(
            &ing,
            dir.path(),
            i,
            &format!("IMG_{i}.jpg"),
            &[i as u8; 64],
            DEV_A,
        )
        .await;
    }
    let root = dir.path().join("library");
    let first = rebuild(&db, &root).await.unwrap();
    let d1 = dump(&db).await;
    let second = rebuild(&db, &root).await.unwrap();
    let d2 = dump(&db).await;
    assert_eq!(first, second);
    assert_eq!(d1, d2);
    assert_eq!(d1.len(), 3);
}

/// Two on-disk copies of the same content collapse to one row — the
/// lexicographically first path wins, deterministically.
#[tokio::test]
async fn duplicate_content_on_disk_yields_one_row() {
    let (dir, db, _ing) = setup().await;
    let originals = dir.path().join("library/originals");
    fs::create_dir_all(&originals).unwrap();
    fs::write(originals.join("a-copy.jpg"), b"same bytes").unwrap();
    fs::write(originals.join("b-copy.jpg"), b"same bytes").unwrap();

    let report = rebuild(&db, dir.path().join("library").as_path())
        .await
        .unwrap();
    assert_eq!(report.indexed, 1);
    assert_eq!(report.duplicates, 1);
    let rows = dump(&db).await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].1, "originals/a-copy.jpg");
}

/// The reconciliation is audited with actor = None — the filesystem cannot
/// say who (审计裁决 2026-07-29).
#[tokio::test]
async fn rebuild_writes_an_unattributed_audit_row() {
    let (dir, db, _ing) = setup().await;
    rebuild(&db, dir.path().join("library").as_path())
        .await
        .unwrap();
    let log = db.list_audit(10).await.unwrap();
    let row = log
        .iter()
        .find(|r| r.entry.action == "index.rebuild")
        .expect("rebuild must be audited");
    assert_eq!(row.entry.actor, None);
    assert_eq!(row.entry.detail.as_deref(), Some("indexed=0 duplicates=0"));
}

/// Hidden files (`.DS_Store` and friends) never enter the index; a library
/// with no `originals/` at all is empty, not an error.
#[tokio::test]
async fn hidden_files_skipped_and_missing_originals_is_empty() {
    let (dir, db, _ing) = setup().await;
    let root = dir.path().join("library");

    let empty = rebuild(&db, &root).await.unwrap();
    assert_eq!((empty.indexed, empty.duplicates), (0, 0));

    let originals = root.join("originals");
    fs::create_dir_all(originals.join(".hidden-dir")).unwrap();
    fs::write(originals.join(".DS_Store"), b"finder junk").unwrap();
    fs::write(
        originals.join(".hidden-dir").join("x.jpg"),
        b"inside hidden",
    )
    .unwrap();
    fs::write(originals.join("real.jpg"), b"real photo").unwrap();

    let report = rebuild(&db, &root).await.unwrap();
    assert_eq!(report.indexed, 1);
    assert_eq!(dump(&db).await[0].1, "originals/real.jpg");
}
