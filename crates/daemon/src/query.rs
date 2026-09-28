//! Query plane (T-033): timeline pages, thumbnails, blob tickets.
//!
//! 契约: `timeline.page` 走 repo; `thumb.get` 缓存命中直读，未生成触发
//! 即时生成（**5 s 超时回内置占位图**，绝不让 UI 干等）; `asset.blob_ticket`
//! 发 iroh-blobs 票据供原图/视频拉取。
//!
//! DESK-34 (#428): 生成路径加了 `ThumbGate`——同一 hash 的 in-flight 去重、
//! 失败/超时后的内存负缓存（带过期，daemon 重启即清空），以及失败 WARN 日志。
//!
//! IDX-06 (#442): 入库后的后台预生成（`crate::thumb_pregen`）与 `thumb.get`
//! 共用同一个 `ThumbGate` 和同一份收尾逻辑 [`settle_generation`]——同一
//! hash 不管谁先触发，底层只生成一次。`thumb.get` 的生成期间会点亮
//! `ThumbGate::foreground`，预生成见它非零就暂停取新活（前台优先）。
//!
//! DESK-35 (#441): 失败不再在最终路径留占位图（见 media-codec thumb.rs），
//! 且收尾时清掉最终路径上的残留文件——「最终路径有文件 ⇔ 真缩略图」，
//! 重试与否只由 gate 的负缓存（10 分钟 / 重启）决定。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use proto::{AssetMeta, BlobTicketResponse, ThumbGet, ThumbSize, TimelineQuery};
use storage::Db;
use transport::Blobs;

use crate::telemetry::{Event as TelemetryEvent, Telemetry};

/// The 5 s thumb-generation budget (契约).
const THUMB_BUDGET: Duration = Duration::from_secs(5);

/// DESK-34 (#428): how long a failed / over-budget generation keeps its
/// negative-cache entry. Within this window `thumb.get` for that hash answers
/// the placeholder immediately instead of spawning another generation (on a
/// Mac without ffmpeg that is another 4 s qlmanage). After it — or after a
/// daemon restart, since the table is in memory only — the next request
/// retries. Ten minutes: long enough that scrolling back and forth over the
/// same page never re-pays, short enough that a transient cause (a system
/// permission prompt the user has since answered) heals in one session.
///
/// DESK-35 (#441): a failed generation leaves nothing at the final thumb
/// paths (and [`settle_generation`] purges any stale file there), so this
/// window is the one and only retry bound for every failure kind.
const THUMB_RETRY_AFTER: Duration = Duration::from_secs(10 * 60);

/// Above this many entries, expired negative records are pruned on insert —
/// keeps the table bounded without a background sweeper.
const THUMB_GATE_PRUNE_AT: usize = 4096;

/// The thumbnail generator `thumb.get` (and the pre-generation pool) calls.
/// Production is always `media_codec::make_thumbs`; the indirection exists
/// so contract tests can count invocations and inject slow / failing
/// generations.
pub(crate) type ThumbGen = media_codec::ThumbGenerator;

