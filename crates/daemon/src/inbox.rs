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
//! ## staging 的清理规则更保守
//!
//! staging 里的东西**可能是有用的**（已经传完、校验过，只是还没 commit），
//! 所以只删**可证明是垃圾**的两类：
//!
//! - `*.upload` —— 半成品。上传协议没有 offset/resume 字段
//!   （`UploadHeader` 只有 hash/bytes/file_name），`File::create` 直接截断，
//!   断了从来都是整个文件重传。所以半成品一律无用。
//! - `*.tmp` 之类的其它中间物同理。
//!
//! 不带后缀的 `<hash>` 文件**一律保留**：它是校验通过、等着 ingest 的。
//! 哪怕它的会话早就断了，下一轮备份手机会重新 offer 同一个 hash，commit
//! 时直接吃这份现成的，省一次上传。真正的兜底是"整个 blob store 清空"，
//! staging 这边宁可留着。

use std::path::Path;

/// 清空 blob store 目录、扫掉 staging 里的半成品。返回释放的字节数。
///
/// 失败一律吞掉并返回已释放的量：**回收是维护动作，不是业务逻辑**——
/// 磁盘权限、文件被占用之类的问题绝不能让 daemon 起不来。
pub fn reclaim_inbox(blobs_dir: &Path, staging_dir: &Path) -> u64 {
    let mut freed = dir_size(blobs_dir);
    if freed > 0 || blobs_dir.exists() {
        // 整个删掉；store 会在 open 时自己重建目录结构。
        if std::fs::remove_dir_all(blobs_dir).is_err() {
            freed = 0; // 没删成，别虚报
        }
    }
    freed + sweep_partial_uploads(staging_dir)
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
        // 校验通过、等 ingest 的那份——必须留着（删了要重传一次）。
        std::fs::write(d.join("cc"), b"verified").unwrap();

        let freed = sweep_partial_uploads(&d);
        assert_eq!(freed, 9 + 10, "释放量必须是两个半成品的实际字节数");
        assert!(!d.join("aa.upload").exists());
        assert!(!d.join("bb.upload").exists());
        assert!(d.join("cc").exists(), "已校验的文件不许被扫掉");
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

        let freed = reclaim_inbox(&blobs, &staging);
        assert_eq!(freed, 18, "blob store 全部 + staging 半成品");
        assert!(!blobs.exists(), "收件箱必须整个清掉");
        assert!(staging.join("keep").exists(), "已校验的 staging 文件要留");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn reclaim_on_a_clean_slate_is_a_noop() {
        let root = tmp("clean");
        let freed = reclaim_inbox(&root.join("nope"), &root.join("also-nope"));
        assert_eq!(0, freed, "首次启动/目录不存在时不许虚报");
        std::fs::remove_dir_all(&root).ok();
    }
}
