//! #851：用原图替换抹过拍摄地点的旧副本。样本是三星 Android 15 真机取的原文件 / 抹过的副本
//! （core-media/tests/fixtures/redaction）。

use std::fs;
use std::path::{Path, PathBuf};

use core_index::{
    IncomingFile, IngestOutcome, Ingestor, SupersedeApplied, SupersedeCheck, QUARANTINE_DIR,
};
use storage::Db;

const DEV_A: [u8; 32] = [0xaa; 32];
const DEV_B: [u8; 32] = [0xbb; 32];

fn fixture(name: &str, kind: &str) -> Vec<u8> {
    let ext = name.rsplit('.').next().unwrap();
    let stem = name.trim_end_matches(&format!(".{ext}"));
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../core-media/tests/fixtures/redaction");
    fs::read(dir.join(format!("{stem}.{kind}.{ext}"))).unwrap()
}

fn h(b: &[u8]) -> [u8; 32] {
    *blake3::hash(b).as_bytes()
}

struct Lib {
    _dir: tempfile::TempDir,
    root: PathBuf,
    db: Db,
    ing: Ingestor,
}

async fn lib() -> Lib {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let db = Db::open_in_memory().await.unwrap();
    let ing = Ingestor::new(db.clone(), &root);
    Lib {
        _dir: dir,
        root,
        db,
        ing,
    }
}

/// 把抹过的副本 A 按手机上传的方式入库，返回它的 rel_path。
async fn ingest_redacted(l: &Lib, name: &str, redacted: &[u8]) -> String {
    let src = l._dir.path().join(format!("staging-{name}"));
    fs::write(&src, redacted).unwrap();
    let out = l
        .ing
        .ingest(&IncomingFile {
            src_path: src,
            file_name: name.into(),
            media_type: "image/jpeg".into(),
            src_device: DEV_A.to_vec(),
            capture_at_ms_hint: None,
        })
        .await
        .unwrap();
    let IngestOutcome::New(rel) = out else {
        panic!("{out:?}")
    };
    rel
}

/// 手机给的 B 的字节：规划出的每段区间原样切出来（真实链路里是 iroh-blobs 校验过的块）。
fn pieces_for(ranges: &[std::ops::Range<u64>], original: &[u8]) -> Vec<(u64, Vec<u8>)> {
    ranges
        .iter()
        .map(|r| (r.start, original[r.start as usize..r.end as usize].to_vec()))
        .collect()
}