#[derive(Debug, thiserror::Error)]
pub enum QueryError {
    #[error("storage: {0}")]
    Storage(#[from] storage::StorageError),
    #[error("unknown asset")]
    NotFound,
    #[error("blob ticket: {0}")]
    Ticket(String),
}

/// Cloneable query engine; the router holds one.
#[derive(Clone)]
pub struct QueryEngine {
    pub(crate) db: Db,
    blobs: Arc<Blobs>,
    pub(crate) library_root: PathBuf,
    pub(crate) thumbs_root: PathBuf,
    /// TEL-04: optional anonymized telemetry sink for `first_byte`.
    telemetry: Option<Telemetry>,
    /// DESK-34 (#428): in-flight dedup + negative cache, shared by every
    /// clone of this engine (the router clones it — a per-clone table
    /// would silently defeat the dedup).
    pub(crate) gate: Arc<ThumbGate>,
    pub(crate) generator: ThumbGen,
    pub(crate) budget: Duration,
    pub(crate) retry_after: Duration,
}

/// One hash's generation bookkeeping.
enum Slot {
    /// A generation is running. `done` flips to `true` once the owner task
    /// has finished all bookkeeping (state written, slot updated).
    InFlight {
        started: Instant,
        done: tokio::sync::watch::Receiver<bool>,
    },
    /// The last generation failed (placeholder outcome or task death).
    Failed { at: Instant },
}

pub(crate) struct ThumbGate {
    slots: Mutex<HashMap<[u8; 32], Slot>>,
    /// IDX-06 (#442): how many `thumb.get`-owned generations are running.
    /// Pre-generation waits for this to reach zero before taking new work,
    /// which is what "thumb.get 优先" means in practice: the background
    /// pool's threads are low priority, but a video's ffmpeg / qlmanage
    /// child process is not, so yielding is the only real lever.
    foreground: tokio::sync::watch::Sender<usize>,
}

impl Default for ThumbGate {
    fn default() -> Self {
        Self {
            slots: Mutex::default(),
            foreground: tokio::sync::watch::Sender::new(0),
        }
    }
}

/// Holds one unit of `ThumbGate::foreground` for as long as it lives —
/// a Drop guard, so a panicking owner task can never leave the counter
/// stuck above zero and starve pre-generation forever.
struct ForegroundGuard(tokio::sync::watch::Sender<usize>);

impl ForegroundGuard {
    fn new(gate: &ThumbGate) -> Self {
        gate.foreground.send_modify(|n| *n += 1);
        Self(gate.foreground.clone())
    }
}

impl Drop for ForegroundGuard {
    fn drop(&mut self) {
        self.0.send_modify(|n| *n = n.saturating_sub(1));
    }
}

/// What a `thumb.get` miss should do, decided under the gate lock.
pub(crate) enum Plan {
    /// Answer the placeholder now; do not generate.
    Placeholder,
    /// Someone else is generating: wait, bounded by the original deadline.
    Wait {
        started: Instant,
        done: tokio::sync::watch::Receiver<bool>,
    },
    /// We reserved the slot: we must start the generation.
    Spawn {
        started: Instant,
        tx: tokio::sync::watch::Sender<bool>,
        done: tokio::sync::watch::Receiver<bool>,
    },
}

impl ThumbGate {
    /// Resolves once no `thumb.get`-owned generation is running.
    pub(crate) async fn foreground_idle(&self) {
        let mut rx = self.foreground.subscribe();
        let _ = rx.wait_for(|n| *n == 0).await;
    }

    pub(crate) fn plan(&self, hash: &[u8; 32], budget: Duration, retry_after: Duration) -> Plan {
        let mut slots = self.slots.lock().unwrap_or_else(|p| p.into_inner());
        match slots.get(hash) {
            Some(Slot::Failed { at }) if at.elapsed() < retry_after => return Plan::Placeholder,
            // Over budget and still running: a waiter would only time out
            // again — answer at once (the timeout half of the negative
            // cache), and never start a second generation for the hash.
            Some(Slot::InFlight { started, .. }) if started.elapsed() >= budget => {
                return Plan::Placeholder
            }
            Some(Slot::InFlight { started, done }) => {
                return Plan::Wait {
                    started: *started,
                    done: done.clone(),
                }
            }
            _ => {}
        }
        let started = Instant::now();
        let (tx, done) = tokio::sync::watch::channel(false);
        slots.insert(
            *hash,
            Slot::InFlight {
                started,
                done: done.clone(),
            },
        );
        Plan::Spawn { started, tx, done }
    }

