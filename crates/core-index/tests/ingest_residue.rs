//! #1047：入库被打断的残留清理（`sweep_ingest_residue`）。
//!
//! 判据（见函数文档）：originals/ 下、文件名严格匹配 `.ppf-ingest-*.part`、
//! 且没有索引行。每条「必须保留」的用例都是对「判据放宽」的反证。

use std::path::Path;

use core_index::{adopt_orphans, sweep_ingest_residue};
use storage::{Asset, Db};

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

/// 残留（0 字节的和写了一半的，含嵌套目录）被清掉，并且**不会**被收编。
/// 去掉清理逻辑：残留文件仍在，断言红。
#[tokio::test(flavor = "multi_thread")]
async fn ingest_temp_files_are_swept_and_never_adopted() {
    let (dir, db) = setup().await;
    let root = dir.path();
    let dev = "ab".repeat(32);
    let half = write(
        root,
        &format!("originals/{dev}/2026/10/.ppf-ingest-42-1.part"),
        b"half a jpeg",
    );
    let empty = write(root, "originals/x/.ppf-ingest-7-9.part", b"");

    assert_eq!(sweep_ingest_residue(&db, root).await.unwrap().removed, 2);
    assert!(!half.exists() && !empty.exists());

    let r = adopt_orphans(&db, root, &[0xcc; 32]).await.unwrap();
    assert_eq!((r.adopted, r.skipped_empty), (0, 0));
}

/// 用户的文件一个都不能动：普通文件（含空文件、残缺文件）、名字相近但
/// 前后缀不完全匹配的点文件、同名但是目录的东西。
#[tokio::test(flavor = "multi_thread")]
async fn user_files_and_lookalikes_survive() {
    let (dir, db) = setup().await;
    let root = dir.path();
    let keep = [
        write(root, "originals/IMG_1.jpg", b"photo"),
        write(root, "originals/empty.jpg", b""),
        write(root, "originals/truncated.jpg", b"\xff\xd8\xff"),
        write(root, "originals/.ppf-ingest-1-1.part.bak", b"x"),
        write(root, "originals/.ppf-ingest-1-1", b"x"),
        write(root, "originals/ppf-ingest-1-1.part", b"x"),
        write(root, "originals/.ppf-ingest-.part", b"x"),
        write(root, "originals/.ppf-INGEST-1.part", b"x"),
        write(root, "originals/a.part", b"x"),
        // 库外同名文件也不碰：.ppf/ 下不是 originals/。
        write(root, ".ppf/staging/.ppf-ingest-1-1.part", b"x"),
        write(root, "elsewhere/.ppf-ingest-1-1.part", b"x"),
    ];
    std::fs::create_dir_all(root.join("originals/.ppf-ingest-9-9.part.d")).unwrap();

    assert_eq!(sweep_ingest_residue(&db, root).await.unwrap().removed, 0);
    for p in &keep {
        assert!(p.exists(), "不该被删：{}", p.display());
    }
}

/// 有索引行指着的路径，即使名字像临时文件也不删（判据第 3 条）。
#[tokio::test(flavor = "multi_thread")]
async fn a_path_with_an_index_row_is_never_swept() {
    let (dir, db) = setup().await;
    let root = dir.path();
    let rel = "originals/.ppf-ingest-5-5.part";
    let p = write(root, rel, b"indexed on purpose");
    db.insert_asset(&Asset {
        hash: vec![1; 32],
        rel_path: rel.into(),
        media_type: "image/jpeg".into(),
        bytes: 18,
        taken_at: Some(0),
        width: None,
        height: None,
        src_device: vec![0xcc; 32],
        added_at: 0,
        thumb_state: 0,
    })
    .await
    .unwrap();

    assert_eq!(sweep_ingest_residue(&db, root).await.unwrap().removed, 0);
    assert!(p.exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn missing_originals_dir_is_fine() {
    let (dir, db) = setup().await;
    assert_eq!(
        sweep_ingest_residue(&db, dir.path()).await.unwrap().removed,
        0
    );
}

/// #1183：清扫改到后台跑之后，本进程正在写的临时文件（名字里的 pid = 本进程）不许删——
/// 它属于「正在进行的入库」。别的进程（上一次运行）留下的照删。
/// 反证：去掉 `ingest_temp_pid(..) == Some(me)` 那条 → 本进程那份被删，红。
#[tokio::test(flavor = "multi_thread")]
async fn this_process_in_flight_temp_is_kept_while_older_runs_residue_goes() {
    let (dir, db) = setup().await;
    let root = dir.path();
    let me = std::process::id();
    let mine = write(
        root,
        &format!("originals/x/.ppf-ingest-{me}-123.part"),
        b"being copied",
    );
    let theirs = write(
        root,
        &format!("originals/x/.ppf-ingest-{}-123.part", me.wrapping_add(1)),
        b"crashed run",
    );
    let r = sweep_ingest_residue(&db, root).await.unwrap();
    assert_eq!(r.removed, 1, "{r:?}");
    assert_eq!(r.freed_bytes, b"crashed run".len() as u64);
    assert_eq!(r.kept, vec![("-".to_string(), "in_flight")]);
    assert!(mine.exists());
    assert!(!theirs.exists());
}

/// 名字匹配的符号链接 / 目录不删，也不跟进去删链接指向的东西。
/// 反证：把递归判定 `kind.is_dir()` 换成 `entry.path().is_dir()`（跟随链接）→ 链接指向的文件被删，红。
#[tokio::test(flavor = "multi_thread")]
async fn a_link_named_like_a_temp_is_never_touched_or_followed() {
    let (dir, db) = setup().await;
    let root = dir.path();
    let outside = dir.path().join("outside");
    let victim = write(&outside, ".ppf-ingest-1-1.part", b"not in the library");
    std::fs::create_dir_all(root.join("originals")).unwrap();
    for kind in platform::test_support::dir_link_kinds() {
        let link = root.join(format!("originals/.ppf-ingest-2-{}.part", kind.name));
        if let Err(e) = kind.make(&outside, &link) {
            assert!(kind.may_need_privilege, "{}: {e}", kind.name);
            eprintln!("跳过 {}: {e}", kind.name);
            continue;
        }
        let r = sweep_ingest_residue(&db, root).await.unwrap();
        assert_eq!(r.removed, 0, "{}: {r:?}", kind.name);
        assert!(
            std::fs::symlink_metadata(&link).is_ok(),
            "{}: 链接还在",
            kind.name
        );
        assert!(victim.exists(), "{}: 链接指向的东西没动", kind.name);
    }
}
