//! BLOB-01: 收件箱回收。
//!
//! ## 为什么需要它
//!
//! 照片从手机到照片库要过三个地方：
//!
//! ```text
//! 手机推 ──▶ .ppf/staging/<hash>   边写边算 BLAKE3，自己比对（收件）
//!        ──▶ originals/…/<file>    rename 进库（归档）
//! ```
//!
//! 归档之后，staging 那份已经被 rename 走了（同卷零拷贝）。**但在 BLOB-01
//! 之前，中间还硬插了一个 blob store**：上传平面把校验过的文件再拷进
//! `.ppf/blobs`，commit 时又拷回来。同一份字节拷三遍，而 blob store 那份
//! **永不回收**。用户机器实测：
//!
//! ```text
//! originals   549M   ← 照片库
//! .ppf/blobs  554M   ← 同一批照片的第二份
//! 合计        1.1G   → 占盘 = 照片本身的 2.05 倍
//! ```
//!
//! 用户定调："收到文件，文件都已经保存好了，我们就没必要在收件箱里面保留
//! 这个文件了吧……它的独立功能就只有一项，一个是收件，一个是中转。"
//!
//! 主路径已经改成不进 blob store（见 `upload.rs` / `backup.rs`）。本模块
//! 负责**清掉存量**，以及每次启动扫掉上个会话的残渣。
//!
//! ## 为什么敢在启动时整个清空 blob store
//!
//! blob store 现在只服务回退路径（T-032：daemon 主动向手机拉取），而
//! **启动这一刻不可能有传输在飞**——所以里面剩的一定是上个会话的垃圾。
//!
//! 这条路也是唯一可行的：iroh-blobs 0.103 的单个 blob `delete` 是
//! `pub(crate)`，文档明说 "Users should rely only on garbage collection for
//! blob deletion"，而 `gc_run_once` 所在的 `store::gc` 模块是 crate 私有的
//! （`mod gc;`），`GcConfig` 只能配成定时轮询。与其把回收时机交给一个我们
//! 控制不了的定时器，不如在一个**可证明安全**的时刻（启动，无传输在飞）
//! 自己动手。
//!
//! 代价：回退路径若被打断，拉到一半的部分数据不能跨重启续传。可接受——
//! 那条路按 commit 批次重试，最多重拉一个文件。
//!
//! #1183 起「清空」分两步：启动时 [`retire_blob_store`] 只把整个目录 rename 进回收目录
//! （O(1)，不拖慢启动），删除由库残留清扫（`residue`，类别 `blobs-retired`）后台做。
//!
//! ## staging 的清理规则（2026-08-21 裁决反转，见 MOB-32）
//!
//! 两类东西：
//!
//! - `*.upload` —— 半成品。旧上传通道（`ppf/upload/1`，#988 已移除）的
//!   协议头只有 hash/bytes/file_name，没有 offset/resume，断了从来都是整个
//!   文件重传。所以半成品一律无用，升级上来的机器上可能还留着，见
//!   `sweep_partial_uploads`。
//! - 不带后缀的 `<hash>` —— 校验通过、等着 ingest 的。**有主的留，没主的收**，
//!   见 `sweep_orphans`。
//!
//! ### BLOB-01 原来的裁决是「裸文件一律保留」，它破产了
//!
//! 原话（本文件旧注释）：「哪怕它的会话早就断了，下一轮备份手机会重新 offer
//! 同一个 hash，commit 时直接吃这份现成的，省一次上传。」
//!
//! 这条推理有一个**没被验证的前提**：手机一定会再 offer 一次。而 MOB-32 的
//! 事故恰恰打掉了这个前提——commit 在会话被顶掉后报了个假的 `ok`，手机把
//! 那 186 张全标记成「已备份」，**从此再也不会 offer**。于是 547MB 的裸文件
//! 成了永久孤儿：不在索引里、没人认领、回收判据也碰不到（只认 `.upload`）。
//!
//! BLOB-01 把 `.ppf/blobs` 压到了 0，泄漏点原地搬到了 staging。
//!
//! ### 现在的判据
//!
//! 一个裸文件是孤儿，当且仅当：
//!
//! 1. 没有**活会话**声明过它的 hash（保护集由 `BackupEngine` 提供——正在
//!    ingest 的、等 commit 兜底的都在里面）；且
//! 2. 落地已经超过 `grace`（覆盖「刚 rename 完还没轮到 ingest」以及
//!    「manifest 比上传晚到」这两个窄窗口）。
//!
//! #1183 起启动时也不再传空保护集：staging 回收并入库残留统一清扫
//! （`residue::ResidueSweeper`），在 daemon 开始服务之后后台跑，那时可能已有
//! 会话，所以启动那一轮与每小时那一轮一样带上活会话的保护集
//! （`BackupEngine::staging_claims`）。重启后会话表为空，结果与原先相同。