    /// Close out a generation: a failure becomes a negative record,
    /// anything else clears the slot so a later miss starts fresh.
    pub(crate) fn finish(&self, hash: &[u8; 32], failed: bool, retry_after: Duration) {
        let mut slots = self.slots.lock().unwrap_or_else(|p| p.into_inner());
        if failed {
            if slots.len() >= THUMB_GATE_PRUNE_AT {
                slots.retain(|_, s| match s {
                    Slot::Failed { at } => at.elapsed() < retry_after,
                    Slot::InFlight { .. } => true,
                });
            }
            slots.insert(*hash, Slot::Failed { at: Instant::now() });
        } else {
            slots.remove(hash);
        }
    }
}

/// DESK-34 / IDX-06: close out one generation — shared by the `thumb.get`
/// owner task and the pre-generation pool, so both write `thumb_state`,
/// log, and release the gate slot identically. `joined` is the generator's
/// result, or why there is none (task death, pool worker lost).
///
/// DESK-35 (#441): on failure, whatever sits at the final thumb paths is
/// removed. `make_thumbs` itself no longer writes there on failure, so what
/// this catches is a placeholder left by an older build (`thumb_state=2`
/// rows from before the fix): as long as it stays, the disk-hit check
/// serves it and the negative cache's expiry never gets a say.
pub(crate) async fn settle_generation(
    db: &Db,
    gate: &ThumbGate,
    thumbs_root: &Path,
    hash: &[u8; 32],
    joined: Result<media_codec::ThumbResult, String>,
    retry_after: Duration,
    tx: tokio::sync::watch::Sender<bool>,
) {
    let prefix = hash_prefix(hash);
    let failed = match joined {
        Ok(result) => {
            let (state, failed) = match &result.outcome {
                media_codec::ThumbOutcome::Generated => (1, false),
                media_codec::ThumbOutcome::Placeholder { reason } => {
                    tracing::warn!(
                        hash = %prefix,
                        reason = %reason,
                        "thumb generation failed; placeholder served"
                    );
                    (2, true)
                }
            };
            if let Err(e) = db.set_thumb_state(hash, state).await {
                tracing::warn!(hash = %prefix, "thumb_state write failed: {e}");
            }
            failed
        }
        Err(e) => {
            tracing::warn!(
                hash = %prefix,
                reason = %e,
                "thumb generation task died; placeholder served"
            );
            let _ = db.set_thumb_state(hash, 2).await;
            true
        }
    };
    if failed {
        let paths = media_codec::thumb_paths(thumbs_root, hash);
        for p in [&paths.t256, &paths.t1024] {
            let _ = tokio::fs::remove_file(p).await;
        }
    }
    gate.finish(hash, failed, retry_after);
    let _ = tx.send(true);
}

/// Short, log-friendly hash prefix.
pub(crate) fn hash_prefix(hash: &[u8; 32]) -> String {
    hash[..6].iter().map(|b| format!("{b:02x}")).collect()
}

impl QueryEngine {
    pub fn new(db: Db, blobs: Arc<Blobs>, library_root: impl Into<PathBuf>) -> Self {
        let root = library_root.into();
        Self {
            db,
            blobs,
            thumbs_root: root.join(".ppf/thumbs"),
            library_root: root,
            telemetry: None,
            gate: Arc::default(),
            generator: Arc::new(|hash: &[u8; 32], src: &Path, root: &Path| {
                media_codec::make_thumbs(hash, src, root)
            }),
            budget: THUMB_BUDGET,
            retry_after: THUMB_RETRY_AFTER,
        }
    }

    /// TEL-04: wire an anonymized telemetry sink so `thumb()`/`original()`
    /// each record one `first_byte` event (ms/kind) per request.
    /// `Telemetry::record` is already a no-op when the client itself is
    /// disabled — this builder only controls whether `QueryEngine` has a
    /// sink to call at all.
    pub fn with_telemetry(mut self, telemetry: Telemetry) -> Self {
        self.telemetry = Some(telemetry);
        self
    }

    fn record_first_byte(&self, started: std::time::Instant, kind: &'static str) {
        if let Some(telemetry) = &self.telemetry {
            telemetry.record(TelemetryEvent::FirstByte {
                ms: started.elapsed().as_millis() as u64,
                kind,
            });
        }
    }

    /// `timeline.page`: keyset pagination straight off the repo.
    pub async fn timeline(&self, q: &TimelineQuery) -> Result<proto::TimelinePage, QueryError> {
        let page = self.db.timeline_page(q.cursor.as_deref(), q.limit).await?;
        Ok(proto::TimelinePage {
            items: page.assets.iter().map(asset_meta).collect(),
            next: page.next_cursor,
        })
    }

    /// `asset.meta`: one asset by hash.
    pub async fn asset_meta(&self, hash_hex: &str) -> Result<AssetMeta, QueryError> {
        let hash = parse_hash(hash_hex).ok_or(QueryError::NotFound)?;
        let asset = self
            .db
            .get_asset(&hash)
            .await?
            .ok_or(QueryError::NotFound)?;
        Ok(asset_meta(&asset))
    }

