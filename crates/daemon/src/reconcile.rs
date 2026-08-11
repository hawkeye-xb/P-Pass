//! SYNC-01: 外部删除对账（幽灵照片根治）。
//!
//! 现象：用户在 Finder 手动删掉库目录文件后，手机时间线依旧看到旧照片
//! ——thumb 存储独立于 originals，索引（asset 表）也没清，三处不同步。
//!
//! 对账语义：磁盘（`originals/`，asset.rel_path 指向的位置）↔ 索引
//! （asset 表）。**磁盘上没了的条目** = 外部删除（无法归因到设备，
//! actor=NULL 如实记审计）→ 清 asset 行 + thumb 文件 + 审计
//! `asset.removed_external`。
//!
//! 触发：①daemon 启动时跑一轮（重启即收敛）；②运行期每小时 re-diff。
//! 选低频轮询而非目录监听的理由：目录监听要 FSEvents/inotify 双平台
//! 实现 + 事件风暴处理，收益只是把收敛提前最多 1 小时；照片墙打开时
//! timeline 从 db 读、thumb 按需生成，对账影响的是「已删照片的残留」，
//! 低频足够且零平台复杂度。
//!
//! ⚠️ 已知边界（写卡时核对，已记录）：**blob 不删**——iroh-blobs 0.103
//! 无公开 delete API（`delete_with_opts` 是 pub(crate)，手删文件会破坏
//! FsStore 的 meta 索引）；孤儿 blob 是内容寻址的，asset 行删除后没有任何
//! 产品路径引用它，惰性无害，未来空间回收另立卡（docs/product/2026-08-12-cache-redlines.md
//! 同源备忘）。identity 文件被删场景：daemon 重启后 load_or_mint_identity
//! 会铸造新身份（老设备失去访问权）——属既有行为，不在本卡范围。

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use storage::{AuditEntry, Db};

/// 一轮对账的统计（供调用方记录/测试断言）。
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ReconcileReport {
    /// 移除的幽灵资产条数（0 = 磁盘与索引一致）。
    pub removed: usize,
}

/// 磁盘 ↔ 索引对账器。只依赖 Db + library_root（blob 删除见模块注释）。
#[derive(Clone)]
pub struct Reconcile {
    db: Db,
    library_root: PathBuf,
    /// 累计移除计数（诊断用；Arc 使 clone 实例共享同一统计）。
    total_removed: std::sync::Arc<AtomicUsize>,
}

impl Reconcile {
    pub fn new(db: Db, library_root: impl Into<PathBuf>) -> Self {
        Self {
            db,
            library_root: library_root.into(),
            total_removed: std::sync::Arc::new(AtomicUsize::new(0)),
        }
    }

    /// 已累计移除的条目数（运行期任务可查）。
    pub fn total_removed(&self) -> usize {
        self.total_removed.load(Ordering::Relaxed)
    }

    /// 对账一轮：枚举索引侧全集，磁盘上缺文件即按外部删除清理。
    /// 任何单条失败不中断整轮（一条坏路径不拖垮其余），返回统计。
    pub async fn run_once(&self) -> ReconcileReport {
        let Ok(paths) = self.db.list_asset_paths().await else {
            // 索引不可读（库损坏等）——静默跳过本轮，等下一轮再试；
            // 对账是收敛手段，不能把 daemon 启动搞挂。
            return ReconcileReport::default();
        };
        let mut report = ReconcileReport::default();
        for (hash, rel_path) in paths {
            if !self.library_root.join(&rel_path).exists() {
                if self.remove_asset(&hash, &rel_path).await.is_ok() {
                    report.removed += 1;
                    self.total_removed.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        report
    }

    /// 清理单个幽灵资产：thumb 文件 + asset 行 + 审计。
    async fn remove_asset(&self, hash: &[u8], rel_path: &str) -> storage::Result<()> {
        // thumb 文件（.ppf/thumbs/<2hex>/<hex>.{256,1024}.jpg）——纯文件，
        // 直接删；不存在（从未生成过缩略图）也正常。
        if let Ok(h32) = <[u8; 32]>::try_from(hash) {
            let paths = media_codec::thumb_paths(&self.library_root.join(".ppf/thumbs"), &h32);
            let _ = std::fs::remove_file(&paths.t256);
            let _ = std::fs::remove_file(&paths.t1024);
        }
        // asset 行（索引是派生数据，文件没了行就没意义）。
        self.db.delete_asset(hash).await?;
        // 审计：外部删除无法归因（actor=NULL，文件系统不背锅）。
        self.db
            .append_audit(&AuditEntry {
                ts: now_ms(),
                actor: None,
                action: "asset.removed_external".to_string(),
                target_hash: Some(hash.to_vec()),
                detail: Some(format!("originals missing: {rel_path}")),
            })
            .await?;
        Ok(())
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