use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

/// NET-20: `.ppf/flow-staging` 是 Flow 单通道（`flow_delivery.rs`）导出
/// 中转文件落盘的目录——`export_to(hash, &staged)` 把字节从
/// `.ppf/flow-blobs`（iroh 自管、有自己的周期 GC）复制成普通文件之后，
/// 才能喂给 `Ingestor::ingest`。这份复制品从落盘那一刻起就跟 iroh 的 GC
/// 无关了：iroh 只认自己仓库里的哈希，看不见这道门外的中转文件。
///
/// 只有"成功 ingest（含判重）"这一条路径会删它
/// （`flow_delivery.rs` 的 `Ok(_)` 分支）。ingest 真失败、或
/// materialize 中途被 cancel（`require_active` 提前返回 `Err`）、或
/// daemon 在这两步之间崩溃，文件都会原地留下——没有任何定时任务扫过
/// 这个目录，是复用旧上传收件箱（`sweep_orphans`）这套机制时漏掉的
/// 第二个装卸台，跟 MOB-32 是同一类根因（有主的留，没主的收），只是
/// 发生在新管线里。
///
/// 文件名形如 `{node_hex}-{queue_sequence}-{content_hash_hex}`
/// （见 `FlowDelivery::staged_path`）。"有主"的判据是：文件名里的
/// content_hash 命中 `protected`（`Db::active_flow_content_hashes()`——
/// 当前仍是 Active 状态的 Flow grant，与 iroh GC 保护集同一份数据来源,
/// 是持久表而非内存态，所以启动时和运行期都能查真值,不必像旧会话那样
/// 在启动时把保护集当成空集）。
pub fn sweep_flow_staging_orphans(
    staging_dir: &Path,
    protected: &HashSet<[u8; 32]>,
    grace: Duration,
) -> u64 {
    let protected_hex: HashSet<String> = protected.iter().map(hex::encode).collect();
    let mut freed = 0u64;
    let Ok(entries) = std::fs::read_dir(staging_dir) else {
        return 0;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let Some(hash_hex) = flow_staged_file_hash_hex(name) else {
            continue; // 命名对不上契约，不在本函数职责内，宁可漏收
        };
        if protected_hex.contains(hash_hex) {
            continue;
        }
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let aged = meta
            .modified()
            .ok()
            .and_then(|m| m.elapsed().ok())
            .map(|age| age >= grace)
            .unwrap_or(false); // 读不出时间就别删——宁可漏收，不可误删
        if !aged {
            continue;
        }
        let size = meta.len();
        if std::fs::remove_file(&path).is_ok() {
            freed += size;
            tracing::info!("NET-20: 回收 flow-staging 孤儿 {name}（{size} 字节）");
        }
    }
    freed
}

/// 从 `{node_hex}-{queue_sequence}-{content_hash_hex}` 里取出最后一段
/// （content_hash 是 32 字节 BLAKE3 → 64 hex 字符，且 hex 字母表里没有
/// `-`，取最后一个 `-` 之后的部分永远是它，与 queue_sequence 的位数无关）。
/// 纯函数，单测直接覆盖；名字不合契约（例如遗留/损坏文件）一律返回
/// `None`，调用方按"不认识，不碰"处理。
fn flow_staged_file_hash_hex(name: &str) -> Option<&str> {
    let hash_hex = name.rsplit_once('-').map(|(_, tail)| tail)?;
    (hash_hex.len() == 64 && hash_hex.bytes().all(|b| b.is_ascii_hexdigit())).then_some(hash_hex)
}

/// 回收目录的名字前缀：`.ppf/blobs-retired-<pid>-<纳秒>`（#1183）。
pub const RETIRED_BLOBS_PREFIX: &str = "blobs-retired-";

/// [`retire_blob_store`] 做了什么（给日志用，不带路径）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlobStoreRetire {
    /// 没有 `.ppf/blobs`（首次启动 / 上次已收走）。
    Absent,
    /// 已整个 rename 进回收目录，等后台删。
    Retired,
    /// `.ppf/blobs` 不是真目录（符号链接 / 文件）：不碰。
    NotADir,
    /// rename 失败：原样留着，store 照常打开（只是旧内容没收走）。
    RenameFailed,
}

