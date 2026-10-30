//! #1260：老库（v2026.10.7 及以前）把服务数据放在库盘 `.ppf/` 里——升级后自动搬到本机。
//!
//! 先拷贝、再核对、最后一次同盘改名提交；提交之前绝不删任何旧数据：
//!
//! 1. 补库 ID（`.ppf/library-id`），记进本机；
//! 2. 本机空间预检（待迁数据量 × 1.2）；
//! 3. 拷到 `libraries/<id>.migrating/`：索引用 `VACUUM INTO`（一致的单文件，WAL 已合并）、
//!    两个 `blobs.db` 直接拷（此刻 store 都没打开）；缩略图不拷，提交后搬（见第 6 步）；
//! 4. 核对：拷出来的索引 `integrity_check` 为 ok、每张表行数与源库相同；
//! 5. 提交：`rename(<id>.migrating → <id>)`，同盘改名是原子的——这一步之后本机那份就是正本；
//! 6. 收尾：缩略图搬过去（同盘改名；跨盘拷完立刻删原件），库盘里的旧索引与两个 `blobs.db` 直接删——
//!    全程只留一份（占盘 1x）。
//!
//! 第 3、4 步失败或中途崩溃：删掉 `.migrating`，本次照旧用库盘里的老布局，下次启动重试——
//! 源数据一字未动。第 5 步之后、第 6 步之前崩溃：下次启动看到本机已有正本，只做第 6 步。

use std::path::{Path, PathBuf};

use crate::layout::{self, legacy, LibraryLayout};

/// 一次启动里本机数据的落定结果。
#[derive(Debug)]
pub enum Settled {
    /// 本机布局就绪（新库，或刚迁移完 / 早就迁移过）。
    Local(LibraryLayout),
    /// 这次没能迁移（空间不够 / 拷贝或核对失败）：照旧用库盘里的老布局，下次启动重试。
    Legacy {
        layout: LibraryLayout,
        reason: String,
    },
}

impl Settled {
    /// 这次启动用的布局。
    pub fn layout(&self) -> &LibraryLayout {
        match self {
            Settled::Local(l) | Settled::Legacy { layout: l, .. } => l,
        }
    }
}

/// 迁移过程中可注入失败的位置（只给测试用）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Copy,
    Verify,
    Commit,
    Cleanup,
}

/// 落定这个库的本机数据：必要时迁移。调用前须已确认库在（[`layout::library_presence`]）。
pub async fn settle(root: &Path, local_base: &Path) -> Settled {
    settle_with(root, local_base, free_bytes, |_| Ok(())).await
}

fn free_bytes(path: &Path) -> Option<u64> {
    use platform::PlatformAdapter as _;
    platform::adapter().volume_stats(path).map(|v| v.free)
}

/// [`settle`] 的可测版本：`free` 回答本机可用空间，`fail_at` 在指定步骤注入失败。
pub async fn settle_with(
    root: &Path,
    local_base: &Path,
    free: impl Fn(&Path) -> Option<u64>,
    fail_at: impl Fn(Step) -> std::io::Result<()>,
) -> Settled {
    let id = match layout::ensure_library_id(root) {
        Ok(id) => id,
        Err(e) => return legacy_with(root, format!("写库 ID 失败：{e}")),
    };
    if layout::recorded_library_id(local_base).as_deref() != Some(id.as_str()) {
        if let Err(e) = layout::record_library_id(local_base, &id) {
            return legacy_with(root, format!("记录库 ID 失败：{e}"));
        }
    }
    let target = layout::local_dir(local_base, &id);
    let done = LibraryLayout::new(root, local_base, &id);
    let legacy_index = legacy::index_db(root);
    if target.join("index.sqlite").exists() || !legacy_index.exists() {
        // 早就迁移过（只差收尾），或本来就是新库：本机布局就绪。
        if let Err(e) = std::fs::create_dir_all(&target) {
            return legacy_with(root, format!("建本机数据目录失败：{e}"));
        }
        if legacy_index.exists() || legacy::thumbs(root).exists() {
            move_thumbs(root, &target);
            cleanup(root, &fail_at);
        }
        return Settled::Local(done);
    }

    let need = legacy_bytes(root);
    if let Some(avail) = free(local_base) {
        if avail < need.saturating_mul(6) / 5 {
            return legacy_with(
                root,
                format!("本机可用空间不够（需要约 {need} 字节 × 1.2，可用 {avail}）"),
            );
        }
    }
    let staging = target.with_file_name(format!("{id}.migrating"));
    let _ = std::fs::remove_dir_all(&staging);
    match copy_and_verify(root, &staging, &fail_at).await {
        Ok(()) => {}
        Err(reason) => {
            let _ = std::fs::remove_dir_all(&staging);
            return legacy_with(root, reason);
        }
    }
    if let Err(e) = fail_at(Step::Commit).and_then(|()| std::fs::rename(&staging, &target)) {
        let _ = std::fs::remove_dir_all(&staging);
        return legacy_with(root, format!("提交失败：{e}"));
    }
    tracing::info!(
        "#1260: 服务数据已从照片库迁到本机（{}，约 {need} 字节）",
        target.display()
    );
    move_thumbs(root, &target);
    cleanup(root, &fail_at);
    Settled::Local(done)
}

