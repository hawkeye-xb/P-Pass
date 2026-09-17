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
//! ⚠️ 对账竞态安全依赖 T-011 ingest 先落文件后插行的顺序（先写盘再
//! INSERT asset 行）——磁盘写入与索引插入之间没有窗口，对账永远不会把
//! 刚落盘还没来得及插行的文件误判为「外部删除」；此顺序改不得。
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

use crate::events::{self, EventBus};

/// 一轮对账的统计（供调用方记录/测试断言）。
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ReconcileReport {
    /// 移除的幽灵资产条数（0 = 磁盘与索引一致）。
    pub removed: usize,
    /// IDX-01: 收编的孤儿文件条数（磁盘上有、索引里没有）。
    pub adopted: u64,
}

/// 磁盘 ↔ 索引对账器。只依赖 Db + library_root（blob 删除见模块注释）。
#[derive(Clone)]
pub struct Reconcile {
    db: Db,
    library_root: PathBuf,
    /// 累计移除计数（诊断用；Arc 使 clone 实例共享同一统计）。
    total_removed: std::sync::Arc<AtomicUsize>,
    events: Option<EventBus>,
    /// IDX-01: 本机 NodeId。`None` = 不跑收编方向——`watcher.rs` 构造的
    /// 那一份只借用 [`Reconcile::remove_asset`]，不该顺带扫全库。
    local_node_id: Option<Vec<u8>>,
}

impl Reconcile {
    pub fn new(db: Db, library_root: impl Into<PathBuf>) -> Self {
        Self {
            db,
            library_root: library_root.into(),
            total_removed: std::sync::Arc::new(AtomicUsize::new(0)),
            events: None,
            local_node_id: None,
        }
    }

    /// IDX-01: 接上本机 NodeId 即打开「收孤儿」方向。只有 `main.rs` 那份
    /// 常驻对账器该接——接了才会每轮扫 `originals/` 补索引缺失的行。
    /// 归属规则由 `core_index` 决定（`originals/<64hex>/` 反推来源设备，
    /// 否则算本机），这里只负责把本机身份递进去。
    pub fn with_local_node_id(mut self, node_id: impl Into<Vec<u8>>) -> Self {
        self.local_node_id = Some(node_id.into());
        self
    }

    /// SYNC-02：接上事件总线后，每跑完一轮就直发一次
    /// `timeline.invalidated`——单轮整轮操作，天然只触发一次，不经
    /// [`crate::events::Throttle`]（那个只用于 ingest 的高频逐文件调用）。
    pub fn with_events(mut self, events: EventBus) -> Self {
        self.events = Some(events);
        self
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
            if !self.library_root.join(&rel_path).exists()
                && self.remove_asset(&hash, &rel_path).await.is_ok()
            {
                report.removed += 1;
                self.total_removed.fetch_add(1, Ordering::Relaxed);
            }
        }

        // IDX-01: 另一半方向——文件在、索引行没了就补回来。
        //
        // 为什么先删后收：两个方向的作用集天然不相交（删的是"行在文件没了"，
        // 收的是"文件在行没了"），顺序不影响结果；先删只是让同一轮里被判为
        // 外部删除的那条不会白白参与下面的 hash 计算。
        //
        // 为什么不看 `audit_tombstone`：墓碑记的是"这份内容离开过库"，而能走
        // 到这里说明文件此刻**确实躺在 originals/ 里**——那是有人把它放回来
        // 了。按墓碑把它永久拉黑，会让"删了又放回来"的照片再也进不了库，
        // 比本卡要修的问题更糟。
        if let Some(node_id) = &self.local_node_id {
            match core_index::adopt_orphans(&self.db, &self.library_root, node_id).await {
                Ok(adopted) => report.adopted = adopted.adopted,
                // 与上面 `list_asset_paths` 失败同一条纪律：对账是收敛手段，
                // 一轮收编失败就等下一轮，绝不把 daemon 启动搞挂。
                Err(e) => tracing::warn!("IDX-01: 孤儿收编本轮失败，等下一轮：{e}"),
            }
        }