/// 启动时把回退路径的 blob store（`.ppf/blobs`）整个 rename 到同一 `.ppf/` 下的回收目录
/// `blobs-retired-<pid>-<纳秒>`，O(1)、与里面有多少东西无关；真正的删除由库残留清扫
/// （`residue`，类别 `blobs-retired`）在启动就绪之后后台做。
///
/// 必须在 `Blobs::open` **之前**：store 一旦打开，目录就归 iroh 管（单个 blob 的 delete
/// 不对外，见模块文档），只能趁它关着时整个挪走。**启动这一刻不可能有传输在飞**，所以
/// 里面剩的一定是上个会话的垃圾。
///
/// 失败一律只回报、不报错：**回收是维护动作，不是业务逻辑**——磁盘权限、文件被占用之类的
/// 问题绝不能让 daemon 起不来。
pub fn retire_blob_store(blobs_dir: &Path) -> BlobStoreRetire {
    let meta = match std::fs::symlink_metadata(blobs_dir) {
        Ok(m) => m,
        Err(_) => return BlobStoreRetire::Absent,
    };
    if !meta.is_dir() {
        return BlobStoreRetire::NotADir;
    }
    let Some(parent) = blobs_dir.parent() else {
        return BlobStoreRetire::RenameFailed;
    };
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let target = parent.join(format!(
        "{RETIRED_BLOBS_PREFIX}{}-{nanos}",
        std::process::id()
    ));
    match std::fs::rename(blobs_dir, &target) {
        Ok(()) => BlobStoreRetire::Retired,
        Err(_) => BlobStoreRetire::RenameFailed,
    }
}

/// `blobs-retired-<十进制>-<十进制>` 才是我们的回收目录名。
pub fn is_retired_blobs_name(name: &str) -> bool {
    name.strip_prefix(RETIRED_BLOBS_PREFIX)
        .and_then(|rest| rest.split_once('-'))
        .is_some_and(|(pid, ns)| {
            !pid.is_empty()
                && !ns.is_empty()
                && pid.bytes().all(|b| b.is_ascii_digit())
                && ns.bytes().all(|b| b.is_ascii_digit())
        })
}

/// #1183：删掉 `ppf_dir` 下所有回收目录（[`retire_blob_store`] 挪过去的旧 blob store）。
/// 返回 (删掉几个, 释放字节, 保留的原因)。
///
/// 判据：`ppf_dir` 的直接子项、名字严格是 `blobs-retired-<数字>-<数字>`、是真目录（不是
/// 符号链接）。满足就整个删——这是清单里**唯一**整目录删除的一类（owner 2026-10-26 定：
/// 目录内容是 iroh store 的内部文件，整份都是我们的；改名之后再没有任何人打开它）。
/// `remove_dir_all` 不跟随里面的符号链接（std 自 1.58 起），只删链接本身。
pub fn sweep_retired_blob_stores(ppf_dir: &Path) -> (u64, u64, Vec<&'static str>) {
    let (mut removed, mut freed, mut kept) = (0u64, 0u64, Vec::new());
    let Ok(entries) = std::fs::read_dir(ppf_dir) else {
        return (0, 0, kept);
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with(RETIRED_BLOBS_PREFIX) {
            continue; // `.ppf` 里别的东西不归这一类
        }
        if !is_retired_blobs_name(&name) {
            kept.push("unrecognized_name");
            continue;
        }
        if !entry.file_type().is_ok_and(|t| t.is_dir()) {
            kept.push("not_a_dir");
            continue;
        }
        let size = tree_size_no_follow(&entry.path());
        match std::fs::remove_dir_all(entry.path()) {
            Ok(()) => {
                removed += 1;
                freed += size;
            }
            Err(_) => kept.push("remove_failed"),
        }
    }
    (removed, freed, kept)
}

/// 目录树里普通文件的总字节（不跟随符号链接）。
fn tree_size_no_follow(dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => tree_size_no_follow(&e.path()),
            Ok(t) if t.is_file() => e.metadata().map(|m| m.len()).unwrap_or(0),
            _ => 0,
        })
        .sum()
}

