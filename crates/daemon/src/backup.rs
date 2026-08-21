//! Backup receive pipeline (T-032, 详细设计 §5.1 服务端半边):
//! manifest 查重回 missing → blobs 接收 → ingest → commit 更新水位。
//!
//! Transfer direction is PULL: the storage side fetches exactly the
//! hashes it declared missing, from the announcing device, over the
//! blobs ALPN (施工裁决 — iroh-blobs push is disabled by default and
//! would bypass the ctrl-plane authz; pulling keeps every write under
//! this daemon's control). The client simply serves its files.
//!
//! Idempotency: a manifest can repeat or arrive out of order — missing
//! is always computed against the current index. A commit can be re-run
//! after any interruption: already-ingested content dedups to
//! `Duplicate`, partially fetched blobs resume (iroh-blobs), and the
//! staging file + `create_new` landing in core-index never leave a
//! half-written original.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use core_index::{IncomingFile, Ingestor};
use proto::{BackupItem, BackupManifest, BackupMissing};
use storage::Db;
use transport::Blobs;

use crate::events::{EventBus, Throttle, DEFAULT_THROTTLE_WINDOW};

/// One device's announced-but-not-yet-committed manifest items.
#[derive(Default)]
struct Session {
    /// hash hex → metadata needed for ingest.
    items: HashMap<String, BackupItem>,
    /// Self-declared dialable address of the uploading device.
    provider: Option<String>,
    /// MOB-30：上传边收边入库的记账。`commit` 报的数字必须把这些算进去
    /// ——否则 commit 阶段看到它们已在索引里，会当成 duplicates 上报，
    /// 手机界面就会说「新增 0 张」。
    ingested: u32,
    duplicates: u32,
    /// 上传阶段已经处理掉的 hash。`commit` 必须跳过它们**且不计数**——
    /// 否则它们既进了 `ingested` 的账，又会在 commit 循环里被
    /// 「已在索引里」那一支当成 duplicates 数第二遍。
    settled: HashSet<String>,
}

/// The storage-side backup engine. Cloneable; the router holds one.
#[derive(Clone)]
pub struct BackupEngine {
    db: Db,
    ingestor: Ingestor,
    blobs: Arc<Blobs>,
    staging: PathBuf,
    sessions: Arc<Mutex<HashMap<transport::NodeId, Session>>>,
    /// SYNC-02：ingest 逐条触发，经节流合并；`commit` 收尾强制 flush。
    /// `None`（未接事件总线，如某些测试场景）时 `signal`/`flush_now`
    /// 直接跳过，不影响 ingest 本身。
    throttle: Option<Throttle>,
}

