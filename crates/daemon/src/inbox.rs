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
//! ## staging 的清理规则（2026-08-21 裁决反转，见 MOB-32）
//!
//! 两类东西：
//!
//! - `*.upload` —— 半成品。上传协议没有 offset/resume 字段
//!   （`UploadHeader` 只有 hash/bytes/file_name），`File::create` 直接截断，
//!   断了从来都是整个文件重传。所以半成品一律无用，见 `sweep_partial_uploads`。
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
//! 启动时传**空保护集**：会话是内存态，重启后一个都不剩，此刻任何裸文件
//! 都无人认领。代价是崩溃重启后可能多传一次——**正确性优先于带宽**，这正是
//! 旧裁决权衡错的地方。

use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

/// 清空 blob store 目录、扫掉 staging 里的半成品与孤儿。返回释放的字节数。
///
/// 启动专用：`protected` 恒为空集，因为会话是内存态，重启后没有任何裸文件
/// 还有主（理由见模块文档）。运行期的定期回收走
/// `BackupEngine::reclaim_staging`，那边会带上活会话的保护集。
///
/// 失败一律吞掉并返回已释放的量：**回收是维护动作，不是业务逻辑**——
/// 磁盘权限、文件被占用之类的问题绝不能让 daemon 起不来。
pub fn reclaim_inbox(blobs_dir: &Path, staging_dir: &Path, grace: Duration) -> u64 {
    let mut freed = dir_size(blobs_dir);
    if freed > 0 || blobs_dir.exists() {
        // 整个删掉；store 会在 open 时自己重建目录结构。
        if std::fs::remove_dir_all(blobs_dir).is_err() {
            freed = 0; // 没删成，别虚报
        }
    }
    freed + sweep_partial_uploads(staging_dir) + sweep_orphans(staging_dir, &HashSet::new(), grace)
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
        let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
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

fn dir_size(dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .map(|e| {
            let p = e.path();
            if p.is_dir() {
                dir_size(&p)
            } else {
                e.metadata().map(|m| m.len()).unwrap_or(0)
            }
        })
        .sum()
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

    #[test]
    fn reclaim_empties_the_blob_store_and_reports_the_bytes() {
        let root = tmp("reclaim");
        let blobs = root.join("blobs");
        let staging = root.join("staging");
        std::fs::create_dir_all(blobs.join("nested")).unwrap();
        std::fs::create_dir_all(&staging).unwrap();
        std::fs::write(blobs.join("a"), b"0123456789").unwrap(); // 10
        std::fs::write(blobs.join("nested/b"), b"01234").unwrap(); // 5
        std::fs::write(staging.join("x.upload"), b"012").unwrap(); // 3
        std::fs::write(staging.join("keep"), b"keepme").unwrap();

        // 宽限期给足：刚落地的成品不许被当成孤儿。
        let freed = reclaim_inbox(&blobs, &staging, Duration::from_secs(3600));
        assert_eq!(freed, 18, "blob store 全部 + staging 半成品");
        assert!(!blobs.exists(), "收件箱必须整个清掉");
        assert!(
            staging.join("keep").exists(),
            "落地不足宽限期的成品不许被回收"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    /// MOB-32：启动回收要把**存量孤儿**清掉——真机上那 547MB 就是这批。
    #[test]
    fn reclaim_sweeps_orphans_past_the_grace_window() {
        let root = tmp("orphan-startup");
        let blobs = root.join("blobs");
        let staging = root.join("staging");
        std::fs::create_dir_all(&staging).unwrap();
        std::fs::write(staging.join("orphan"), b"0123456789").unwrap(); // 10

        // grace = 0 → 落地即过期。启动时保护集恒为空（会话是内存态）。
        let freed = reclaim_inbox(&blobs, &staging, Duration::ZERO);
        assert_eq!(freed, 10, "存量孤儿必须被回收并如实报数");
        assert!(!staging.join("orphan").exists());
        std::fs::remove_dir_all(&root).ok();
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

    #[test]
    fn reclaim_on_a_clean_slate_is_a_noop() {
        let root = tmp("clean");
        let freed = reclaim_inbox(&root.join("nope"), &root.join("also-nope"), Duration::ZERO);
        assert_eq!(0, freed, "首次启动/目录不存在时不许虚报");
        std::fs::remove_dir_all(&root).ok();
    }
}