    /// `thumb.get`: cache hit reads the file; miss generates within the
    /// budget; over-budget (or unknown asset) answers the placeholder —
    /// a grid never blocks on a slow decode.
    pub async fn thumb(&self, t: &ThumbGet) -> Result<Vec<u8>, QueryError> {
        let started = std::time::Instant::now();
        let size = t.size;
        let Some(hash) = parse_hash(&t.hash) else {
            self.record_first_byte(started, "thumb");
            return Ok(media_codec::placeholder_jpeg(size as u32));
        };
        let paths = media_codec::thumb_paths(&self.thumbs_root, &hash);
        let path = match size {
            ThumbSize::S256 => paths.t256.clone(),
            ThumbSize::S1024 => paths.t1024.clone(),
        };
        if let Ok(bytes) = tokio::fs::read(&path).await {
            self.record_first_byte(started, "thumb");
            return Ok(bytes);
        }

        // Miss: the asset must exist.
        let Some(asset) = self.db.get_asset(&hash).await? else {
            self.record_first_byte(started, "thumb");
            return Ok(media_codec::placeholder_jpeg(size as u32));
        };

        // DESK-34 (#428): consult the gate before spawning anything — a
        // recent failure answers at once, a running generation is joined
        // instead of duplicated. No `.await` may sit between reserving a
        // slot (`Plan::Spawn`) and `spawn_generation`: a request dropped
        // there (connection closed) would leave the slot InFlight with no
        // owner, wedging the hash on the placeholder until restart.
        let (gen_started, mut done) = match self.gate.plan(&hash, self.budget, self.retry_after) {
            Plan::Placeholder => {
                self.record_first_byte(started, "thumb");
                return Ok(media_codec::placeholder_jpeg(size as u32));
            }
            Plan::Wait { started, done } => (started, done),
            Plan::Spawn {
                started: gen_started,
                tx,
                done,
            } => {
                self.spawn_generation(hash, self.library_root.join(&asset.rel_path), tx);
                (gen_started, done)
            }
        };

        // Bounded wait on the shared deadline (the generation's start, not
        // this request's): joiners never stretch the 5 s promise.
        let remaining = self.budget.saturating_sub(gen_started.elapsed());
        let finished = tokio::time::timeout(remaining, done.wait_for(|d| *d))
            .await
            .is_ok();
        let result = if finished {
            Ok(tokio::fs::read(&path)
                .await
                .unwrap_or_else(|_| media_codec::placeholder_jpeg(size as u32)))
        } else {
            // Budget blown: placeholder now; the owner task keeps running
            // and the file may still land on disk for a later request.
            Ok(media_codec::placeholder_jpeg(size as u32))
        };
        self.record_first_byte(started, "thumb");
        result
    }

    /// DESK-34 (#428): run one generation to completion, detached from any
    /// requester. It owns the bookkeeping the old timeout branch skipped:
    /// `thumb_state` is written whenever the generation ends (even past the
    /// budget), failures land in the negative cache, and every failure or
    /// budget overrun is a WARN carrying hash prefix and reason — before
    /// this, thumbnail generation logged nothing at all.
    fn spawn_generation(&self, hash: [u8; 32], src: PathBuf, tx: tokio::sync::watch::Sender<bool>) {
        let db = self.db.clone();
        let gate = Arc::clone(&self.gate);
        let generator = Arc::clone(&self.generator);
        let thumbs_root = self.thumbs_root.clone();
        let (budget, retry_after) = (self.budget, self.retry_after);
        // Taken synchronously, before the task exists: pre-generation must
        // already see the foreground as busy by the time `thumb()` returns.
        let foreground = ForegroundGuard::new(&self.gate);
        tokio::spawn(async move {
            let _foreground = foreground;
            let prefix = hash_prefix(&hash);
            let root = thumbs_root.clone();
            let mut handle = tokio::task::spawn_blocking(move || generator(&hash, &src, &root));
            let joined = match tokio::time::timeout(budget, &mut handle).await {
                Ok(joined) => joined,
                Err(_) => {
                    tracing::warn!(
                        hash = %prefix,
                        reason = "timeout",
                        "thumb generation exceeded the {budget:?} budget; placeholder served, \
                         hash short-circuited until it finishes"
                    );
                    handle.await
                }
            };
            settle_generation(
                &db,
                &gate,
                &thumbs_root,
                &hash,
                joined.map_err(|e| e.to_string()),
                retry_after,
                tx,
            )
            .await;
        });
    }

    /// `asset.blob_ticket`: make the original fetchable and hand out a
    /// ticket. Import is idempotent (content-addressed store).
    pub async fn blob_ticket(&self, hash_hex: &str) -> Result<BlobTicketResponse, QueryError> {
        let hash = parse_hash(hash_hex).ok_or(QueryError::NotFound)?;
        let asset = self
            .db
            .get_asset(&hash)
            .await?
            .ok_or(QueryError::NotFound)?;
        let abs = self.library_root.join(&asset.rel_path);
        let ticket = self
            .blobs
            .push(hash, &abs)
            .await
            .map_err(|e| QueryError::Ticket(e.to_string()))?;
        Ok(BlobTicketResponse { ticket })
    }

    /// DESK-03: `asset.path` — the ORIGINAL file's absolute path on disk.
    /// 桌面壳与 daemon 同机：Finder 揭示直接指向这个路径（读 rel_path
    /// 拼 library_root，不做任何复制）。仅桌面 IPC 消费，不走网络平面。
    pub async fn asset_path(&self, hash_hex: &str) -> Result<PathBuf, QueryError> {
        let hash = parse_hash(hash_hex).ok_or(QueryError::NotFound)?;
        let asset = self
            .db
            .get_asset(&hash)
            .await?
            .ok_or(QueryError::NotFound)?;
        Ok(self.library_root.join(&asset.rel_path))
    }

