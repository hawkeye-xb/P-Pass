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
use std::time::{Duration, Instant};

use core_index::{IncomingFile, Ingestor};
use proto::{BackupItem, BackupManifest, BackupMissing};
use storage::Db;
use transport::Blobs;

use crate::events::{EventBus, Throttle, DEFAULT_THROTTLE_WINDOW};

/// MOB-32：一个会话空闲多久算「上一轮已经不在了」。
///
/// 下界由**单个文件的上传时长**决定——一轮备份里 session 被 touch 的最大
/// 间隔就是一个文件（一段 4K 视频走慢速局域网是分钟级）。取一小时，与
/// staging 孤儿的宽限期同一个数：两者要容忍的都是「一轮还没走完」。
pub const SESSION_IDLE_TTL: Duration = Duration::from_secs(3600);

/// MOB-32：staging 里的裸文件落地多久之后才算孤儿。
/// 见 `SESSION_IDLE_TTL` —— 同一个理由，同一个数。
pub const STAGING_ORPHAN_GRACE: Duration = Duration::from_secs(3600);

/// 会话是否还算活着。**纯判据**，单测直接覆盖。
fn session_is_live(touched_at: Instant, now: Instant, ttl: Duration) -> bool {
    now.saturating_duration_since(touched_at) < ttl
}

/// One device's announced-but-not-yet-committed manifest items.
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
    /// MOB-32：最后一次被碰的时刻（begin / manifest / 逐张入库都算）。
    /// 会话的生命周期归 `commit` 和 janitor（`sweep_sessions`），
    /// **不再归 `begin`**——理由见 `begin` 的注释。
    touched_at: Instant,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            items: HashMap::new(),
            provider: None,
            ingested: 0,
            duplicates: 0,
            settled: HashSet::new(),
            touched_at: Instant::now(),
        }
    }
}

impl Session {
    fn touch(&mut self) {
        self.touched_at = Instant::now();
    }
}