/// MOB-32：扫掉 staging 里的**孤儿**——已校验落地（裸文件名 = hash）但
/// 没有任何活会话认领、且落地已超过 `grace` 的那些。返回释放的字节数。
///
/// 三道保护，缺一个都会误删用户的照片：
///
/// - 带后缀的一概不碰（`.upload` 是正在写的半成品，归 `sweep_partial_uploads`）
/// - `protected` 里的 hash 一概不碰（活会话声明过：可能正在 ingest，
///   也可能在等 commit 兜底）
/// - 落地不足 `grace` 的一概不碰（rename 完成到 ingest 之间那一瞬，
///   以及 manifest 比上传晚到的窄窗口）
pub fn sweep_orphans(staging_dir: &Path, protected: &HashSet<String>, grace: Duration) -> u64 {
    let mut freed = 0u64;
    let Ok(entries) = std::fs::read_dir(staging_dir) else {
        return 0;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        // 带后缀 = 不是「校验通过的成品」，不在本函数职责内。
        if path.extension().is_some() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if protected.contains(name) {
            continue;
        }
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let aged = meta
            .modified()
            .ok()
            .and_then(|m| m.elapsed().ok())
            .map(|age| age >= grace)
            .unwrap_or(false); // 读不出时间就别删——宁可漏收，不可误删
        if !aged {
            continue;
        }
        let size = meta.len();
        if std::fs::remove_file(&path).is_ok() {
            freed += size;
            tracing::info!("MOB-32: 回收 staging 孤儿 {name}（{size} 字节）");
        }
    }
    freed
}

/// 只删半成品（`.upload` 后缀）。完整的 `<hash>` 文件一律保留。
pub fn sweep_partial_uploads(staging_dir: &Path) -> u64 {
    let mut freed = 0u64;
    let Ok(entries) = std::fs::read_dir(staging_dir) else {
        return 0;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !is_partial_upload(&path) {
            continue;
        }
        // #1183：只删普通文件——同名的符号链接、目录不碰（metadata 不跟随链接）。
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let size = meta.len();
        if std::fs::remove_file(&path).is_ok() {
            freed += size;
        }
    }
    freed
}