async fn replaces(name: &str) {
    let l = lib().await;
    let (original, redacted) = (fixture(name, "original"), fixture(name, "redacted"));
    let (a, b) = (h(&redacted), h(&original));
    let rel = ingest_redacted(&l, name, &redacted).await;

    let SupersedeCheck::Ready(plan) = l.ing.plan_supersede(&a, &b, &DEV_A).await.unwrap() else {
        panic!("{name}: expected Ready")
    };
    let fetched: u64 = plan.ranges.iter().map(|r| r.end - r.start).sum();
    assert!(
        fetched < original.len() as u64 || original.len() < 4096,
        "{name}: 只要元数据区间，不是整张"
    );

    let out = l
        .ing
        .apply_supersede(
            &plan,
            &b,
            original.len() as u64,
            &pieces_for(&plan.ranges, &original),
            42,
        )
        .await
        .unwrap();
    let SupersedeApplied::Replaced {
        rel_path,
        quarantined,
    } = out
    else {
        panic!("{name}: {out:?}")
    };

    assert_eq!(rel_path, rel, "{name}: 原地替换，路径不变");
    assert_eq!(
        fs::read(l.root.join(&rel)).unwrap(),
        original,
        "{name}: 库里的文件 = 原图"
    );
    assert!(
        l.db.get_asset(&a).await.unwrap().is_none(),
        "{name}: 旧行没了"
    );
    assert_eq!(
        l.db.get_asset(&b).await.unwrap().unwrap().rel_path,
        rel,
        "{name}: 新行在原路径"
    );
    assert_eq!(
        l.db.alias_target(&a).await.unwrap(),
        Some(b.to_vec()),
        "{name}: 别名 A→B"
    );
    assert!(
        l.ing.has_durable_copy(&a).await.unwrap(),
        "{name}: 再报旧指纹算「已有」，不会重传"
    );
    assert!(quarantined.starts_with(QUARANTINE_DIR));
    assert_eq!(
        fs::read(l.root.join(&quarantined)).unwrap(),
        redacted,
        "{name}: 旧副本隔离、没硬删"
    );
    assert!(l.db.pending_swaps().await.unwrap().is_empty());
    assert_eq!(
        l.db.count_assets().await.unwrap(),
        1,
        "{name}: 库里仍是一张"
    );

    // 重放同一个请求：直接成功，不再动任何东西。
    assert_eq!(
        l.ing.plan_supersede(&a, &b, &DEV_A).await.unwrap(),
        SupersedeCheck::AlreadyDone
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn jpeg_is_replaced_in_place_by_its_original() {
    replaces("jpeg.jpg").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn heic_is_replaced_in_place_by_its_original() {
    replaces("heic.heic").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn mp4_is_replaced_in_place_by_its_original() {
    replaces("mp4.mp4").await;
}

/// 拒绝的情形：库一律不动。
async fn refused(l: &Lib, rel: &str, redacted: &[u8], a: &[u8; 32]) {
    assert_eq!(fs::read(l.root.join(rel)).unwrap(), redacted, "文件没被动");
    assert!(l.db.get_asset(a).await.unwrap().is_some(), "旧行还在");
    assert_eq!(l.db.alias_target(a).await.unwrap(), None);
    assert!(l.db.pending_swaps().await.unwrap().is_empty());
    let staging = l.root.join(".ppf/supersede-staging");
    assert!(
        !staging.exists() || fs::read_dir(&staging).unwrap().next().is_none(),
        "拼接用的临时文件清掉了"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn another_devices_copy_is_never_replaced() {
    let l = lib().await;
    let (original, redacted) = (
        fixture("jpeg.jpg", "original"),
        fixture("jpeg.jpg", "redacted"),
    );
    let rel = ingest_redacted(&l, "jpeg.jpg", &redacted).await;
    let a = h(&redacted);
    assert_eq!(
        l.ing
            .plan_supersede(&a, &h(&original), &DEV_B)
            .await
            .unwrap(),
        SupersedeCheck::Refused("not_uploader")
    );
    refused(&l, &rel, &redacted, &a).await;
}

// 反证：B 在 A 非 0 的位置也不同 → 不是「抹地点」，是另一张照片 → 拒绝。
#[tokio::test(flavor = "multi_thread")]
async fn a_change_beyond_zeroed_bytes_is_refused() {
    let l = lib().await;
    let (original, redacted) = (
        fixture("jpeg.jpg", "original"),
        fixture("jpeg.jpg", "redacted"),
    );
    let rel = ingest_redacted(&l, "jpeg.jpg", &redacted).await;
    let a = h(&redacted);
    let SupersedeCheck::Ready(plan) = l
        .ing
        .plan_supersede(&a, &h(&original), &DEV_A)
        .await
        .unwrap()
    else {
        panic!()
    };
    let mut tampered = original.clone();
    let i = (0..tampered.len())
        .find(|&i| redacted[i] != 0 && i > 20 && (i as u64) < plan.ranges[0].end)
        .unwrap();
    tampered[i] ^= 0x55;
    let out = l
        .ing
        .apply_supersede(
            &plan,
            &h(&tampered),
            tampered.len() as u64,
            &pieces_for(&plan.ranges, &tampered),
            1,
        )
        .await
        .unwrap();
    assert_eq!(out, SupersedeApplied::Refused("not_a_redaction"));
    refused(&l, &rel, &redacted, &a).await;
}

// 拼出来的文件指纹对不上（手机报的 B 与给的字节不符）→ 拒绝。
#[tokio::test(flavor = "multi_thread")]
async fn a_splice_that_does_not_hash_to_the_claimed_original_is_refused() {
    let l = lib().await;
    let (original, redacted) = (
        fixture("jpeg.jpg", "original"),
        fixture("jpeg.jpg", "redacted"),
    );
    let rel = ingest_redacted(&l, "jpeg.jpg", &redacted).await;
    let a = h(&redacted);
    let SupersedeCheck::Ready(plan) = l.ing.plan_supersede(&a, &[7; 32], &DEV_A).await.unwrap()
    else {
        panic!()
    };
    let out = l
        .ing
        .apply_supersede(
            &plan,
            &[7; 32],
            original.len() as u64,
            &pieces_for(&plan.ranges, &original),
            1,
        )
        .await
        .unwrap();
    assert_eq!(out, SupersedeApplied::Refused("hash_mismatch"));
    refused(&l, &rel, &redacted, &a).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn size_or_coverage_mismatches_are_refused() {
    let l = lib().await;
    let (original, redacted) = (
        fixture("jpeg.jpg", "original"),
        fixture("jpeg.jpg", "redacted"),
    );
    let rel = ingest_redacted(&l, "jpeg.jpg", &redacted).await;
    let (a, b) = (h(&redacted), h(&original));
    let SupersedeCheck::Ready(plan) = l.ing.plan_supersede(&a, &b, &DEV_A).await.unwrap() else {
        panic!()
    };
    let pieces = pieces_for(&plan.ranges, &original);
    assert_eq!(
        l.ing
            .apply_supersede(&plan, &b, original.len() as u64 + 1, &pieces, 1)
            .await
            .unwrap(),
        SupersedeApplied::Refused("size_mismatch")
    );
    assert_eq!(
        l.ing
            .apply_supersede(&plan, &b, original.len() as u64, &[], 1)
            .await
            .unwrap(),
        SupersedeApplied::Refused("incomplete_ranges")
    );
    refused(&l, &rel, &redacted, &a).await;
}

// 库里的文件在规划之后被改了（用户编辑 / 换了文件）：不拿它当 A 去拼。
#[tokio::test(flavor = "multi_thread")]
async fn a_library_file_that_is_no_longer_the_old_copy_is_refused() {
    let l = lib().await;
    let (original, redacted) = (
        fixture("jpeg.jpg", "original"),
        fixture("jpeg.jpg", "redacted"),
    );
    let rel = ingest_redacted(&l, "jpeg.jpg", &redacted).await;
    let (a, b) = (h(&redacted), h(&original));
    let mut edited = redacted.clone();
    *edited.last_mut().unwrap() ^= 1;
    let SupersedeCheck::Ready(plan) = l.ing.plan_supersede(&a, &b, &DEV_A).await.unwrap() else {
        panic!()
    };
    fs::write(l.root.join(&rel), &edited).unwrap();
    let out = l
        .ing
        .apply_supersede(
            &plan,
            &b,
            original.len() as u64,
            &pieces_for(&plan.ranges, &original),
            1,
        )
        .await
        .unwrap();
    assert_eq!(out, SupersedeApplied::Refused("old_changed"));
    assert_eq!(
        fs::read(l.root.join(&rel)).unwrap(),
        edited,
        "用户改过的文件不动"
    );
    assert!(l.db.get_asset(&a).await.unwrap().is_some());
}

// 索引已改指 B、文件还没换过去时崩溃：启动时补完，rel_path 上始终有文件。
// 反证：没有待换记录 / 不补 → 库里那份仍是 A，而索引说是 B（缩略图、去重全错位），红。
#[tokio::test(flavor = "multi_thread")]
async fn a_crash_between_the_index_change_and_the_file_swap_is_finished_on_startup() {
    let l = lib().await;
    let (original, redacted) = (
        fixture("jpeg.jpg", "original"),
        fixture("jpeg.jpg", "redacted"),
    );
    let rel = ingest_redacted(&l, "jpeg.jpg", &redacted).await;
    let (a, b) = (h(&redacted), h(&original));
    let asset = l.db.get_asset(&a).await.unwrap().unwrap();
    // 模拟 apply_supersede 走到「事务已提交」那一刻：staged 已就绪，rename 还没做。
    let staged_rel = ".ppf/supersede-staging/crash.part";
    fs::create_dir_all(l.root.join(".ppf/supersede-staging")).unwrap();
    fs::write(l.root.join(staged_rel), &original).unwrap();
    let replacement = storage::Asset {
        hash: b.to_vec(),
        ..asset
    };
    l.db.supersede_asset(&a, &replacement, staged_rel, 1)
        .await
        .unwrap();
    assert!(
        l.root.join(&rel).exists(),
        "崩溃窗口里 rel_path 上仍有文件（对账不会当成外部删除）"
    );

    assert_eq!(l.ing.finish_pending_swaps().await.unwrap(), 1);
    assert_eq!(fs::read(l.root.join(&rel)).unwrap(), original);
    assert!(l.db.pending_swaps().await.unwrap().is_empty());
    assert_eq!(
        l.ing.finish_pending_swaps().await.unwrap(),
        0,
        "补完一次就清掉"
    );
}