/// 缩略图在提交之后搬过去，全程只有一份（占盘 1x）：同一块盘直接改名；不同盘先拷贝、拷完立刻删原件。
/// 失败只记日志——下次启动接着搬（拷贝可重来，同名同大小的跳过）；最坏是缩略图按需重建。
fn move_thumbs(root: &Path, target: &Path) {
    let from = legacy::thumbs(root);
    if !from.exists() {
        return;
    }
    let to = target.join("thumbs");
    if !to.exists() {
        match std::fs::rename(&from, &to) {
            Ok(()) => return,
            Err(e) if !platform::is_cross_volume_rename(&e) => {
                tracing::warn!("#1260: 缩略图没搬过去（{e}），下次启动再搬");
                return;
            }
            Err(_) => {}
        }
    }
    match copy_tree(&from, &to).and_then(|()| std::fs::remove_dir_all(&from)) {
        Ok(()) => {}
        Err(e) => tracing::warn!("#1260: 缩略图没搬完（{e}），下次启动接着搬"),
    }
}

fn legacy_with(root: &Path, reason: String) -> Settled {
    tracing::warn!("#1260: 本次没有迁移服务数据，照旧使用照片库里的老布局，下次启动重试：{reason}");
    Settled::Legacy {
        layout: LibraryLayout::legacy(root),
        reason,
    }
}

/// 待迁数据量（索引含 WAL、两个 blobs.db、缩略图）。
fn legacy_bytes(root: &Path) -> u64 {
    let mut files = vec![
        legacy::index_db(root),
        legacy::blobs_db(root),
        legacy::flow_blobs_db(root),
    ];
    for suffix in ["-wal", "-shm"] {
        let mut p = legacy::index_db(root).into_os_string();
        p.push(suffix);
        files.push(PathBuf::from(p));
    }
    let mut total: u64 = files
        .iter()
        .filter_map(|p| std::fs::metadata(p).ok())
        .map(|m| m.len())
        .sum();
    total += dir_bytes(&legacy::thumbs(root));
    total
}

fn dir_bytes(dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => dir_bytes(&e.path()),
            Ok(t) if t.is_file() => e.metadata().map(|m| m.len()).unwrap_or(0),
            _ => 0,
        })
        .sum()
}

async fn copy_and_verify(
    root: &Path,
    staging: &Path,
    fail_at: &impl Fn(Step) -> std::io::Result<()>,
) -> Result<(), String> {
    std::fs::create_dir_all(staging).map_err(|e| format!("建临时目录失败：{e}"))?;
    fail_at(Step::Copy).map_err(|e| format!("拷贝失败：{e}"))?;
    let index = staging.join("index.sqlite");
    storage::copy::vacuum_into(&legacy::index_db(root), &index)
        .await
        .map_err(|e| format!("拷贝索引失败：{e}"))?;
    for (from, to) in [
        (legacy::blobs_db(root), staging.join("blobs.db")),
        (legacy::flow_blobs_db(root), staging.join("flow-blobs.db")),
    ] {
        if from.exists() {
            copy_synced(&from, &to).map_err(|e| format!("拷贝 {} 失败：{e}", from.display()))?;
        }
    }

    fail_at(Step::Verify).map_err(|e| format!("核对失败：{e}"))?;
    let (src_ok, src) = storage::copy::table_counts(&legacy::index_db(root))
        .await
        .map_err(|e| format!("读源索引失败：{e}"))?;
    let (dst_ok, dst) = storage::copy::table_counts(&index)
        .await
        .map_err(|e| format!("读拷出的索引失败：{e}"))?;
    if !dst_ok {
        return Err("拷出的索引 integrity_check 不通过".into());
    }
    if src != dst {
        return Err(format!("拷出的索引与源索引行数不一致（源 ok={src_ok}）"));
    }
    sync_dir(staging).map_err(|e| format!("落盘失败：{e}"))?;
    Ok(())
}

fn copy_synced(from: &Path, to: &Path) -> std::io::Result<()> {
    // 在自己打开的可写句柄上写、在同一个句柄上 sync：Windows 的 FlushFileBuffers
    // 要写权限（只读句柄报 os error 5），而 `fs::copy` 会把只读属性带到目标上。
    let mut src = std::fs::File::open(from)?;
    let mut dst = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(to)?;
    std::io::copy(&mut src, &mut dst)?;
    dst.sync_all()
}