/// 半成品判据。**纯函数**，单测直接覆盖。
///
/// 只认 `.upload` 后缀——那是上传平面写盘中的临时名，校验通过才原地 rename
/// 成不带后缀的 `<hash>`。判据写死在这里，与 `upload.rs` 的命名是一份契约：
/// 那边改了后缀这边必须跟着改，否则半成品会被当成可 ingest 的完整文件。
pub fn is_partial_upload(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()) == Some("upload")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("ppass-inbox-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn partial_uploads_are_recognised_by_suffix() {
        assert!(is_partial_upload(Path::new("/x/abc123.upload")));
        // 不带后缀 = 校验通过、等 ingest。绝不能误判成垃圾。
        assert!(!is_partial_upload(Path::new("/x/abc123")));
        assert!(!is_partial_upload(Path::new("/x/abc123.jpg")));
    }

    #[test]
    fn sweep_keeps_verified_files_and_drops_partials() {
        let d = tmp("sweep");
        std::fs::write(d.join("aa.upload"), b"partial-1").unwrap();
        std::fs::write(d.join("bb.upload"), b"partial-22").unwrap();
        // 校验通过的成品——**半成品扫描**不许碰它（它的去留归
        // `sweep_orphans` 判，判据是有没有主 + 落地多久）。
        std::fs::write(d.join("cc"), b"verified").unwrap();

        let freed = sweep_partial_uploads(&d);
        assert_eq!(freed, 9 + 10, "释放量必须是两个半成品的实际字节数");
        assert!(!d.join("aa.upload").exists());
        assert!(!d.join("bb.upload").exists());
        assert!(d.join("cc").exists(), "半成品扫描不许碰已校验的成品");
        std::fs::remove_dir_all(&d).ok();
    }

    /// #1183：启动时只 rename（O(1)），不删；删由后台清扫做，并如实报字节。
    #[test]
    fn the_blob_store_is_retired_by_rename_and_swept_later() {
        let ppf = tmp("retire");
        let blobs = ppf.join("blobs");
        std::fs::create_dir_all(blobs.join("nested")).unwrap();
        std::fs::write(blobs.join("a"), b"0123456789").unwrap(); // 10
        std::fs::write(blobs.join("nested/b"), b"01234").unwrap(); // 5

        assert_eq!(retire_blob_store(&blobs), BlobStoreRetire::Retired);
        assert!(!blobs.exists(), "原位置空出来，store 打开时重建");
        let retired: Vec<_> = std::fs::read_dir(&ppf)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(retired.len(), 1);
        assert!(is_retired_blobs_name(&retired[0]), "{retired:?}");

        let (removed, freed, kept) = sweep_retired_blob_stores(&ppf);
        assert_eq!((removed, freed), (1, 15), "{kept:?}");
        assert!(std::fs::read_dir(&ppf).unwrap().next().is_none());
        assert_eq!(retire_blob_store(&blobs), BlobStoreRetire::Absent);
        std::fs::remove_dir_all(&ppf).ok();
    }

    /// `.ppf/blobs` 是符号链接：不挪、不删、不跟进去。
    /// 反证：把 `symlink_metadata` 换成 `metadata`（跟随链接）→ 链接被挪走，红。
    #[test]
    fn a_linked_blob_store_is_left_alone() {
        let ppf = tmp("retire-link");
        let outside = tmp("retire-link-outside");
        std::fs::write(outside.join("keep"), b"x").unwrap();
        for kind in platform::test_support::dir_link_kinds() {
            let link = ppf.join("blobs");
            if let Err(e) = kind.make(&outside, &link) {
                assert!(kind.may_need_privilege, "{}: {e}", kind.name);
                continue;
            }
            assert_eq!(retire_blob_store(&link), BlobStoreRetire::NotADir);
            assert!(std::fs::symlink_metadata(&link).is_ok());
            assert!(outside.join("keep").exists());
            break;
        }
        std::fs::remove_dir_all(&ppf).ok();
        std::fs::remove_dir_all(&outside).ok();
    }

    /// 回收目录的判据：名字严格匹配、是真目录；`.ppf` 里别的东西（含名字相近的、链接）一律不碰，
    /// 链接指向的东西也不碰。
    /// 反证：把 `is_retired_blobs_name` 放宽成只看前缀 → `blobs-retired-x` 被删，红；
    /// 去掉 `is_dir` 判断（链接也删）→ 链接被删，红。
    #[test]
    fn retired_sweep_only_takes_our_directories() {
        let ppf = tmp("retired-guards");
        let outside = tmp("retired-guards-outside");
        std::fs::write(outside.join("keep"), b"x").unwrap();
        let keep = [
            ppf.join("blobs"),
            ppf.join("flow-blobs"),
            ppf.join("blobs-retired-x"),
            ppf.join("blobs-retired-1"),
            ppf.join("blobs-retired--1"),
        ];
        for d in &keep {
            std::fs::create_dir_all(d.join("inner")).unwrap();
        }
        std::fs::write(ppf.join("blobs-retired-2-3"), b"a file, not a dir").unwrap();
        let mut links = Vec::new();
        for kind in platform::test_support::dir_link_kinds() {
            let link = ppf.join("blobs-retired-4-5");
            if let Err(e) = kind.make(&outside, &link) {
                assert!(kind.may_need_privilege, "{}: {e}", kind.name);
                continue;
            }
            links.push(link);
            break;
        }
        let (removed, _, mut kept) = sweep_retired_blob_stores(&ppf);
        assert_eq!(removed, 0, "{kept:?}");
        kept.sort();
        let mut want = vec![
            "not_a_dir",
            "unrecognized_name",
            "unrecognized_name",
            "unrecognized_name",
        ];
        if !links.is_empty() {
            want.push("not_a_dir");
        }
        want.sort();
        assert_eq!(kept, want);
        for d in &keep {
            assert!(d.join("inner").is_dir(), "{}", d.display());
        }
        assert!(ppf.join("blobs-retired-2-3").is_file());
        for l in &links {
            assert!(std::fs::symlink_metadata(l).is_ok());
        }
        assert!(outside.join("keep").exists(), "链接指向的东西不碰");
        std::fs::remove_dir_all(&ppf).ok();
        std::fs::remove_dir_all(&outside).ok();
    }

    /// #1183：同名的符号链接 / 目录不是半成品，不碰。
    /// 反证：去掉 `meta.is_file()` 判断 → 链接被删，红。
    #[test]
    fn partial_upload_sweep_leaves_links_and_dirs_alone() {
        let d = tmp("partial-links");
        let outside = tmp("partial-links-outside");
        std::fs::create_dir_all(d.join("dir.upload")).unwrap();
        let mut links = Vec::new();
        for kind in platform::test_support::dir_link_kinds() {
            let link = d.join(format!("{}.upload", kind.name));
            if let Err(e) = kind.make(&outside, &link) {
                assert!(kind.may_need_privilege, "{}: {e}", kind.name);
                continue;
            }
            links.push(link);
        }
        assert_eq!(sweep_partial_uploads(&d), 0);
        assert!(d.join("dir.upload").is_dir());
        for l in &links {
            assert!(std::fs::symlink_metadata(l).is_ok(), "{}", l.display());
        }
        std::fs::remove_dir_all(&d).ok();
        std::fs::remove_dir_all(&outside).ok();
    }

    /// 三道保护逐条：有主的不碰、没过宽限期的不碰、带后缀的不碰。
    #[test]
    fn orphan_sweep_respects_every_guard() {
        let d = tmp("orphan-guards");
        std::fs::write(d.join("mine"), b"claimed").unwrap();
        std::fs::write(d.join("nobodys"), b"orphaned!").unwrap(); // 9
        std::fs::write(d.join("half.upload"), b"partial").unwrap();

        let protected: HashSet<String> = ["mine".to_string()].into_iter().collect();
        let freed = sweep_orphans(&d, &protected, Duration::ZERO);

        assert_eq!(freed, 9, "只该收走那一个没主的");
        assert!(d.join("mine").exists(), "活会话声明过的 hash 一个都不能动");
        assert!(!d.join("nobodys").exists());
        assert!(
            d.join("half.upload").exists(),
            "带后缀的不在孤儿扫描职责内（归 sweep_partial_uploads）"
        );

        // 宽限期未到 → 连没主的也不许动。
        std::fs::write(d.join("just-landed"), b"fresh").unwrap();
        assert_eq!(
            0,
            sweep_orphans(&d, &HashSet::new(), Duration::from_secs(3600)),
            "落地不足宽限期的裸文件一律保留"
        );
        assert!(d.join("just-landed").exists());
        std::fs::remove_dir_all(&d).ok();
    }

    // ── NET-20: flow-staging 孤儿回收 ──────────────────────────────

    #[test]
    fn flow_staged_file_hash_hex_extracts_the_trailing_64_hex_segment() {
        let hash = "ab".repeat(32);
        let name = format!("deadbeef-7-{hash}");
        assert_eq!(flow_staged_file_hash_hex(&name), Some(hash.as_str()));
        // 命名对不上契约（截断、缺段、非 hex）一律 None，不误删。
        assert_eq!(
            flow_staged_file_hash_hex("no-dashes-at-all-but-short"),
            None
        );
        assert_eq!(
            flow_staged_file_hash_hex(&format!("only-{}", "zz".repeat(32))),
            None
        );
        assert_eq!(flow_staged_file_hash_hex("noseparatorhere"), None);
    }

    #[test]
    fn flow_staging_orphan_sweep_respects_every_guard() {
        let d = tmp("flow-staging-guards");
        let claimed_hash = [0x11u8; 32];
        let claimed_hex = hex::encode(claimed_hash);
        let orphan_hex = hex::encode([0x22u8; 32]);
        std::fs::write(d.join(format!("aa-1-{claimed_hex}")), b"claimed").unwrap();
        std::fs::write(d.join(format!("bb-2-{orphan_hex}")), b"orphaned!").unwrap(); // 9
        std::fs::write(d.join("garbage-name"), b"unrelated").unwrap();

        let protected: HashSet<[u8; 32]> = [claimed_hash].into_iter().collect();
        let freed = sweep_flow_staging_orphans(&d, &protected, Duration::ZERO);

        assert_eq!(freed, 9, "只该收走没有活 grant 认领的那一个");
        assert!(
            d.join(format!("aa-1-{claimed_hex}")).exists(),
            "活 grant 引用的 content_hash 一个都不能动"
        );
        assert!(!d.join(format!("bb-2-{orphan_hex}")).exists());
        assert!(
            d.join("garbage-name").exists(),
            "命名不合契约的文件不在本函数职责内，宁可漏收"
        );
        std::fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn flow_staging_orphan_sweep_respects_the_grace_window() {
        let d = tmp("flow-staging-grace");
        let hex = hex::encode([0x33u8; 32]);
        std::fs::write(d.join(format!("cc-3-{hex}")), b"just-landed").unwrap();

        assert_eq!(
            0,
            sweep_flow_staging_orphans(&d, &HashSet::new(), Duration::from_secs(3600)),
            "落地不足宽限期的裸文件一律保留，哪怕没有活 grant 认领"
        );
        assert!(d.join(format!("cc-3-{hex}")).exists());
        std::fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn flow_staging_orphan_sweep_on_missing_dir_is_a_noop() {
        let root = tmp("flow-staging-missing");
        assert_eq!(
            0,
            sweep_flow_staging_orphans(&root.join("nope"), &HashSet::new(), Duration::ZERO)
        );
        std::fs::remove_dir_all(&root).ok();
    }
}
