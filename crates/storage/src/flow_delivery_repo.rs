//! REBUILD-02 durable state for one native iroh-blobs delivery at a time.
//!
//! The grant is the Desktop-side authority for an item tuple. It records the
//! pairing record id, lease, and BLAKE3 hash together, so an old phone-side
//! retry cannot be mistaken for the current item. Completion is a separate
//! durable transition made only after materialization.
//!
//! #1117：交付记录挂在配对记录上（`pairing_id`，外键 ON DELETE CASCADE）。
//! 配对记录一删，它名下的租约与回执随之删除；重新配对拿新 id，序号空间独立。

use std::collections::HashSet;

use sqlx::Row;

use crate::{Db, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlowGrant {
    /// 交付方设备（由配对记录推出；写入时不落库，读出时 join 回来）。
    pub node_id: Vec<u8>,
    pub queue_sequence: i64,
    pub pairing_id: String,
    pub lease_token: String,
    pub content_hash: Vec<u8>,
    pub file_name: String,
    pub media_type: String,
    pub provider: String,
    pub state: FlowGrantState,
    pub receipt_id: Option<String>,
    /// #1272: `"auto"`（自动备份）或 `"picked"`（手机上手动挑选）。手机不报时是 `"auto"`。
    pub source: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlowGrantState {
    Active,
    Cancelled,
    Completed,
}

impl FlowGrantState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Cancelled => "cancelled",
            Self::Completed => "completed",
        }
    }

    fn from_db(value: &str) -> Self {
        match value {
            "active" => Self::Active,
            "cancelled" => Self::Cancelled,
            "completed" => Self::Completed,
            _ => Self::Cancelled,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlowReceipt {
    pub receipt_id: String,
    pub pairing_id: String,
    pub lease_token: String,
    pub content_hash: Vec<u8>,
}

/// #1272：只读地数一下「手机上手动挑选、已送达」的张数。照片库找不到时数据库还在本机，
/// 说明里要写这个数。打不开 / 没有这一列（更早的版本建的库）⇒ `None`，调用方不显示这一句。
pub async fn completed_picked_count_at(path: &std::path::Path) -> Option<i64> {
    use sqlx::ConnectOptions as _;
    let mut conn = sqlx::sqlite::SqliteConnectOptions::new()
        .filename(path)
        .read_only(true)
        .connect()
        .await
        .ok()?;
    sqlx::query_scalar("SELECT COUNT(*) FROM flow_delivery WHERE source = 'picked' AND state = 'completed'")
        .fetch_one(&mut conn)
        .await
        .ok()
}

/// 读出交付记录时 join 配对记录取回设备 NodeId。
const GRANT_SELECT: &str = "SELECT p.node_id, f.queue_sequence, f.pairing_id, f.lease_token,
            f.content_hash, f.file_name, f.media_type, f.provider, f.state, f.receipt_id, f.source
     FROM flow_delivery f JOIN pairing p ON p.id = f.pairing_id";

impl Db {
    /// Persist or replace a non-completed single-item grant. Completed rows
    /// are immutable receipts; callers must not overwrite their evidence.
    /// Stamps the resume clock with the wall clock; see
    /// [`Self::upsert_flow_grant_at`].
    pub async fn upsert_flow_grant(&self, grant: &FlowGrant) -> Result<()> {
        self.upsert_flow_grant_at(grant, wall_clock_ms()).await
    }

    /// Same as [`Self::upsert_flow_grant`] with an explicit `now_ms`: an
    /// offer is the phone resuming this tuple, so it restarts the
    /// [`Self::stale_active_flow_grants`] clock (#413 §6).
    pub async fn upsert_flow_grant_at(&self, grant: &FlowGrant, now_ms: i64) -> Result<()> {
        sqlx::query(
            "INSERT INTO flow_delivery
                (pairing_id, queue_sequence, lease_token, content_hash, file_name, media_type, provider, state, receipt_id, last_resumed_ms, source)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
             ON CONFLICT(pairing_id, queue_sequence) DO UPDATE SET
                lease_token = excluded.lease_token,
                content_hash = excluded.content_hash,
                file_name = excluded.file_name,
                media_type = excluded.media_type,
                provider = excluded.provider,
                state = excluded.state,
                receipt_id = NULL,
                last_resumed_ms = excluded.last_resumed_ms,
                source = excluded.source
             WHERE flow_delivery.state != 'completed'",
        )
        .bind(&grant.pairing_id)
        .bind(grant.queue_sequence)
        .bind(&grant.lease_token)
        .bind(&grant.content_hash)
        .bind(&grant.file_name)
        .bind(&grant.media_type)
        .bind(&grant.provider)
        .bind(grant.state.as_str())
        .bind(now_ms)
        .bind(&grant.source)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// #413 §6: a status poll that respawns a lost fetch is the phone
    /// actively waiting on this tuple — the same resume fact as an offer.
    /// Only an active row is touched; returns whether one was.
    pub async fn touch_active_flow_grant(&self, grant: &FlowGrant, now_ms: i64) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE flow_delivery SET last_resumed_ms = ?
             WHERE pairing_id = ? AND queue_sequence = ? AND lease_token = ?
               AND state = 'active'",
        )
        .bind(now_ms)
        .bind(&grant.pairing_id)
        .bind(grant.queue_sequence)
        .bind(&grant.lease_token)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected() == 1)
    }

    /// #413 §6: active grants whose last resume is older than `cutoff_ms`.
    /// Selection only — the caller decides (e.g. skips a still-running
    /// fetch) and cancels through the guarded [`Self::cancel_flow_grant`].
    pub async fn stale_active_flow_grants(&self, cutoff_ms: i64) -> Result<Vec<FlowGrant>> {
        let rows = sqlx::query(&format!(
            "{GRANT_SELECT} WHERE f.state = 'active' AND f.last_resumed_ms < ?
             ORDER BY f.last_resumed_ms"
        ))
        .bind(cutoff_ms)
        .fetch_all(self.pool())
        .await?;
        Ok(rows.into_iter().map(flow_grant_from_row).collect())
    }

    /// #413 §7 `index_ok`: the index database is open and its schema
    /// answers a query. Deliberately a read — a health probe must never
    /// contend with ingest for the write lock.
    pub async fn index_health_check(&self) -> Result<()> {
        sqlx::query("SELECT 1 FROM asset LIMIT 1")
            .fetch_optional(self.pool())
            .await?;
        Ok(())
    }

    /// A completed asset may be rediscovered after the phone lost only its
    /// local lease. The receipt stays immutable, but an authenticated caller
    /// with the same pairing and content hash may bind a fresh lease/provider
    /// to replay that receipt without re-fetching the bytes.
    pub async fn rebind_completed_flow_grant(&self, grant: &FlowGrant) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE flow_delivery SET lease_token = ?, provider = ?
             WHERE pairing_id = ? AND queue_sequence = ?
               AND content_hash = ? AND state = 'completed'",
        )
        .bind(&grant.lease_token)
        .bind(&grant.provider)
        .bind(&grant.pairing_id)
        .bind(grant.queue_sequence)
        .bind(&grant.content_hash)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected() == 1)
    }

    /// 一条交付记录。`node_id` 必须是这次配对的设备——别的设备拿着这个 id 查不到。
    pub async fn flow_grant(
        &self,
        node_id: &[u8],
        pairing_id: &str,
        queue_sequence: i64,
    ) -> Result<Option<FlowGrant>> {
        let row = sqlx::query(&format!(
            "{GRANT_SELECT} WHERE p.node_id = ? AND f.pairing_id = ? AND f.queue_sequence = ?"
        ))
        .bind(node_id)
        .bind(pairing_id)
        .bind(queue_sequence)
        .fetch_optional(self.pool())
        .await?;
        Ok(row.map(flow_grant_from_row))
    }

    /// Hashes of Flow items whose durable state still permits/resumes a native
    /// fetch. This is the sole storage-backed protection source for the
    /// flow-blobs GC callback.
    pub async fn active_flow_content_hashes(&self) -> Result<HashSet<[u8; 32]>> {
        let hashes: Vec<Vec<u8>> =
            sqlx::query_scalar("SELECT content_hash FROM flow_delivery WHERE state = 'active'")
                .fetch_all(self.pool())
                .await?;
        Ok(hashes
            .into_iter()
            .filter_map(|hash| hash.try_into().ok())
            .collect())
    }

    /// Record cancellation only if this still is the exact current item.
    /// #1076: the item is the tuple; `provider` (where the bytes come from)
    /// is not part of it, so a re-offer that only swapped the provider ticket
    /// is still the same item.
    pub async fn cancel_flow_grant(&self, grant: &FlowGrant) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE flow_delivery SET state = 'cancelled'
             WHERE pairing_id = ? AND queue_sequence = ? AND lease_token = ?
               AND content_hash = ? AND state = 'active'",
        )
        .bind(&grant.pairing_id)
        .bind(grant.queue_sequence)
        .bind(&grant.lease_token)
        .bind(&grant.content_hash)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected() == 1)
    }

    /// Atomically record a receipt after the original is materialized. The
    /// exact active tuple is rechecked here, so cancellation/supersession —
    /// or the pairing record having been deleted — can never receive a
    /// completion receipt. #1076: the provider is not rechecked.
    pub async fn complete_flow_grant(&self, grant: &FlowGrant, receipt_id: &str) -> Result<bool> {
        let result = sqlx::query(
            "UPDATE flow_delivery SET state = 'completed', receipt_id = ?
             WHERE pairing_id = ? AND queue_sequence = ? AND lease_token = ?
               AND content_hash = ? AND state = 'active'",
        )
        .bind(receipt_id)
        .bind(&grant.pairing_id)
        .bind(grant.queue_sequence)
        .bind(&grant.lease_token)
        .bind(&grant.content_hash)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected() == 1)
    }

    /// The receipt adapter reads only completed rows; active/cancelled work
    /// is intentionally indistinguishable from no receipt at all.
    pub async fn flow_receipt(
        &self,
        node_id: &[u8],
        pairing_id: &str,
        queue_sequence: i64,
    ) -> Result<Option<FlowReceipt>> {
        let row = sqlx::query(
            "SELECT f.receipt_id, f.pairing_id, f.lease_token, f.content_hash
             FROM flow_delivery f JOIN pairing p ON p.id = f.pairing_id
             WHERE p.node_id = ? AND f.pairing_id = ? AND f.queue_sequence = ?
               AND f.state = 'completed'",
        )
        .bind(node_id)
        .bind(pairing_id)
        .bind(queue_sequence)
        .fetch_optional(self.pool())
        .await?;
        Ok(row.map(|row| FlowReceipt {
            receipt_id: row.get("receipt_id"),
            pairing_id: row.get("pairing_id"),
            lease_token: row.get("lease_token"),
            content_hash: row.get("content_hash"),
        }))
    }
}