fn copy_tree(from: &Path, to: &Path) -> std::io::Result<()> {
    let entries = match std::fs::read_dir(from) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    std::fs::create_dir_all(to)?;
    for entry in entries {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            copy_tree(&entry.path(), &to.join(entry.file_name()))?;
        } else if kind.is_file() {
            let dst = to.join(entry.file_name());
            let same = match (entry.metadata(), std::fs::metadata(&dst)) {
                (Ok(a), Ok(b)) => a.len() == b.len(),
                _ => false,
            };
            if !same {
                std::fs::copy(entry.path(), &dst)?;
            }
        }
    }
    Ok(())
}

fn sync_dir(dir: &Path) -> std::io::Result<()> {
    platform::sync_dir(dir)
}

/// 提交之后：库盘里的旧索引与两个 `blobs.db` 直接删（本机那份已是正本）。
/// 失败只记日志，下次启动再删。
fn cleanup(root: &Path, fail_at: &impl Fn(Step) -> std::io::Result<()>) {
    if let Err(e) = fail_at(Step::Cleanup) {
        tracing::warn!("#1260: 旧数据收尾失败（{e}），下次启动再做");
        return;
    }
    let index = legacy::index_db(root);
    let mut olds = vec![index.clone()];
    for suffix in ["-wal", "-shm"] {
        let mut p = index.clone().into_os_string();
        p.push(suffix);
        olds.push(PathBuf::from(p));
    }
    olds.push(legacy::blobs_db(root));
    olds.push(legacy::flow_blobs_db(root));
    for old in olds {
        if let Err(e) = std::fs::remove_file(&old) {
            if e.kind() != std::io::ErrorKind::NotFound {
                tracing::warn!(
                    "#1260: 旧文件 {} 没删掉（{e}），下次启动再删",
                    old.display()
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library_location::LIBRARY_MARKER;

    #[test]
    fn copy_synced_handles_a_read_only_source() {
        let d = tempfile::tempdir().unwrap();
        let from = d.path().join("blobs.db");
        std::fs::write(&from, b"db").unwrap();
        let mut perm = std::fs::metadata(&from).unwrap().permissions();
        perm.set_readonly(true);
        std::fs::set_permissions(&from, perm).unwrap();
        let to = d.path().join("copy.db");
        copy_synced(&from, &to).unwrap();
        assert_eq!(std::fs::read(&to).unwrap(), b"db");
    }

    /// 老布局的库：库盘 `.ppf/` 里有索引（带一张照片的行）、两个 blobs.db、缩略图。
    async fn old_library() -> tempfile::TempDir {
        let lib = tempfile::tempdir().unwrap();
        let ppf = lib.path().join(LIBRARY_MARKER);
        std::fs::create_dir_all(ppf.join("blobs")).unwrap();
        std::fs::create_dir_all(ppf.join("flow-blobs")).unwrap();
        std::fs::create_dir_all(ppf.join("thumbs/ab")).unwrap();
        let month = lib.path().join("originals/aa/2026/09");
        std::fs::create_dir_all(&month).unwrap();
        std::fs::write(month.join("a.jpg"), b"photo-1").unwrap();
        let db = storage::Db::open(&legacy::index_db(lib.path()))
            .await
            .unwrap();
        let adopted = crate::Reconcile::new(db.clone(), lib.path())
            .with_local_node_id([0xccu8; 32])
            .run_once()
            .await
            .adopted;
        assert_eq!(adopted, 1);
        db.close().await;
        std::fs::write(legacy::blobs_db(lib.path()), b"redb-1").unwrap();
        std::fs::write(legacy::flow_blobs_db(lib.path()), b"redb-2").unwrap();
        std::fs::write(ppf.join("thumbs/ab/x.256.jpg"), b"jpg").unwrap();
        lib
    }

    fn plenty(_: &Path) -> Option<u64> {
        Some(u64::MAX)
    }

    async fn assets_in(path: &Path) -> usize {
        let db = storage::Db::open(path).await.unwrap();
        db.list_asset_paths().await.unwrap().len()
    }

    // 成功路径：数据到了本机、内容一致，库盘上不留旧副本（占盘 1x），库 ID 补上并记进本机。
    #[tokio::test]
    async fn an_old_library_moves_its_service_data_to_the_local_disk() {
        let lib = old_library().await;
        let local = tempfile::tempdir().unwrap();
        let Settled::Local(layout) =
            settle_with(lib.path(), local.path(), plenty, |_| Ok(())).await
        else {
            panic!("应当迁移成功");
        };
        assert_eq!(assets_in(&layout.index_db()).await, 1);
        assert_eq!(std::fs::read(layout.blobs_db()).unwrap(), b"redb-1");
        assert_eq!(std::fs::read(layout.flow_blobs_db()).unwrap(), b"redb-2");
        assert!(layout.thumbs().join("ab/x.256.jpg").is_file());
        assert!(
            !legacy::thumbs(lib.path()).exists(),
            "缩略图是搬过去的，库里不留副本（占盘 1x）"
        );
        assert!(!legacy::index_db(lib.path()).exists(), "旧索引已挪走");
        let id = layout::read_library_id(lib.path()).expect("补上了库 ID");
        assert_eq!(layout::recorded_library_id(local.path()), Some(id));
        assert!(
            !legacy::blobs_db(lib.path()).exists() && !legacy::flow_blobs_db(lib.path()).exists()
        );
        let leftovers: Vec<_> = std::fs::read_dir(lib.path().join(LIBRARY_MARKER))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .filter(|n| n.starts_with("index.sqlite") || n == "thumbs")
            .collect();
        assert!(
            leftovers.is_empty(),
            "库盘上不留旧副本（占盘 1x）：{leftovers:?}"
        );
    }

    // 失败路径：拷贝 / 核对 / 提交任一步失败——源数据一字未动、没有半成品，下次启动重试成功。
    // 反证：失败时不清 .migrating 或先删了源 → 断言红。
    #[tokio::test]
    async fn a_failed_migration_keeps_the_old_data_and_retries_next_start() {
        for step in [Step::Copy, Step::Verify, Step::Commit] {
            let lib = old_library().await;
            let local = tempfile::tempdir().unwrap();
            let fail = |s: Step| {
                if s == step {
                    Err(std::io::Error::other("injected"))
                } else {
                    Ok(())
                }
            };
            let out = settle_with(lib.path(), local.path(), plenty, fail).await;
            assert!(matches!(out, Settled::Legacy { .. }), "{step:?}: {out:?}");
            assert_eq!(
                assets_in(&legacy::index_db(lib.path())).await,
                1,
                "{step:?}：源索引还在"
            );
            assert_eq!(
                std::fs::read(legacy::blobs_db(lib.path())).unwrap(),
                b"redb-1"
            );
            let id = layout::read_library_id(lib.path()).unwrap();
            let libs = local.path().join(layout::LIBRARIES_DIR);
            assert!(!libs.join(&id).exists(), "{step:?}：没有提交出半成品");
            assert!(
                !libs.join(format!("{id}.migrating")).exists(),
                "{step:?}：临时目录已清"
            );

            let retry = settle_with(lib.path(), local.path(), plenty, |_| Ok(())).await;
            let Settled::Local(layout) = retry else {
                panic!("{step:?}：重试应当成功")
            };
            assert_eq!(assets_in(&layout.index_db()).await, 1);
        }
    }

    #[tokio::test]
    async fn not_enough_local_space_defers_without_touching_anything() {
        let lib = old_library().await;
        let local = tempfile::tempdir().unwrap();
        let out = settle_with(lib.path(), local.path(), |_| Some(1), |_| Ok(())).await;
        assert!(matches!(out, Settled::Legacy { .. }));
        assert!(legacy::index_db(lib.path()).exists());
    }

    // 提交后、收尾前崩溃：下次启动直接用本机那份，只补做收尾。
    #[tokio::test]
    async fn a_crash_after_commit_only_finishes_the_cleanup() {
        let lib = old_library().await;
        let local = tempfile::tempdir().unwrap();
        let fail = |s: Step| {
            if s == Step::Cleanup {
                Err(std::io::Error::other("crash"))
            } else {
                Ok(())
            }
        };
        let Settled::Local(_) = settle_with(lib.path(), local.path(), plenty, fail).await else {
            panic!("提交已成功");
        };
        assert!(
            legacy::index_db(lib.path()).exists(),
            "收尾没做，旧文件还在"
        );
        let Settled::Local(layout) =
            settle_with(lib.path(), local.path(), plenty, |_| Ok(())).await
        else {
            panic!()
        };
        assert!(!legacy::index_db(lib.path()).exists(), "下次启动补做了收尾");
        assert_eq!(assets_in(&layout.index_db()).await, 1, "用的是本机那份");
    }

    #[tokio::test]
    async fn a_new_library_starts_local() {
        let lib = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(lib.path().join(LIBRARY_MARKER)).unwrap();
        let local = tempfile::tempdir().unwrap();
        let Settled::Local(layout) =
            settle_with(lib.path(), local.path(), plenty, |_| Ok(())).await
        else {
            panic!()
        };
        assert!(layout.local().is_dir());
        assert!(!legacy::index_db(lib.path()).exists());
    }
}