        if let Some(bus) = &self.events {
            events::emit(bus, events::TIMELINE_INVALIDATED, serde_json::json!({}));
        }
        report
    }

    /// 清理单个幽灵资产：thumb 文件 + asset 行 + 审计。
    /// WATCH-01: `pub(crate)`——目录监听的局部对账复用同一清理逻辑
    /// （thumb 路径约定 + 审计口径只此一份，不复制）。
    ///
    /// AUDIT-04: an external delete is exactly case matrix §5's
    /// "Desktop 外部删除" — it must leave a durable `audit_tombstone`
    /// (asset_ref = the removed hash, discoverer = None because the
    /// filesystem cannot say who), NOT just a plain audit_operation row.
    /// Deleting the `asset` row must never delete this tombstone or any
    /// prior item evidence for the same hash (card decision #3) — the
    /// `asset_ref` column is intentionally not a foreign key.
    pub(crate) async fn remove_asset(&self, hash: &[u8], rel_path: &str) -> storage::Result<()> {
        // thumb 文件（.ppf/thumbs/<2hex>/<hex>.{256,1024}.jpg）——纯文件，
        // 直接删；不存在（从未生成过缩略图）也正常。
        if let Ok(h32) = <[u8; 32]>::try_from(hash) {
            let paths = media_codec::thumb_paths(&self.library_root.join(".ppf/thumbs"), &h32);
            let _ = std::fs::remove_file(&paths.t256);
            let _ = std::fs::remove_file(&paths.t1024);
        }
        // asset 行（索引是派生数据，文件没了行就没意义）。
        self.db.delete_asset(hash).await?;
        // AUDIT-04: tombstone first — this is the case-matrix "外部删除"
        // fact, unattributable by design (filesystem cannot say who).
        self.db
            .append_tombstone(&storage::TombstoneEntry {
                tombstone_id: fresh_id(),
                item_ref: None,
                asset_ref: hash.to_vec(),
                evidence_ref: None,
                reason: "external_delete".into(),
                discoverer: None,
                occurred_at: now_ms(),
                recoverable: false,
                payload: Some(serde_json::json!({ "relPath": rel_path }).to_string()),
            })
            .await?;
        // 审计：外部删除无法归因（actor=NULL，文件系统不背锅）——保留
        // AUDIT-01 的 `asset.removed_external` operation 行以兼容既有
        // activity 消费者；tombstone 是本卡新增的、随资产行删除仍存活
        // 的权威证据。
        self.db
            .append_audit(&AuditEntry::local(
                now_ms(),
                None,
                "asset.removed_external",
                Some(hash.to_vec()),
                Some(serde_json::json!({ "relPath": rel_path }).to_string()),
            ))
            .await?;
        Ok(())
    }
}