fn wall_clock_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn flow_grant_from_row(row: sqlx::sqlite::SqliteRow) -> FlowGrant {
    FlowGrant {
        node_id: row.get("node_id"),
        queue_sequence: row.get("queue_sequence"),
        pairing_id: row.get("pairing_id"),
        lease_token: row.get("lease_token"),
        content_hash: row.get("content_hash"),
        file_name: row.get("file_name"),
        media_type: row.get("media_type"),
        provider: row.get("provider"),
        state: FlowGrantState::from_db(row.get::<String, _>("state").as_str()),
        receipt_id: row.get("receipt_id"),
        source: row.get("source"),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{FlowGrant, FlowGrantState};
    use crate::{Db, DepartedBy, Pairing, Role};

    async fn paired_db(id: &str) -> Db {
        let db = Db::open_in_memory().await.unwrap();
        pair(&db, id).await;
        db
    }

    async fn pair(db: &Db, id: &str) {
        let p = Pairing {
            id: id.into(),
            node_id: vec![9; 32],
            role: Role::Member,
            paired_at: 1,
        };
        db.accept_pairing(&p.node_id, "phone", &p).await.unwrap();
    }

    fn grant(hash: u8, state: FlowGrantState, sequence: i64) -> FlowGrant {
        FlowGrant {
            node_id: vec![9; 32],
            queue_sequence: sequence,
            pairing_id: "pairing".into(),
            lease_token: format!("lease-{sequence}"),
            content_hash: vec![hash; 32],
            file_name: format!("{sequence}.jpg"),
            media_type: "image/jpeg".into(),
            provider: "provider".into(),
            state,
            receipt_id: None,
            source: "auto".into(),
        }
    }

    /// #1272：电脑端记下每一张是怎么来的（自动备份 / 手动挑选）。
    /// 反证：upsert 不写 source 列（落成默认 'auto'），picked 断言变红。
    #[tokio::test]
    async fn a_grant_records_how_the_phone_came_to_send_it() {
        let db = paired_db("pairing").await;
        let auto = grant(1, FlowGrantState::Active, 1);
        let mut picked = grant(2, FlowGrantState::Active, 2);
        picked.source = "picked".into();
        db.upsert_flow_grant(&auto).await.unwrap();
        db.upsert_flow_grant(&picked).await.unwrap();

        let read = |seq| {
            let db = db.clone();
            async move {
                db.flow_grant(&[9; 32], "pairing", seq)
                    .await
                    .unwrap()
                    .unwrap()
                    .source
            }
        };
        assert_eq!(read(1).await, "auto");
        assert_eq!(read(2).await, "picked");
    }

    /// #1272：库找不到时只读数「手选、已送达」的张数：只数手选 + 已完成，自动备份的、没完成的不数；
    /// 文件不在 / 打不开 ⇒ None。反证：去掉 `source = 'picked'` 条件 → 把自动备份的也数进去，红。
    #[tokio::test]
    async fn counts_completed_picked_grants_read_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.sqlite");
        let db = Db::open(&path).await.unwrap();
        pair(&db, "pairing").await;
        let auto = grant(1, FlowGrantState::Active, 1);
        let mut picked_done = grant(2, FlowGrantState::Active, 2);
        picked_done.source = "picked".into();
        let mut picked_done_too = grant(3, FlowGrantState::Active, 3);
        picked_done_too.source = "picked".into();
        let mut picked_open = grant(4, FlowGrantState::Active, 4);
        picked_open.source = "picked".into();
        for g in [&auto, &picked_done, &picked_done_too, &picked_open] {
            db.upsert_flow_grant(g).await.unwrap();
        }
        for g in [&auto, &picked_done, &picked_done_too] {
            assert!(db.complete_flow_grant(g, "receipt").await.unwrap());
        }
        assert_eq!(super::completed_picked_count_at(&path).await, Some(2));
        assert_eq!(super::completed_picked_count_at(&dir.path().join("missing.sqlite")).await, None);
    }

    #[tokio::test]
    async fn active_flow_content_hashes_excludes_completed_and_cancelled_grants() {
        let db = paired_db("pairing").await;
        db.upsert_flow_grant(&grant(1, FlowGrantState::Active, 1))
            .await
            .unwrap();
        db.upsert_flow_grant(&grant(2, FlowGrantState::Cancelled, 2))
            .await
            .unwrap();
        db.upsert_flow_grant(&grant(3, FlowGrantState::Completed, 3))
            .await
            .unwrap();

        assert_eq!(
            db.active_flow_content_hashes().await.unwrap(),
            HashSet::from([[1; 32]]),
            "only an active Flow grant may keep a flow-blobs hash alive"
        );
    }

    /// #1117：重新配对 = 新配对记录。旧记录删除时它的回执一起删；新 id 拥有
    /// 独立的序号空间，旧 id 再也查不到。
    /// 反证：去掉 flow_delivery 的 ON DELETE CASCADE，旧回执断言变红。
    #[tokio::test]
    async fn a_rejoin_gets_a_fresh_sequence_space_and_old_receipts_go_with_the_old_pairing() {
        let db = paired_db("before-rejoin").await;
        let mut old = grant(1, FlowGrantState::Completed, 1);
        old.pairing_id = "before-rejoin".into();
        db.upsert_flow_grant(&old).await.unwrap();
        db.remove_pairing(&[9; 32], None, DepartedBy::Device, 1)
            .await
            .unwrap();
        pair(&db, "after-rejoin").await;

        let mut renewed = grant(2, FlowGrantState::Active, 1);
        renewed.pairing_id = "after-rejoin".into();
        db.upsert_flow_grant(&renewed).await.unwrap();

        assert_eq!(
            db.flow_grant(&old.node_id, &old.pairing_id, 1)
                .await
                .unwrap(),
            None,
            "the old pairing's receipts were deleted with it"
        );
        assert_eq!(
            db.flow_grant(&renewed.node_id, &renewed.pairing_id, 1)
                .await
                .unwrap(),
            Some(renewed)
        );
    }

    /// 别的设备拿着这次配对的 id 查不到它的交付记录。
    #[tokio::test]
    async fn another_device_cannot_read_this_pairings_grants() {
        let db = paired_db("pairing").await;
        db.upsert_flow_grant(&grant(1, FlowGrantState::Completed, 1))
            .await
            .unwrap();
        assert!(db
            .flow_grant(&[8; 32], "pairing", 1)
            .await
            .unwrap()
            .is_none());
        assert!(db
            .flow_receipt(&[8; 32], "pairing", 1)
            .await
            .unwrap()
            .is_none());
    }

    /// #413 §6: 超过期限没续传的 active grant 才算过期；completed/cancelled
    /// 永不出现在结果里，刚续传（重新 offer）过的也不算。
    #[tokio::test]
    async fn stale_active_grants_are_selected_by_their_last_resume_time_only() {
        let db = paired_db("pairing").await;
        db.upsert_flow_grant_at(&grant(1, FlowGrantState::Active, 1), 1_000)
            .await
            .unwrap();
        db.upsert_flow_grant_at(&grant(2, FlowGrantState::Active, 2), 5_000)
            .await
            .unwrap();
        db.upsert_flow_grant_at(&grant(3, FlowGrantState::Cancelled, 3), 1_000)
            .await
            .unwrap();
        db.upsert_flow_grant_at(&grant(4, FlowGrantState::Completed, 4), 1_000)
            .await
            .unwrap();

        let stale = db.stale_active_flow_grants(2_000).await.unwrap();
        assert_eq!(stale, vec![grant(1, FlowGrantState::Active, 1)]);

        // Re-offering the same tuple is the resume signal: it refreshes the clock.
        db.upsert_flow_grant_at(&grant(1, FlowGrantState::Active, 1), 9_000)
            .await
            .unwrap();
        assert!(db.stale_active_flow_grants(2_000).await.unwrap().is_empty());

        // A status-driven respawn refreshes it too, but only for an active row.
        assert!(db
            .touch_active_flow_grant(&grant(2, FlowGrantState::Active, 2), 20_000)
            .await
            .unwrap());
        assert!(!db
            .touch_active_flow_grant(&grant(3, FlowGrantState::Active, 3), 20_000)
            .await
            .unwrap());
        assert_eq!(
            db.stale_active_flow_grants(10_000).await.unwrap(),
            vec![grant(1, FlowGrantState::Active, 1)]
        );
    }

    /// #1076: a re-offer that only swaps the provider ticket is the same item.
    /// A fetch still holding the old provider can complete it or cancel it.
    #[tokio::test]
    async fn complete_and_cancel_ignore_a_replaced_provider() {
        let db = paired_db("pairing").await;
        let old = grant(1, FlowGrantState::Active, 1);
        let mut reoffered = old.clone();
        reoffered.provider = "provider-2".into();

        db.upsert_flow_grant(&old).await.unwrap();
        db.upsert_flow_grant(&reoffered).await.unwrap();
        assert!(db.complete_flow_grant(&old, "receipt").await.unwrap());

        let other = grant(2, FlowGrantState::Active, 2);
        let mut other_reoffered = other.clone();
        other_reoffered.provider = "provider-2".into();
        db.upsert_flow_grant(&other).await.unwrap();
        db.upsert_flow_grant(&other_reoffered).await.unwrap();
        assert!(db.cancel_flow_grant(&other).await.unwrap());

        // Counter-proof: the tuple still guards — another lease cannot finish it.
        let third = grant(3, FlowGrantState::Active, 3);
        db.upsert_flow_grant(&third).await.unwrap();
        let mut stranger = third.clone();
        stranger.lease_token = "lease-other".into();
        assert!(!db.complete_flow_grant(&stranger, "receipt").await.unwrap());
    }

    /// 配对记录被删后，在途拉取再也拿不到回执：记录已随配对级联删除。
    #[tokio::test]
    async fn a_deleted_pairing_can_never_receive_a_completion() {
        let db = paired_db("pairing").await;
        let g = grant(1, FlowGrantState::Active, 1);
        db.upsert_flow_grant(&g).await.unwrap();
        db.remove_pairing(&[9; 32], None, DepartedBy::Owner, 1)
            .await
            .unwrap();
        assert!(!db.complete_flow_grant(&g, "receipt").await.unwrap());
        assert!(db.active_flow_content_hashes().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn index_health_check_answers_on_an_open_index() {
        let db = Db::open_in_memory().await.unwrap();
        db.index_health_check().await.unwrap();
        // Counter-proof: a closed index must not report healthy.
        db.pool().close().await;
        assert!(db.index_health_check().await.is_err());
    }
}