/// The storage-side backup engine. Cloneable; the router holds one.
#[derive(Clone)]
pub struct BackupEngine {
    db: Db,
    ingestor: Ingestor,
    blobs: Arc<Blobs>,
    staging: PathBuf,
    sessions: Arc<Mutex<HashMap<transport::NodeId, Session>>>,
    /// MOB-32：**本轮这台设备确实交付了几个文件**（上传平面校验通过就记）。
    ///
    /// 故意**不放在 `Session` 里**：session 可能被顶掉（那正是 MOB-32 的
    /// 事故），而这条证据必须活得比 session 长——否则 `commit` 无从发现
    /// 「传上来 N 张、入库 0 张」这个矛盾，只会安静地报成功。
    delivered: Arc<Mutex<HashMap<transport::NodeId, u32>>>,
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
    /// MOB-32：上传平面收下并校验通过了 N 个文件，commit 却一张都没入库。
    /// 这只可能是会话状态坏了（历史上是校准把它顶掉了）。**必须让手机
    /// 知道**——手机的判据是「调用没抛异常」，报成功它就把整批标记
    /// 「已备份」，那 N 张照片从此没人会再传一遍。
    #[error("交付了 {delivered} 个文件却一张都没入库——会话状态已损坏")]
    NothingIngested { delivered: u32 },
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
            delivered: Arc::default(),
            throttle: None,
        }
    }

    /// SYNC-02：接上事件总线——之后每条新 ingest 经节流合并推
    /// `timeline.invalidated`，`commit` 收尾强制 flush 一次挂起信号。
    pub fn with_events(self, events: EventBus) -> Self {
        self.with_events_and_window(events, DEFAULT_THROTTLE_WINDOW)
    }

    /// 可注入节流窗口的变体：集成测试用它把窗口拉到「比整批还长」，
    /// 把「批中不触发窗口 emit」从依赖墙钟运气变成结构性不可能——
    /// 1 秒默认窗口在被打满的 CI runner 上会在批次中途到点，多 emit
    /// 一次（对产品无害，但让「恰好一次」的断言变成薛定谔的红）。
    /// 窗口语义本身由 events.rs 的 Throttle 单测钉住，这里不测机制。
    pub fn with_events_and_window(mut self, events: EventBus, window: std::time::Duration) -> Self {
        self.throttle = Some(Throttle::new(events, window));
        self
    }

    /// `backup.begin`：**只保证这台设备有一个会话**，不保证它是空的。
    ///
    /// ⚠️ MOB-32：这里原本是 `insert(peer, Session::default())`——无条件盖掉。
    /// 而**漂移校准也走这条路**（`BackupRunner.existCheck` = begin +
    /// manifest(items 空)），会话又是按设备 NodeId 索引的，于是「用户在备份
    /// 途中打开 App」= 把正在跑的那一轮清空：manifest 声明的 items 全没了，
    /// 已上传的文件在 staging 里成了没人认领的孤儿，commit 循环零次报
    /// `ingested=0` **却返回成功**，手机据此把整批标记「已备份」。
    /// 用户真机实测一次丢 185 张 / 547MB。
    ///
    /// 老契约那句 "Idempotent" 只对**空闲**设备成立，对**正在上传**的设备
    /// 是毁灭性的。会话的生命周期现在归两处：`commit` 成功后删，janitor
    /// （`sweep_sessions`）清掉空闲超过 `SESSION_IDLE_TTL` 的。
    pub fn begin(&self, peer: transport::NodeId) {
        self.sessions
            .lock()
            .expect("sessions lock")
            .entry(peer)
            .or_default()
            .touch();
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
        session.touch(); // MOB-32：会话还在动，janitor 别收它
        for item in &m.items {
            session.items.insert(item.hash.clone(), item.clone());
        }
        if m.provider.is_some() {
            session.provider = m.provider.clone();
        }
        Ok(BackupMissing { hashes: missing })
    }

    /// MOB-32：上传平面校验通过后记一笔交付。**必须在调 `ingest_staged`
    /// 之前调**——会话被顶掉时 `ingest_staged` 会静默早退（找不到 item），
    /// 台账却照记，`commit` 才有据可查。
    pub fn note_delivered(&self, peer: transport::NodeId) {
        *self
            .delivered
            .lock()
            .expect("delivered lock")
            .entry(peer)
            .or_insert(0) += 1;
    }

    /// MOB-32 janitor：清掉空闲超过 `ttl` 的会话（连同它的交付台账）。
    /// 返回清掉的会话数。
    ///
    /// `begin` 不再负责重置之后，**总得有人收走中途死掉的那一轮**——否则
    /// 上一轮声明过、手机再也不会提供的「幽灵 item」会一直留在 items 里。
    pub fn sweep_sessions(&self, ttl: Duration) -> usize {
        let now = Instant::now();
        let mut dropped = Vec::new();
        let mut sessions = self.sessions.lock().expect("sessions lock");
        sessions.retain(|peer, s| {
            let live = session_is_live(s.touched_at, now, ttl);
            if !live {
                dropped.push(*peer);
            }
            live
        });
        if !dropped.is_empty() {
            let mut delivered = self.delivered.lock().expect("delivered lock");
            for peer in &dropped {
                delivered.remove(peer);
            }
        }
        dropped.len()
    }

    /// MOB-32：回收 staging 里的孤儿（已校验、但没有任何活会话认领的裸
    /// 文件）。返回释放的字节数。
    ///
    /// 保护集 = **所有活会话声明过的 hash**。它们可能正在 ingest，也可能
    /// 在等 commit 兜底，一个都不能碰。
    pub fn reclaim_staging(&self, grace: Duration) -> u64 {
        let protected: HashSet<String> = {
            let sessions = self.sessions.lock().expect("sessions lock");
            sessions
                .values()
                .flat_map(|s| s.items.keys().cloned())
                .collect()
        };
        crate::inbox::sweep_orphans(&self.staging, &protected, grace)
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
            session.touch(); // MOB-32：整轮上传期间会话持续续命
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
        // MOB-32：本轮这台设备到底交付了几个文件——独立于 session 的台账，
        // 会话被顶掉也还在。收尾时用它对账。
        let delivered = self
            .delivered
            .lock()
            .expect("delivered lock")
            .get(&peer)
            .copied()
            .unwrap_or(0);
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
                // ⚠️ MOB-32：拉取回退只对**自称可被拉取**的设备成立。
                //
                // 手机永远发 `provider = null`（它只推，从不 serve blobs），
                // 所以对手机来说这条路本来就走不通。而 `begin` 不再清空会话
                // 之后，上一轮中途死掉、手机上又已被删掉的照片会作为「幽灵
                // item」留在 items 里：不在索引、不在 staging、blob store 也
                // 没有 → 无门的话每次 commit 都在这里 `?` 报错，而报错时
                // 下面的 `sessions.remove` 走不到，会话不死、重试又 touch 它
                // 让 janitor 也收不走 → 备份一直红。
                //
                // 幽灵 item 本来就该跳过：手机上已经没有这张照片了，没有东西
                // 可备份。跳过不计数，留一行日志。
                if provider.is_none() {
                    tracing::warn!(
                        "commit {peer:?}: 跳过无处可取的 item {}（推送型会话，手机不提供拉取）",
                        item.hash
                    );
                    continue;
                }
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
            if self.ingest_one(peer, &item, &staged).await? {
                outcome.ingested += 1;
            } else {
                outcome.duplicates += 1;
            }
        }

        // ── ② MOB-32：交付了 N 个文件却一张都没入库 → 绝不许报成功 ──
        //
        // 手机的判据是「调用没抛异常」。报成功它就把整批标记「已备份」，
        // 那批照片从此没人会再传一遍——真机上一次丢了 185 张。
        // 水位也不能推：推了下一轮连候选都不会再产生。
        if delivered > 0 && outcome.ingested == 0 && outcome.duplicates == 0 {
            tracing::error!(
                "commit {peer:?}: 交付 {delivered} 个文件却入库 0 张——会话状态已损坏，拒绝报成功"
            );
            return Err(BackupError::NothingIngested { delivered });
        }

        if let Some(generation) = generation {
            self.db
                .set_watermark(&peer.0, generation, unix_ms_now())
                .await?;
        }
        self.sessions.lock().expect("sessions lock").remove(&peer);
        // 台账只在**成功收尾**时清——报错时留着，好让重试那一轮仍然看得见
        // 「这台设备已经交付过东西」。
        self.delivered.lock().expect("delivered lock").remove(&peer);
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
    for (i, chunk) in hex.as_bytes().as_chunks::<2>().0.iter().enumerate() {
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
