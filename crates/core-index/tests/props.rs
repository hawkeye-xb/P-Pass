//! T-011 property tests (契约点名 proptest ×2):
//! 1. same content, any two paths/names → second ingest is Duplicate;
//! 2. timeline keyset cursor is strictly monotonic — no dup, no miss.

use core_index::{timeline_page, IncomingFile, IngestOutcome, Ingestor};
use proptest::prelude::*;
use storage::{Asset, Db};

fn rt() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 32, ..ProptestConfig::default() })]

    #[test]
    fn same_content_twice_is_always_duplicate(
        content in proptest::collection::vec(any::<u8>(), 0..4096),
        name_a in "[a-z0-9]{1,12}",
        name_b in "[a-z0-9]{1,12}",
    ) {
        let (first, second, rows) = rt().block_on(async {
            let dir = tempfile::tempdir().unwrap();
            let db = Db::open_in_memory().await.unwrap();
            let ing = Ingestor::new(db.clone(), dir.path().join("lib"));

            let file = |tag: &str, name: &str| {
                let src = dir.path().join(format!("staging-{tag}"));
                std::fs::write(&src, &content).unwrap();
                IncomingFile {
                    src_path: src,
                    file_name: format!("{name}.jpg"),
                    media_type: "image/jpeg".into(),
                    src_device: vec![7u8; 32],
                }
            };
            let first = ing.ingest(&file("a", &name_a)).await.unwrap();
            let second = ing.ingest(&file("b", &name_b)).await.unwrap();
            let rows = timeline_page(&db, None, 1000).await.unwrap().assets.len();
            (first, second, rows)
        });
        prop_assert!(matches!(first, IngestOutcome::New(_)));
        prop_assert_eq!(second, IngestOutcome::Duplicate);
        prop_assert_eq!(rows, 1);
    }

    #[test]
    fn timeline_cursor_is_monotonic_no_dup_no_miss(
        // 0..8 forces heavy taken_at ties (hash tiebreak coverage); None
        // exercises the COALESCE(taken_at, 0) leg.
        taken in proptest::collection::vec(proptest::option::of(0i64..8), 1..60),
        limit in 1u32..10,
    ) {
        let keys: Vec<(i64, Vec<u8>)> = rt().block_on(async {
            let db = Db::open_in_memory().await.unwrap();
            for (i, t) in taken.iter().enumerate() {
                let mut hash = vec![0u8; 32];
                hash[0] = i as u8;
                db.insert_asset(&Asset {
                    hash,
                    rel_path: format!("originals/d/2026/07/{i}.jpg"),
                    media_type: "image/jpeg".into(),
                    bytes: 1,
                    taken_at: *t,
                    width: None,
                    height: None,
                    src_device: vec![1u8; 32],
                    added_at: 0,
                    thumb_state: 0,
                })
                .await
                .unwrap();
            }
            let mut got = Vec::new();
            let mut cursor: Option<String> = None;
            loop {
                let page = timeline_page(&db, cursor.as_deref(), limit).await.unwrap();
                got.extend(
                    page.assets
                        .iter()
                        .map(|a| (a.taken_at.unwrap_or(0), a.hash.clone())),
                );
                match page.next_cursor {
                    Some(c) => cursor = Some(c),
                    None => break,
                }
            }
            got
        });

        // No miss:
        prop_assert_eq!(keys.len(), taken.len());
        // Strictly monotonic in (taken_at DESC, hash ASC) — which also
        // proves no duplicates:
        for w in keys.windows(2) {
            let ((t1, h1), (t2, h2)) = (&w[0], &w[1]);
            prop_assert!(
                t1 > t2 || (t1 == t2 && h1 < h2),
                "cursor order violated: ({}, {:?}) then ({}, {:?})", t1, h1[0], t2, h2[0]
            );
        }
    }
}