    /// DESK-03: `asset.original` — 原图字节（大图查看用，不落盘）。
    ///
    /// 同机桌面壳直接读原文件字节，内存展示后即弃——「不长期落盘」由
    /// 不写任何临时文件天然满足。受 ctrl 帧上限约束：> 12 MiB 的原图
    /// 返回 NotFound（base64 后超 16 MiB 帧），桌面端降级到 1024 缩略图。
    /// 只服务 photo（video 原片体量必然超限，桌面大图只看照片）。
    pub async fn original(&self, hash_hex: &str) -> Result<Vec<u8>, QueryError> {
        const ORIGINAL_CAP: i64 = 12 * 1024 * 1024; // base64(12MiB) ≈ 16MiB 帧上限
        let started = std::time::Instant::now();
        let hash = parse_hash(hash_hex).ok_or(QueryError::NotFound)?;
        let asset = self
            .db
            .get_asset(&hash)
            .await?
            .ok_or(QueryError::NotFound)?;
        if !asset.media_type.starts_with("image/") {
            return Err(QueryError::NotFound); // video 不走大图
        }
        if asset.bytes > ORIGINAL_CAP {
            return Err(QueryError::NotFound);
        }
        let abs = self.library_root.join(&asset.rel_path);
        let bytes = tokio::fs::read(&abs)
            .await
            .map_err(|_| QueryError::NotFound)?;
        // Only a successful read actually delivers a first byte to the
        // viewer; NotFound/oversize/non-image paths never emit bytes, so
        // recording latency for them would not measure what the card asks
        // for ("翻相册卡不卡").
        self.record_first_byte(started, "blob");
        Ok(bytes)
    }
}

/// storage 行 → 线上元数据: taken_at ms→s, MIME → "photo"/"video" 粗类.
fn asset_meta(a: &storage::Asset) -> AssetMeta {
    AssetMeta {
        hash: a.hash.iter().map(|b| format!("{b:02x}")).collect(),
        taken_at: a.taken_at.unwrap_or(0) / 1000,
        media_type: if a.media_type.starts_with("video/") {
            "video".into()
        } else {
            "photo".into()
        },
        width: a.width.unwrap_or(0) as u32,
        height: a.height.unwrap_or(0) as u32,
        bytes: a.bytes.max(0) as u64,
        src_device: (a.src_device.len() == 32)
            .then(|| a.src_device.iter().map(|b| format!("{b:02x}")).collect()),
    }
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

    fn asset(src_device: Vec<u8>) -> storage::Asset {
        storage::Asset {
            hash: vec![0x11; 32],
            rel_path: "originals/test.jpg".into(),
            media_type: "image/jpeg".into(),
            bytes: 42,
            taken_at: Some(1_690_000_000_000),
            width: Some(4032),
            height: Some(3024),
            src_device,
            added_at: 1_690_000_000_000,
            thumb_state: 1,
        }
    }

    #[test]
    fn asset_meta_exposes_full_source_node_id_and_hides_empty_source() {
        assert_eq!(
            asset_meta(&asset(vec![0xab; 32])).src_device,
            Some("ab".repeat(32))
        );
        assert_eq!(asset_meta(&asset(vec![])).src_device, None);
    }

    // ── DESK-34 (#428): thumb.get gate contract ───────────────────────────
    //
    // The injected generators below write NOTHING to disk on failure —
    // which, since DESK-35 (#441), is also what the real `make_thumbs` does.
    // (Before it, the real codec wrote placeholder JPEGs at the final paths;
    // `a_failed_real_generation_is_retried_after_the_window` pins that down.)

    use std::sync::atomic::{AtomicUsize, Ordering};

    const VIDEO_A: [u8; 32] = [0x5a; 32];
    const VIDEO_B: [u8; 32] = [0xb7; 32];

    struct Fixture {
        engine: QueryEngine,
        _root: tempfile::TempDir,
    }

    async fn fixture(
        generator: ThumbGen,
        budget: Duration,
        retry_after: Duration,
        hashes: &[[u8; 32]],
    ) -> Fixture {
        let root = tempfile::tempdir().unwrap();
        let db = Db::open_in_memory().await.unwrap();
        for (i, h) in hashes.iter().enumerate() {
            db.insert_asset(&storage::Asset {
                hash: h.to_vec(),
                rel_path: format!("originals/clip{i}.mp4"),
                media_type: "video/mp4".into(),
                bytes: 42,
                taken_at: Some(1_690_000_000_000),
                width: None,
                height: None,
                src_device: vec![9u8; 32],
                added_at: 1_690_000_000_000,
                thumb_state: 0,
            })
            .await
            .unwrap();
        }
        let transport = transport::IrohTransport::bind(transport::TransportConfig::loopback(vec![
            "ppf/blobs/1".into(),
        ]))
        .await
        .unwrap();
        let blobs = Arc::new(
            Blobs::open(&transport, &root.path().join("blobs"))
                .await
                .unwrap(),
        );
        let mut engine = QueryEngine::new(db, blobs, root.path().join("library"));
        engine.generator = generator;
        engine.budget = budget;
        engine.retry_after = retry_after;
        Fixture {
            engine,
            _root: root,
        }
    }

    fn get(hash: &[u8; 32]) -> ThumbGet {
        ThumbGet {
            hash: hex::encode(hash),
            size: ThumbSize::S256,
        }
    }

    /// Fails like a qlmanage non-zero exit, counts calls, writes nothing.
    fn failing_gen(calls: Arc<AtomicUsize>, delay: Duration) -> ThumbGen {
        Arc::new(move |hash: &[u8; 32], _src: &Path, root: &Path| {
            calls.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(delay);
            media_codec::ThumbResult {
                paths: media_codec::thumb_paths(root, hash),
                outcome: media_codec::ThumbOutcome::Placeholder {
                    reason: "quicklook on clip.mp4: qlmanage exited with exit status: 1".into(),
                },
            }
        })
    }

    async fn thumb_state(f: &Fixture, hash: &[u8; 32]) -> i64 {
        f.engine
            .db
            .get_asset(hash)
            .await
            .unwrap()
            .unwrap()
            .thumb_state
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn failed_generation_is_negative_cached_and_not_respawned() {
        let calls = Arc::new(AtomicUsize::new(0));
        let f = fixture(
            failing_gen(Arc::clone(&calls), Duration::ZERO),
            Duration::from_secs(2),
            Duration::from_secs(3600),
            &[VIDEO_A],
        )
        .await;
        let placeholder = media_codec::placeholder_jpeg(256);

        assert_eq!(f.engine.thumb(&get(&VIDEO_A)).await.unwrap(), placeholder);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(
            thumb_state(&f, &VIDEO_A).await,
            2,
            "failure must be recorded"
        );

        for _ in 0..5 {
            let t = Instant::now();
            assert_eq!(f.engine.thumb(&get(&VIDEO_A)).await.unwrap(), placeholder);
            assert!(
                t.elapsed() < Duration::from_millis(200),
                "must answer at once"
            );
        }
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "a negative-cached hash must never spawn another generation"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn over_budget_generation_short_circuits_followers_and_still_records_state() {
        // qlmanage stuck on a permission prompt: the generation outlives
        // the budget. Followers must not pay the budget again, must not
        // start a second generation, and the state must land when it ends.
        let calls = Arc::new(AtomicUsize::new(0));
        let f = fixture(
            failing_gen(Arc::clone(&calls), Duration::from_millis(800)),
            Duration::from_millis(200),
            Duration::from_secs(3600),
            &[VIDEO_A],
        )
        .await;

        let t = Instant::now();
        f.engine.thumb(&get(&VIDEO_A)).await.unwrap();
        let first = t.elapsed();
        assert!(
            first >= Duration::from_millis(150) && first < Duration::from_millis(600),
            "first request is bounded by the budget, took {first:?}"
        );

        let t = Instant::now();
        f.engine.thumb(&get(&VIDEO_A)).await.unwrap();
        assert!(
            t.elapsed() < Duration::from_millis(100),
            "follower must not wait out a blown budget again, took {:?}",
            t.elapsed()
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1, "no second generation");

        // The detached owner task records thumb_state once it finishes —
        // the old timeout branch never wrote any state.
        let deadline = Instant::now() + Duration::from_secs(5);
        while thumb_state(&f, &VIDEO_A).await != 2 {
            assert!(Instant::now() < deadline, "thumb_state never recorded");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        // …and after it finished, the failure stays negative-cached.
        f.engine.thumb(&get(&VIDEO_A)).await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn negative_entry_expires_and_the_hash_is_retried() {
        let calls = Arc::new(AtomicUsize::new(0));
        let f = fixture(
            failing_gen(Arc::clone(&calls), Duration::ZERO),
            Duration::from_secs(2),
            Duration::from_millis(150),
            &[VIDEO_A],
        )
        .await;
        f.engine.thumb(&get(&VIDEO_A)).await.unwrap();
        f.engine.thumb(&get(&VIDEO_A)).await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1, "inside the window: cached");
        tokio::time::sleep(Duration::from_millis(250)).await;
        f.engine.thumb(&get(&VIDEO_A)).await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2, "after the window: retried");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn concurrent_misses_on_one_hash_share_a_single_generation() {
        const N: usize = 20;
        let calls = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&calls);
        let generator: ThumbGen = Arc::new(move |hash: &[u8; 32], _src: &Path, root: &Path| {
            c.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(Duration::from_millis(300));
            let paths = media_codec::thumb_paths(root, hash);
            std::fs::create_dir_all(paths.t256.parent().unwrap()).unwrap();
            std::fs::write(&paths.t256, b"REAL-256").unwrap();
            std::fs::write(&paths.t1024, b"REAL-1024").unwrap();
            media_codec::ThumbResult {
                paths,
                outcome: media_codec::ThumbOutcome::Generated,
            }
        });
        let f = fixture(
            generator,
            Duration::from_secs(3),
            Duration::from_secs(3600),
            &[VIDEO_A],
        )
        .await;

        let tasks: Vec<_> = (0..N)
            .map(|_| {
                let engine = f.engine.clone(); // clones must share the gate
                tokio::spawn(async move { engine.thumb(&get(&VIDEO_A)).await.unwrap() })
            })
            .collect();
        for t in tasks {
            assert_eq!(
                t.await.unwrap(),
                b"REAL-256",
                "every waiter gets the real thumb"
            );
        }
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "{N} concurrent thumb.get for one hash must run the generator once"
        );
        assert_eq!(thumb_state(&f, &VIDEO_A).await, 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_request_dropped_mid_flight_never_wedges_the_hash() {
        // A connection closing mid-request drops the `thumb()` future at
        // whatever `.await` it sits on. If that happened after the gate
        // slot was reserved but before the owner task existed, the slot
        // would stay InFlight forever and the hash would answer the
        // placeholder until restart, with no generation ever run.
        let calls = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&calls);
        let generator: ThumbGen = Arc::new(move |hash: &[u8; 32], _src: &Path, root: &Path| {
            c.fetch_add(1, Ordering::SeqCst);
            let paths = media_codec::thumb_paths(root, hash);
            std::fs::create_dir_all(paths.t256.parent().unwrap()).unwrap();
            std::fs::write(&paths.t256, b"REAL-256").unwrap();
            media_codec::ThumbResult {
                paths,
                outcome: media_codec::ThumbOutcome::Generated,
            }
        });
        let f = fixture(
            generator,
            Duration::from_millis(200),
            Duration::from_secs(3600),
            &[VIDEO_A],
        )
        .await;
        // Poll by hand and drop the future the moment the gate holds a slot
        // for the hash — the narrowest point a real disconnect could hit.
        {
            let req = get(&VIDEO_A);
            let mut fut = std::pin::pin!(f.engine.thumb(&req));
            let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                if std::future::Future::poll(fut.as_mut(), &mut cx).is_ready() {
                    panic!("request finished before the gate was observed; test inconclusive");
                }
                if f.engine.gate.slots.lock().unwrap().contains_key(&VIDEO_A) {
                    break; // drop `fut` here
                }
                assert!(Instant::now() < deadline, "gate slot never appeared");
                tokio::task::yield_now().await;
            }
        }
        tokio::time::sleep(Duration::from_millis(300)).await; // past the budget
        let bytes = f.engine.thumb(&get(&VIDEO_A)).await.unwrap();
        assert!(
            bytes == b"REAL-256",
            "the hash must still get its real thumbnail after a dropped request \
             (got {} bytes, generator calls = {})",
            bytes.len(),
            calls.load(Ordering::SeqCst)
        );
    }

    /// E2 DESK-35 (#441), with the REAL codec: a generation that fails
    /// (corrupt original) is negative-cached for the window — no re-pay, the
    /// #428 guard — and once the window passes, the same hash is generated
    /// again and serves the real thumbnail. Before the fix `make_thumbs`
    /// wrote the placeholder at the final path and the disk hit served it
    /// forever.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_failed_real_generation_is_retried_after_the_window() {
        use crate::thumb_pregen::tests::{fixture, write_jpeg};
        let calls = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&calls);
        let generator: ThumbGen = Arc::new(move |hash: &[u8; 32], src: &Path, root: &Path| {
            c.fetch_add(1, Ordering::SeqCst);
            media_codec::make_thumbs(hash, src, root)
        });
        let a = [0x41; 32];
        let f = fixture(
            Some(generator),
            Duration::from_millis(1500),
            &[(a, "originals/p.jpg".into(), 0)],
        )
        .await;
        let src = f.library().join("originals/p.jpg");
        std::fs::create_dir_all(src.parent().unwrap()).unwrap();
        std::fs::write(&src, b"not a jpeg (yet)").unwrap();
        let placeholder = media_codec::placeholder_jpeg(256);

        assert_eq!(f.engine.thumb(&get(&a)).await.unwrap(), placeholder);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let paths = media_codec::thumb_paths(&f.engine.thumbs_root, &a);
        assert!(
            !paths.t256.exists() && !paths.t1024.exists(),
            "a failure must not land at the final thumb paths"
        );

        // The cause goes away (the user answered the permission prompt).
        write_jpeg(&src);
        assert_eq!(f.engine.thumb(&get(&a)).await.unwrap(), placeholder);
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "inside the window: negative-cached, no second generation"
        );

