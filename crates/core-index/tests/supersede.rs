//! #851：用原图替换抹过拍摄地点的旧副本。样本是三星 Android 15 真机取的原文件 / 抹过的副本
//! （core-media/tests/fixtures/redaction）。

use std::fs;
use std::path::{Path, PathBuf};

use core_index::{
    sweep_supersede_staging, sweep_superseded_residue, IncomingFile, IngestOutcome, Ingestor,
    SupersedeApplied, SupersedeCheck, SUPERSEDED_RESIDUE_DIR, SUPERSEDE_STAGING_DIR,
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

/// 库目录下所有普通文件的字节数之和（按路径逐个加：同一 inode 的硬链接会被算两次，
/// 所以「把 A 硬链接留一份」也会让总量变多）。
fn tree_bytes(dir: &Path) -> u64 {
    let Ok(rd) = fs::read_dir(dir) else { return 0 };
    rd.map(|e| e.unwrap())
        .map(|e| {
            let t = e.file_type().unwrap();
            if t.is_dir() {
                tree_bytes(&e.path())
            } else {
                e.metadata().unwrap().len()
            }
        })
        .sum()
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
    let bytes_before = tree_bytes(&l.root);

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
    let SupersedeApplied::Replaced { rel_path } = out else {
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
    // #1182：不留旧副本，库占盘仍是 1x（B 与 A 等长）。
    // 反证：恢复把 A 硬链接 / 复制进 `.ppf/superseded/` 的那段 → 两条断言都红。
    assert!(
        !l.root.join(SUPERSEDED_RESIDUE_DIR).exists(),
        "{name}: 不再产生 .ppf/superseded/"
    );
    assert_eq!(
        tree_bytes(&l.root),
        bytes_before,
        "{name}: 库目录总字节 = 替换前（没有多出一份旧副本）"
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

/// 业务规则 §6.5 / `MAX_REGION_BYTES`：要抓的元数据区间合计超过 8 MiB 就拒绝
/// （`region_too_large`），不去抓几乎整个文件。构造一个只有 `ftyp` + 一个 `moov` 盒子的
/// MP4：`moov` 整块都算元数据区间，大小可控。恰好 8 MiB 仍可替换。
/// 反证：`>` 改 `>=` → 恰好 8 MiB 那条红；去掉上限判断 → 8 MiB+1 那条红。
fn mp4_with_moov(moov_total: usize) -> Vec<u8> {
    let mut f = Vec::new();
    f.extend_from_slice(&[0, 0, 0, 16]);
    f.extend_from_slice(b"ftypisom");
    f.extend_from_slice(&[0, 0, 0, 0]);
    f.extend_from_slice(&(moov_total as u32).to_be_bytes());
    f.extend_from_slice(b"moov");
    f.resize(16 + moov_total, 0);
    f
}

#[tokio::test(flavor = "multi_thread")]
async fn a_metadata_region_over_eight_mib_is_refused_as_too_large() {
    let cap = core_index::MAX_REGION_BYTES as usize;
    assert_eq!(cap, 8 * 1024 * 1024);
    for (moov, expect_ready) in [(cap, true), (cap + 1, false)] {
        let l = lib().await;
        let a_bytes = mp4_with_moov(moov);
        let mut b_bytes = a_bytes.clone();
        *b_bytes.last_mut().unwrap() = 1; // 另一个文件，长度相同
        let src = l._dir.path().join("staging-big.mp4");
        fs::write(&src, &a_bytes).unwrap();
        let out = l
            .ing
            .ingest(&IncomingFile {
                src_path: src,
                file_name: "big.mp4".into(),
                media_type: "video/mp4".into(),
                src_device: DEV_A.to_vec(),
                capture_at_ms_hint: None,
            })
            .await
            .unwrap();
        assert!(matches!(out, IngestOutcome::New(_)), "{out:?}");
        let check = l
            .ing
            .plan_supersede(&h(&a_bytes), &h(&b_bytes), &DEV_A)
            .await
            .unwrap();
        if expect_ready {
            assert!(
                matches!(check, SupersedeCheck::Ready(_)),
                "恰好 8 MiB 应可替换: {check:?}"
            );
        } else {
            assert_eq!(check, SupersedeCheck::Refused("region_too_large"));
        }
    }
}

// ── #1182 / #1183：旧版留在 `.ppf/superseded/` 的旧副本，残留清扫按判据清掉 ──────────

/// 走一遍真实替换，再按旧版的样子把 A 放进残留目录。返回 (库, A 的指纹, B 的 rel_path, 残留文件)。
async fn library_with_legacy_copy() -> (Lib, [u8; 32], String, PathBuf) {
    let l = lib().await;
    let (original, redacted) = (
        fixture("jpeg.jpg", "original"),
        fixture("jpeg.jpg", "redacted"),
    );
    let (a, b) = (h(&redacted), h(&original));
    ingest_redacted(&l, "jpeg.jpg", &redacted).await;
    let SupersedeCheck::Ready(plan) = l.ing.plan_supersede(&a, &b, &DEV_A).await.unwrap() else {
        panic!("expected Ready")
    };
    let SupersedeApplied::Replaced { rel_path } = l
        .ing
        .apply_supersede(
            &plan,
            &b,
            original.len() as u64,
            &pieces_for(&plan.ranges, &original),
            1,
        )
        .await
        .unwrap()
    else {
        panic!("expected Replaced")
    };
    let legacy = l
        .root
        .join(SUPERSEDED_RESIDUE_DIR)
        .join(format!("{}.jpg", hex(&a)));
    fs::create_dir_all(legacy.parent().unwrap()).unwrap();
    fs::write(&legacy, &redacted).unwrap();
    (l, a, rel_path, legacy)
}

fn hex(h: &[u8]) -> String {
    h.iter().map(|b| format!("{b:02x}")).collect()
}

// 别名 A→B 在、B 的文件在：遗留的 A 被删，目录删空后也删掉；库里那份原图不受影响。
#[tokio::test(flavor = "multi_thread")]
async fn a_legacy_superseded_copy_is_removed_when_its_original_is_in_the_library() {
    let (l, _a, rel, legacy) = library_with_legacy_copy().await;
    let report = sweep_superseded_residue(&l.db, &l.root).await.unwrap();
    assert_eq!(report.removed, 1, "{report:?}");
    assert!(report.kept.is_empty(), "{report:?}");
    assert!(!legacy.exists());
    assert!(report.dir_removed);
    assert!(!l.root.join(SUPERSEDED_RESIDUE_DIR).exists());
    assert_eq!(
        fs::read(l.root.join(&rel)).unwrap(),
        fixture("jpeg.jpg", "original"),
        "原图不动"
    );
    // 再跑一次：目录已不在，什么都不做。
    let again = sweep_superseded_residue(&l.db, &l.root).await.unwrap();
    assert_eq!(again.removed, 0);
}

// 别名缺失：不知道它被谁替换了，不删；目录也留着。
#[tokio::test(flavor = "multi_thread")]
async fn a_legacy_copy_without_an_alias_is_kept() {
    let (l, _a, _rel, legacy) = library_with_legacy_copy().await;
    let stray = legacy.with_file_name(format!("{}.jpg", hex(&[7u8; 32])));
    fs::rename(&legacy, &stray).unwrap();
    let report = sweep_superseded_residue(&l.db, &l.root).await.unwrap();
    assert_eq!(report.removed, 0);
    assert_eq!(report.kept, vec![("07070707".to_string(), "no_alias")]);
    assert!(stray.exists());
    assert!(!report.dir_removed);
    assert!(l.root.join(SUPERSEDED_RESIDUE_DIR).is_dir());
}

// 别名在、但 B 的文件不在盘上（外部删除、对账还没跑）：A 可能是这张照片仅剩的一份，不删。
// 反证：去掉「rel_path 在盘上」这条判据 → 本条红。
#[tokio::test(flavor = "multi_thread")]
async fn a_legacy_copy_whose_original_file_is_gone_is_kept() {
    let (l, a, rel, legacy) = library_with_legacy_copy().await;
    fs::remove_file(l.root.join(&rel)).unwrap();
    let report = sweep_superseded_residue(&l.db, &l.root).await.unwrap();
    assert_eq!(report.removed, 0);
    assert_eq!(
        report.kept,
        vec![(hex(&a)[..8].to_string(), "target_file_missing")]
    );
    assert!(legacy.exists(), "B 不在，A 必须留着");
    assert!(!report.dir_removed);
}

// 名字不是 `<64 位 hex>.<扩展名>` 的（用户或别的程序放进来的）一律不碰。
#[tokio::test(flavor = "multi_thread")]
async fn files_in_the_legacy_dir_that_are_not_ours_are_kept() {
    let (l, _a, _rel, legacy) = library_with_legacy_copy().await;
    let dir = legacy.parent().unwrap().to_path_buf();
    fs::write(dir.join("notes.txt"), b"x").unwrap();
    fs::create_dir(dir.join("sub")).unwrap();
    let report = sweep_superseded_residue(&l.db, &l.root).await.unwrap();
    assert_eq!(report.removed, 1, "{report:?}");
    let mut reasons: Vec<_> = report.kept.iter().map(|(_, r)| *r).collect();
    reasons.sort();
    assert_eq!(reasons, vec!["not_a_file", "unrecognized_name"]);
    assert!(
        report.kept.iter().all(|(tag, _)| tag == "-"),
        "用户自己的文件名不进日志: {report:?}"
    );
    assert!(dir.join("notes.txt").exists());
    assert!(dir.join("sub").is_dir());
    assert!(!report.dir_removed);
}

/// 名字匹配的符号链接 / 目录链接不删（也不跟进去）。
/// 反证：把「不是普通文件就跳过」那条去掉 → 名字是指纹、别名在，链接被 `remove_file` 删掉，红。
#[tokio::test(flavor = "multi_thread")]
async fn a_link_in_the_superseded_dir_is_kept() {
    let (l, _a, _rel, legacy) = library_with_legacy_copy().await;
    let outside = l._dir.path().join("outside");
    fs::create_dir_all(&outside).unwrap();
    fs::remove_file(&legacy).unwrap();
    for kind in platform::test_support::dir_link_kinds() {
        if let Err(e) = kind.make(&outside, &legacy) {
            assert!(kind.may_need_privilege, "{}: {e}", kind.name);
            continue;
        }
        let report = sweep_superseded_residue(&l.db, &l.root).await.unwrap();
        assert_eq!(report.removed, 0, "{}: {report:?}", kind.name);
        assert_eq!(report.kept, vec![("-".to_string(), "not_a_file")]);
        assert!(fs::symlink_metadata(&legacy).is_ok());
        assert!(outside.is_dir());
        // 下一种链接形态用同一个名字：先把这一个拆掉。
        let _ = fs::remove_dir(&legacy).or_else(|_| fs::remove_file(&legacy));
    }
}

// ── #1183：apply_supersede 出错路径当场删自己的 staged ─────────────────────────────

fn staging_files(root: &Path) -> Vec<String> {
    let dir = root.join(SUPERSEDE_STAGING_DIR);
    let Ok(rd) = fs::read_dir(dir) else {
        return Vec::new();
    };
    rd.map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

/// 索引事务报错（这里用「B 的指纹已被另一行占着」触发主键冲突）：整体回滚、没有待换记录，
/// staged 当场删掉，库里一切照旧。
/// 反证：去掉 `supersede_asset` 出错分支里的 `remove_file` → staged 留下，红。
#[tokio::test(flavor = "multi_thread")]
async fn a_failed_index_transaction_removes_its_staged_file() {
    let l = lib().await;
    let (original, redacted) = (
        fixture("jpeg.jpg", "original"),
        fixture("jpeg.jpg", "redacted"),
    );
    let rel = ingest_redacted(&l, "jpeg.jpg", &redacted).await;
    let (a, b) = (h(&redacted), h(&original));
    let SupersedeCheck::Ready(plan) = l.ing.plan_supersede(&a, &b, &DEV_A).await.unwrap() else {
        panic!("expected Ready")
    };
    // 故障注入：另一行已经用了 B 的指纹 ⇒ 事务里 INSERT 撞主键。
    let blocker = storage::Asset {
        hash: b.to_vec(),
        rel_path: "originals/elsewhere.jpg".into(),
        ..l.db.get_asset(&a).await.unwrap().unwrap()
    };
    l.db.insert_asset(&blocker).await.unwrap();

    let out = l
        .ing
        .apply_supersede(
            &plan,
            &b,
            original.len() as u64,
            &pieces_for(&plan.ranges, &original),
            1,
        )
        .await;
    assert!(out.is_err(), "事务应当失败: {out:?}");
    assert_eq!(
        staging_files(&l.root),
        Vec::<String>::new(),
        "staged 当场删掉"
    );
    assert!(l.db.pending_swaps().await.unwrap().is_empty());
    assert_eq!(fs::read(l.root.join(&rel)).unwrap(), redacted, "A 不动");
    assert!(
        l.db.get_asset(&a).await.unwrap().is_some(),
        "旧行还在（回滚）"
    );
}

// ── #1183：supersede-staging 里没人要的 staged 由残留清扫删 ─────────────────────────

fn staged(root: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    let p = root.join(SUPERSEDE_STAGING_DIR).join(name);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(&p, bytes).unwrap();
    p
}

/// 事务提交前崩溃留下的（旧版命名 `<hex>.part` 与别的进程的 `<hex>-<pid>.part`）：删。
/// 反证：清扫函数什么都不删 → 本条红。
#[tokio::test(flavor = "multi_thread")]
async fn orphan_staged_files_from_an_earlier_run_are_removed() {
    let l = lib().await;
    let other = std::process::id().wrapping_add(1);
    let old_style = staged(&l.root, &format!("{}.part", hex(&[1; 32])), b"12345");
    let other_pid = staged(&l.root, &format!("{}-{other}.part", hex(&[2; 32])), b"678");
    let report = sweep_supersede_staging(&l.db, &l.root).await.unwrap();
    assert_eq!(report.removed, 2, "{report:?}");
    assert_eq!(report.freed_bytes, 8);
    assert!(report.kept.is_empty(), "{report:?}");
    assert!(!old_style.exists() && !other_pid.exists());
    assert!(l.root.join(SUPERSEDE_STAGING_DIR).is_dir(), "目录本身不删");
}

/// 有待换记录的（按 staged_path 或按新指纹认）留给 finish_pending_swaps，不删。
/// 反证：去掉 `swap_pending` 判据 → 两份都被删，补完就没东西可换了，红。
#[tokio::test(flavor = "multi_thread")]
async fn staged_files_with_a_pending_swap_are_kept() {
    let l = lib().await;
    let (original, redacted) = (
        fixture("jpeg.jpg", "original"),
        fixture("jpeg.jpg", "redacted"),
    );
    ingest_redacted(&l, "jpeg.jpg", &redacted).await;
    let (a, b) = (h(&redacted), h(&original));
    let other = std::process::id().wrapping_add(1);
    let name = format!("{}-{other}.part", hex(&b));
    let by_path = staged(&l.root, &name, &original);
    // 同一个新指纹、别的名字（例如旧版命名）：按新指纹也认作有主。
    let by_hash = staged(&l.root, &format!("{}.part", hex(&b)), &original);
    let asset = l.db.get_asset(&a).await.unwrap().unwrap();
    l.db.supersede_asset(
        &a,
        &storage::Asset {
            hash: b.to_vec(),
            ..asset
        },
        &format!("{SUPERSEDE_STAGING_DIR}/{name}"),
        1,
    )
    .await
    .unwrap();
    let report = sweep_supersede_staging(&l.db, &l.root).await.unwrap();
    assert_eq!(report.removed, 0, "{report:?}");
    let tag = hex(&b)[..8].to_string();
    assert_eq!(
        report.kept,
        vec![(tag.clone(), "swap_pending"), (tag, "swap_pending")]
    );
    assert!(by_path.exists() && by_hash.exists());
}

/// 本进程写的（pid = 自己）可能正在拼接、事务还没提交：不删。
/// 反证：去掉 `in_flight` 判据 → 被删，红。
#[tokio::test(flavor = "multi_thread")]
async fn a_staged_file_of_this_process_is_in_flight_and_kept() {
    let l = lib().await;
    let me = std::process::id();
    let mine = staged(&l.root, &format!("{}-{me}.part", hex(&[3; 32])), b"x");
    let report = sweep_supersede_staging(&l.db, &l.root).await.unwrap();
    assert_eq!(report.removed, 0);
    assert_eq!(report.kept, vec![("03030303".to_string(), "in_flight")]);
    assert!(mine.exists());
}

/// 名字不是我们的命名、或不是普通文件（子目录、链接）：一律不碰，日志不带名字。
/// 反证：把名字判据放宽成「以 .part 结尾」→ 前几个被删，红；去掉「不是普通文件就跳过」→ 链接被删，红。
#[tokio::test(flavor = "multi_thread")]
async fn unrecognized_names_dirs_and_links_in_staging_are_kept() {
    let l = lib().await;
    let h64 = hex(&[0xab; 32]);
    let keep = [
        staged(&l.root, "notes.part", b"x"),
        staged(&l.root, &format!("{h64}.part.bak"), b"x"),
        staged(&l.root, &format!("{}.part", h64.to_uppercase()), b"x"),
        staged(&l.root, &format!("{h64}-abc.part"), b"x"),
        staged(&l.root, &format!("{h64}-.part"), b"x"),
        staged(&l.root, &format!("{}.part", &h64[..62]), b"x"),
        staged(&l.root, &h64, b"x"),
    ];
    let sub = l
        .root
        .join(SUPERSEDE_STAGING_DIR)
        .join(format!("{}.part", hex(&[5; 32])));
    fs::create_dir_all(&sub).unwrap();
    fs::write(sub.join("inner"), b"x").unwrap();
    let outside = l._dir.path().join("outside");
    fs::create_dir_all(&outside).unwrap();
    let mut links = Vec::new();
    for kind in platform::test_support::dir_link_kinds() {
        let link = l
            .root
            .join(SUPERSEDE_STAGING_DIR)
            .join(format!("{}-1.part", hex(&[6; 32])));
        if let Err(e) = kind.make(&outside, &link) {
            assert!(kind.may_need_privilege, "{}: {e}", kind.name);
            continue;
        }
        links.push(link);
        break;
    }
    let report = sweep_supersede_staging(&l.db, &l.root).await.unwrap();
    assert_eq!(report.removed, 0, "{report:?}");
    assert!(report.kept.iter().all(|(tag, _)| tag == "-"), "{report:?}");
    for p in keep.iter().chain(links.iter()) {
        assert!(fs::symlink_metadata(p).is_ok(), "不该被删：{}", p.display());
    }
    assert!(sub.join("inner").exists(), "不递归删目录");
}