fn fresh_id() -> String {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("OS randomness for tombstone id");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn run_once_emits_timeline_invalidated_exactly_once() {
        let db = Db::open_in_memory().await.unwrap();
        let dir = tempfile::tempdir().unwrap();
        let (bus, mut rx) = events::bus();
        let reconcile = Reconcile::new(db, dir.path()).with_events(bus);

        let report = reconcile.run_once().await;
        assert_eq!(report.removed, 0, "空索引，磁盘侧自然也没有需要清理的");

        let msg = rx.try_recv().expect("跑完一轮该发一次");
        assert_eq!(msg["event"], events::TIMELINE_INVALIDATED);
        assert!(
            rx.try_recv().is_err(),
            "单轮 reconcile 只应触发一次，不是零次也不是多次"
        );
    }

    // IDX-01 RED: 对账必须有「收孤儿」这一半——文件躺在 originals/ 里、
    // 索引却没有它的行时，跑一轮必须把它补回来。去掉 run_once 里那段
    // adopt_orphans 调用，这条立刻变红（本卡的故障判据）。
    #[tokio::test]
    async fn run_once_adopts_a_file_that_has_no_index_row() {
        let db = Db::open_in_memory().await.unwrap();
        let dir = tempfile::tempdir().unwrap();
        let local = [0xccu8; 32];
        let src_dev = "aa".repeat(32);
        let month = dir.path().join(format!("originals/{src_dev}/2026/09"));
        std::fs::create_dir_all(&month).unwrap();
        std::fs::write(month.join("orphan.jpg"), b"orphan bytes").unwrap();

        let reconcile = Reconcile::new(db.clone(), dir.path()).with_local_node_id(local);
        let report = reconcile.run_once().await;

        assert_eq!(report.adopted, 1, "磁盘上有、索引里没有 → 必须收编");
        assert_eq!(report.removed, 0, "没有幽灵行可删");
        let page = db.timeline_page(None, 10).await.unwrap();
        assert_eq!(page.assets.len(), 1, "收编完必须能从时间线读出来");
        assert_eq!(
            page.assets[0].src_device,
            hex_to_bytes(&src_dev),
            "归属必须从 originals/<64hex>/ 反推到来源设备，不是记成本机"
        );
    }

    // IDX-01: 没接 with_local_node_id 就不许扫全库——watcher.rs 借用
    // remove_asset 的那一份走的就是这条路，它不该顺带做全库收编。
    #[tokio::test]
    async fn adoption_stays_off_until_the_local_node_id_is_wired() {
        let db = Db::open_in_memory().await.unwrap();
        let dir = tempfile::tempdir().unwrap();
        let month = dir.path().join("originals/aa/2026/09");
        std::fs::create_dir_all(&month).unwrap();
        std::fs::write(month.join("orphan.jpg"), b"orphan bytes").unwrap();

        let report = Reconcile::new(db.clone(), dir.path()).run_once().await;

        assert_eq!(report.adopted, 0);
        assert_eq!(
            db.timeline_page(None, 10).await.unwrap().assets.len(),
            0,
            "没打开收编开关就一行都不许写"
        );
    }

    // IDX-01 反证②（不越界）：收编**不是**清表重建。已经在册的行，
    // added_at / thumb_state 必须一字不动——真走了 clear+rebuild 这条必红。
    #[tokio::test]
    async fn adoption_never_rewrites_rows_that_are_already_indexed() {
        let db = Db::open_in_memory().await.unwrap();
        let dir = tempfile::tempdir().unwrap();
        let month = dir.path().join("originals/aa/2026/09");
        std::fs::create_dir_all(&month).unwrap();
        let kept = month.join("kept.jpg");
        std::fs::write(&kept, b"kept bytes").unwrap();
        let kept_hash = core_index::hash_file(&kept).unwrap().to_vec();
        db.insert_asset(&storage::Asset {
            hash: kept_hash.clone(),
            rel_path: "originals/aa/2026/09/kept.jpg".into(),
            media_type: "image/jpeg".into(),
            bytes: 10,
            taken_at: Some(111),
            width: Some(640),
            height: Some(480),
            src_device: vec![7u8; 32],
            added_at: 12345,
            thumb_state: 1,
        })
        .await
        .unwrap();
        std::fs::write(month.join("new.jpg"), b"new bytes").unwrap();

        let report = Reconcile::new(db.clone(), dir.path())
            .with_local_node_id([0xccu8; 32])
            .run_once()
            .await;

        assert_eq!(report.adopted, 1, "只该收那一个没入册的");
        let kept_row = db.get_asset(&kept_hash).await.unwrap().expect("原行还在");
        assert_eq!(kept_row.added_at, 12345, "added_at 不许被重写");
        assert_eq!(kept_row.thumb_state, 1, "thumb_state 不许被归零");
        assert_eq!(kept_row.width, Some(640), "width 不许被抹成 NULL");
        assert_eq!(kept_row.src_device, vec![7u8; 32], "归属不许被改写");
    }

    fn hex_to_bytes(hex: &str) -> Vec<u8> {
        (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect()
    }

    #[tokio::test]
    async fn run_once_without_events_bus_does_not_panic() {
        let db = Db::open_in_memory().await.unwrap();
        let dir = tempfile::tempdir().unwrap();
        let reconcile = Reconcile::new(db, dir.path()); // 没接 with_events

        reconcile.run_once().await;
    }

    // AUDIT-04 RED: an external delete must leave a durable tombstone that
    // survives the asset row's own deletion (card decision #3). Comment
    // out the `append_tombstone` call above and this test goes red.
    #[tokio::test]
    async fn external_delete_leaves_a_tombstone_that_outlives_the_asset_row() {
        let db = Db::open_in_memory().await.unwrap();
        let dir = tempfile::tempdir().unwrap();
        let hash = vec![0x42u8; 32];
        db.insert_asset(&storage::Asset {
            hash: hash.clone(),
            rel_path: "originals/gone.jpg".into(),
            media_type: "image/jpeg".into(),
            bytes: 1,
            taken_at: Some(1),
            width: None,
            height: None,
            src_device: vec![1u8; 32],
            added_at: 1,
            thumb_state: 0,
        })
        .await
        .unwrap();
        // The file was never actually written to disk under `dir` — this
        // simulates the Finder-style external delete reconcile detects.
        let reconcile = Reconcile::new(db.clone(), dir.path());

        let report = reconcile.run_once().await;
        assert_eq!(report.removed, 1);

        assert!(
            db.get_asset(&hash).await.unwrap().is_none(),
            "the asset row must actually be gone"
        );
        let tombstones = db.list_tombstones_for_asset(&hash).await.unwrap();
        assert_eq!(
            tombstones.len(),
            1,
            "tombstone must survive the asset row's own deletion"
        );
        assert_eq!(tombstones[0].entry.reason, "external_delete");
        assert!(
            tombstones[0].entry.discoverer.is_none(),
            "filesystem-detected deletion is unattributable by design"
        );
        assert!(!tombstones[0].entry.recoverable);
    }
}