/// What a commit did (also serialized into the audit detail).
#[derive(Debug, PartialEq, Eq)]
pub struct CommitOutcome {
    pub ingested: u32,
    pub duplicates: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum BackupError {
    #[error("fetch {hash}: {msg}")]
    Fetch { hash: String, msg: String },
    #[error("ingest {hash}: {msg}")]
    Ingest { hash: String, msg: String },
    #[error("storage: {0}")]
    Storage(#[from] storage::StorageError),
}

impl BackupEngine {
    /// `library_root` is the same root core-index lands originals under;
    /// staging lives beside the index in `.ppf/staging`. `blobs` is the
    /// daemon's ONE store handle — shared with the query engine (two
    /// handles on one store dir would fight over the redb lock).
    pub fn new(db: Db, blobs: Arc<Blobs>, library_root: impl Into<PathBuf>) -> Self {
        let root = library_root.into();
        Self {
            ingestor: Ingestor::new(db.clone(), &root),
            db,
            blobs,
            staging: root.join(".ppf/staging"),
            sessions: Arc::default(),
            throttle: None,
        }
    }

    /// SYNC-02：接上事件总线——之后每条新 ingest 经节流合并推
    /// `timeline.invalidated`，`commit` 收尾强制 flush 一次挂起信号。
    pub fn with_events(mut self, events: EventBus) -> Self {
        self.throttle = Some(Throttle::new(events, DEFAULT_THROTTLE_WINDOW));
        self
    }

    /// `backup.begin`: reset the device's session. Idempotent.
    pub fn begin(&self, peer: transport::NodeId) {
        self.sessions
            .lock()
            .expect("sessions lock")
            .insert(peer, Session::default());
    }

    /// `backup.manifest`: record metadata, answer with what's missing.
    /// Repeats and reordering are safe — missing always reflects the
    /// index as it is now.
    pub async fn manifest(
        &self,
        peer: transport::NodeId,
        m: &BackupManifest,
    ) -> Result<BackupMissing, BackupError> {
        let mut missing = Vec::new();
        for item in &m.items {
            let Some(hash) = parse_hash(&item.hash) else {
                continue; // unparseable hash: not fetchable, not missing
            };
            if self.db.get_asset(&hash).await?.is_none() {
                missing.push(item.hash.clone());
            }
        }
        // Bare hashes (no metadata) still get a dedup answer — a client
        // may probe before preparing files. They are not fetchable until
        // a manifest with items arrives.
        for hex in &m.hashes {
            if m.items.iter().any(|i| &i.hash == hex) {
                continue;
            }
            if let Some(hash) = parse_hash(hex) {
                if self.db.get_asset(&hash).await?.is_none() {
                    missing.push(hex.clone());
                }
            }
        }

        let mut sessions = self.sessions.lock().expect("sessions lock");
        let session = sessions.entry(peer).or_default();
        for item in &m.items {
            session.items.insert(item.hash.clone(), item.clone());
        }
        if m.provider.is_some() {
            session.provider = m.provider.clone();
        }
        Ok(BackupMissing { hashes: missing })
    }

    /// MOB-30：把 `staging/<hash>` 那一份入库。**上传平面收完一张就调它**，
    /// `commit` 收尾时再对漏下的（走回退拉取的）调一次。
    ///
    /// 用户定调（2026-08-21）：「上传是主动的，我觉得入库也应该是主动的，
    /// 而不是说批量。」在此之前入库全挤在 `commit` 里，后果有两条：
    /// ①传 500 张时照片墙 8 分钟毫无动静最后一秒全冒出来；②`manifest` 算
    /// `missing` 只查索引不看 staging，传到第 400 张断掉时那 400 个文件安然
    /// 躺在 staging 里而索引一条都没有 → 下一轮手机把它们**重新上传一遍**。
    /// 逐张入库把②一并解掉：断点之前的都已进索引，下一轮 `missing` 不含它们。
    ///
    /// 返回 `true` = 真的新增了一条（New/Moved），`false` = 重复。
    /// 找不到 session 里的 item（manifest 还没到）时返回 `false` 不报错
    /// ——`commit` 会兜底。
    pub async fn ingest_staged(
        &self,
        peer: transport::NodeId,
        hash_hex: &str,
    ) -> Result<bool, BackupError> {
        let item = {
            let sessions = self.sessions.lock().expect("sessions lock");
            sessions
                .get(&peer)
                .and_then(|s| s.items.get(hash_hex).cloned())
        };
        let Some(item) = item else {
            return Ok(false);
        };
        let staged = self.staging.join(hash_hex);
        if !staged.is_file() {
            return Ok(false);
        }
        let fresh = self.ingest_one(peer, &item, &staged).await?;
        let mut sessions = self.sessions.lock().expect("sessions lock");
        if let Some(session) = sessions.get_mut(&peer) {
            if fresh {
                session.ingested += 1;
            } else {
                session.duplicates += 1;
            }
            session.settled.insert(hash_hex.to_string());
        }
        Ok(fresh)
    }

    /// 单条入库的**唯一**实现——上传路径与 commit 路径共用。
    /// 各写一遍必然漂移（MOB-19 手动/自动两条备份管线就是这么烂掉的）。
    async fn ingest_one(
        &self,
        peer: transport::NodeId,
        item: &BackupItem,
        staged: &std::path::Path,
    ) -> Result<bool, BackupError> {
        let incoming = IncomingFile {
            src_path: staged.to_path_buf(),
            file_name: item.file_name.clone(),
            media_type: item.media_type.clone(),
            src_device: peer.0.to_vec(),
        };
        match self.ingestor.ingest(&incoming).await {
            // WATCH-03：Moved = 索引里有这份内容但记录的文件早被外部删了，
            // 这次上传把它补回来——staged 已被 place 移走，不能再删。
            Ok(core_index::IngestOutcome::New(_)) | Ok(core_index::IngestOutcome::Moved(_)) => {
                if let Some(throttle) = &self.throttle {
                    throttle.signal();
                }
                Ok(true)
            }
            Ok(core_index::IngestOutcome::Duplicate) => {
                let _ = std::fs::remove_file(staged);
                Ok(false)
            }
            Err(e) => {
                let _ = std::fs::remove_file(staged);
                Err(BackupError::Ingest {
                    hash: item.hash.clone(),
                    msg: e.to_string(),
                })
            }
        }
    }

    /// `backup.commit`: pull every announced-and-still-missing blob from
    /// the device, ingest it, then advance the device's watermark.
    /// Fully idempotent — re-running after a crash converges.
    pub async fn commit(
        &self,
        peer: transport::NodeId,
        generation: Option<i64>,
    ) -> Result<CommitOutcome, BackupError> {
        let (items, provider, already) = {
            let sessions = self.sessions.lock().expect("sessions lock");
            sessions
                .get(&peer)
                .map(|s| {
                    (
                        s.items
                            .values()
                            .filter(|i| !s.settled.contains(&i.hash))
                            .cloned()
                            .collect::<Vec<BackupItem>>(),
                        s.provider.clone(),
                        // MOB-30：上传阶段已经边收边入库的部分。
                        CommitOutcome {
                            ingested: s.ingested,
                            duplicates: s.duplicates,
                        },
                    )
                })
                .unwrap_or((
                    Vec::new(),
                    None,
                    CommitOutcome {
                        ingested: 0,
                        duplicates: 0,
                    },
                ))
        };
        // Self-declared address beats observation — register it so every
        // fetch below dials the uploader directly.
        if let Some(addr) = &provider {
            if let Err(e) = self.blobs.register_peer(addr) {
                tracing::warn!("bad provider address from {peer:?}: {e}");
            }
        }

        std::fs::create_dir_all(&self.staging).ok();
        // MOB-30：起点是上传阶段已入库的账，不是 0——否则 commit 只会看到
        // 「它们已在索引里」并当成 duplicates，界面就报「新增 0 张」。
        let mut outcome = already;
        for item in items {
            let Some(hash) = parse_hash(&item.hash) else {
                continue;
            };
            if self.db.get_asset(&hash).await?.is_some() {
                outcome.duplicates += 1;
                continue; // already in the library — idempotent re-run
            }
            let staged = self.staging.join(&item.hash);
            // ── BLOB-01（2026-08-20）：主路径零往返 ──
            //
            // 手机推上来的文件（T-054 上传平面）已经**校验完毕、就躺在
            // staging 里**（上传平面流式算 BLAKE3 并自己比对，通过后把
            // `<hash>.upload` 原地改名成 `<hash>`）。直接 ingest 就行——
            // 下面那次 rename 是同卷零拷贝。
            //
            // 旧实现在这里无条件 `export_to`，也就是把文件从 blob store 里
            // **再拷一遍**出来；而它进 blob store 本身又是一次拷贝。同一份
            // 字节拷三遍，且 blob store 那份永不回收（用户实测占盘 2.05 倍）。
            //
            // blob store 从此只服务**回退路径**（T-032：daemon 主动向手机
            // 拉取）。那条路真的需要"边收边验+断点续传"，值得走它。
            // 短路顺序即优先级：staging 有现成的就用；没有才碰 blob store；
            // store 里也没有才向手机拉（T-032 回退路径）。
            if !staged.is_file() && self.blobs.export_to(hash, &staged).await.is_err() {
                {
                    self.blobs
                        .fetch_from(peer, hash)
                        .await
                        .map_err(|e| BackupError::Fetch {
                            hash: item.hash.clone(),
                            msg: e.to_string(),
                        })?;
                    self.blobs
                        .export_to(hash, &staged)
                        .await
                        .map_err(|e| BackupError::Fetch {
                            hash: item.hash.clone(),
                            msg: e.to_string(),
                        })?;
                }
            }
            if self.ingest_one(peer, &item, &staged).await? {
                outcome.ingested += 1;
            } else {
                outcome.duplicates += 1;
            }
        }

        if let Some(generation) = generation {
            self.db
                .set_watermark(&peer.0, generation, unix_ms_now())
                .await?;
        }
        self.sessions.lock().expect("sessions lock").remove(&peer);
        // §⑤ 批次收尾：这批里若还有挂起的节流信号，立即发，不等窗口到点
        // ——避免最后一批结果多等一个窗口才在时间线上出现。
        if let Some(throttle) = &self.throttle {
            throttle.flush_now();
        }
        Ok(outcome)
    }
}

fn unix_ms_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn parse_hash(hex: &str) -> Option<[u8; 32]> {
    let hex = hex.trim();
    if hex.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in hex.as_bytes().chunks_exact(2).enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[i] = ((hi << 4) | lo) as u8;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_parsing_rejects_garbage() {
        assert!(parse_hash("short").is_none());
        assert!(parse_hash(&"zz".repeat(32)).is_none());
        assert_eq!(parse_hash(&"0f".repeat(32)), Some([0x0f; 32]));
    }
}