        tokio::time::sleep(Duration::from_millis(1700)).await;
        let bytes = f.engine.thumb(&get(&a)).await.unwrap();
        assert_ne!(
            bytes, placeholder,
            "after the window the hash is retried and serves the real thumbnail"
        );
        image::load_from_memory(&bytes).expect("real JPEG");
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(
            f.engine
                .db
                .get_asset(&a)
                .await
                .unwrap()
                .unwrap()
                .thumb_state,
            1
        );
    }

    /// `tracing` sink for the log contract.
    #[derive(Clone, Default)]
    struct LogBuf(Arc<Mutex<Vec<u8>>>);
    impl std::io::Write for LogBuf {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    // current_thread on purpose: the owner task runs on this thread, so the
    // thread-local subscriber below sees its events.
    #[tokio::test]
    async fn generation_failures_and_overruns_log_warn_with_hash_prefix_and_reason() {
        let buf = LogBuf::default();
        let sink = buf.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .with_max_level(tracing::Level::WARN)
            .with_writer(move || sink.clone())
            .finish();
        // A second live dispatcher is load-bearing. With exactly one
        // registered, tracing-core takes its `has_just_one` shortcut and
        // computes a callsite's interest from the *registering thread's*
        // default: a parallel test (no subscriber) hitting the shared WARN
        // callsite first caches `Interest::never`, and this test's events
        // vanish (tracing-core 0.1.36 callsite.rs `register_dispatch`).
        // With two, interest is the union over every registered dispatcher.
        let _second = tracing::Dispatch::new(tracing_subscriber::registry());
        let _guard = tracing::subscriber::set_default(subscriber);

        let generator: ThumbGen = Arc::new(|hash: &[u8; 32], _src: &Path, root: &Path| {
            if *hash == VIDEO_B {
                std::thread::sleep(Duration::from_millis(400)); // over budget
            }
            media_codec::ThumbResult {
                paths: media_codec::thumb_paths(root, hash),
                outcome: media_codec::ThumbOutcome::Placeholder {
                    reason: "quicklook on clip.mp4: qlmanage produced no thumbnail".into(),
                },
            }
        });
        let f = fixture(
            generator,
            Duration::from_millis(150),
            Duration::from_secs(3600),
            &[VIDEO_A, VIDEO_B],
        )
        .await;
        f.engine.thumb(&get(&VIDEO_A)).await.unwrap();
        f.engine.thumb(&get(&VIDEO_B)).await.unwrap();
        // Let B's owner task finish so its failure line is written too.
        let deadline = Instant::now() + Duration::from_secs(5);
        while thumb_state(&f, &VIDEO_B).await != 2 {
            assert!(Instant::now() < deadline, "B never finished");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }

        let log = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
        let lines: Vec<&str> = log.lines().collect();
        let has = |prefix: &str, needle: &str| {
            lines
                .iter()
                .any(|l| l.contains("WARN") && l.contains(prefix) && l.contains(needle))
        };
        assert!(
            has(&hash_prefix(&VIDEO_A), "produced no thumbnail"),
            "failure WARN with prefix + reason missing:\n{log}"
        );
        assert!(
            has(&hash_prefix(&VIDEO_B), "timeout"),
            "budget-overrun WARN with prefix + reason missing:\n{log}"
        );
        assert!(
            !log.contains(&hex::encode(VIDEO_A)),
            "log carries a prefix, not the full hash"
        );
    }
}
