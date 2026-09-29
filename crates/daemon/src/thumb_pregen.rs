//! IDX-06 (#442): background thumbnail pre-generation.
//!
//! 设计文档的入库流程是「blob 落盘 → EXIF → 缩略图 256 + 预览 1024 → 写索引」，
//! 且「全管线低优先级线程池，索引期间不抢用户机器」。在这之前缩略图只在
//! `thumb.get` 里现场生成：照片墙第一次滚到一屏视频，每一格同时起一个
//! qlmanage（#428 卡一屏的主因）。
//!
//! 这里把入库成功的资产投递给 `media_codec::ThumbPool`（低优先级线程，
//! 并发度 = [`PREGEN_WORKERS`]），另有一条启动补齐：daemon 起来后在后台
//! 按时间线从新到旧扫 `thumb_state=0` 的行（以及 `thumb_state=2`，每次
//! 启动重试一次——DESK-35 #441）。
//!
//! 三条硬约束，各有落点：
//! - **不阻塞入库**：[`ThumbPregen::ingested`] 只往无界通道里塞一个
//!   rel_path，永不 await。
//! - **与 `thumb.get` 共用 gate**：生成前走同一个 `ThumbGate::plan`，收尾走
//!   同一个 `settle_generation`。同一 hash 不论谁先到，底层只生成一次；
//!   后到的 `thumb.get` 按 #440 的规矩加入等待或直接回占位图。
//! - **前台优先**：先拿 permit（总数 = 线程池线程数，所以一旦拿到 gate
//!   槽位，池里必有空闲线程立刻开工，`Slot::InFlight.started` 不会因为
//!   排队而失真），再等 `thumb.get` 自己的生成全部结束，才去占槽位。
//!   视频的 ffmpeg / qlmanage 是子进程，不继承线程优先级——所以让路比
//!   降优先级更要紧。

use std::path::Path;
use std::sync::Arc;

use tokio::sync::{mpsc, OwnedSemaphorePermit, Semaphore};

use crate::query::{hash_prefix, settle_generation, Plan, QueryEngine};

/// Pre-generation concurrency cap. One: a video's first frame is a child
/// process at normal priority, and the whole point is not to compete with
/// the user's machine (or with `thumb.get`) while a library indexes.
pub const PREGEN_WORKERS: usize = 1;

/// Rows per `timeline_page` during the backfill scan (the repo's cap is 1000).
const SCAN_PAGE: u32 = 500;

enum Msg {
    /// An ingest just landed this rel_path in the index.
    Ingested(String),
    /// Scan the whole index for rows still missing thumbs.
    Scan { retry_failed: bool },
}

/// Cheap, cloneable handle the ingest paths hold. Every method is
/// fire-and-forget: none of them can block or fail an ingest.
#[derive(Clone)]
pub struct ThumbPregen {
    tx: mpsc::UnboundedSender<Msg>,
}

impl ThumbPregen {
    /// An ingest succeeded (New / Moved) at `rel_path`. The hash is looked
    /// up by the worker, not here, so the ingest path pays nothing.
    pub fn ingested(&self, rel_path: &str) {
        let _ = self.tx.send(Msg::Ingested(rel_path.to_owned()));
    }

    /// Queue a backfill pass over every `thumb_state=0` row, newest first.
    /// `retry_failed` also retries `thumb_state=2` rows once — the daemon
    /// passes `true` exactly once, at startup (DESK-35 #441).
    pub fn backfill(&self, retry_failed: bool) {
        let _ = self.tx.send(Msg::Scan { retry_failed });
    }
}

struct Worker {
    engine: QueryEngine,
    pool: media_codec::ThumbPool,
    permits: Arc<Semaphore>,
    /// Two overlapping scans would queue every row twice.
    scan_lock: tokio::sync::Mutex<()>,
}

impl QueryEngine {
    /// Start the pre-generation pool (`workers` low-priority threads) and
    /// return the handle the ingest paths use. Must run inside a tokio
    /// runtime. The generator is this engine's — the very function
    /// `thumb.get` calls — so both paths count as one.
    pub fn start_thumb_pregen(&self, workers: usize) -> ThumbPregen {
        let workers = workers.max(1);
        let worker = Arc::new(Worker {
            pool: media_codec::ThumbPool::with_generator(
                workers,
                self.thumbs_root.clone(),
                Arc::clone(&self.generator),
            ),
            engine: self.clone(),
            permits: Arc::new(Semaphore::new(workers)),
            scan_lock: tokio::sync::Mutex::new(()),
        });
        let (tx, mut rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Some(msg) = rx.recv().await {
                match msg {
                    Msg::Ingested(rel) => {
                        // Taking the permit here (not in the task) keeps the
                        // number of live tasks bounded by the cap.
                        let Ok(permit) = Arc::clone(&worker.permits).acquire_owned().await else {
                            return;
                        };
                        let w = Arc::clone(&worker);
                        tokio::spawn(async move { w.ingested(&rel, permit).await });
                    }
                    Msg::Scan { retry_failed } => {
                        let w = Arc::clone(&worker);
                        tokio::spawn(async move { w.scan(retry_failed).await });
                    }
                }
            }
        });
        ThumbPregen { tx }
    }
}

impl Worker {
    async fn ingested(&self, rel_path: &str, permit: OwnedSemaphorePermit) {
        let hash = match self.engine.db.hash_at_rel_path(rel_path).await {
            Ok(Some(h)) => h,
            Ok(None) => return, // evicted again before we got here
            Err(e) => {
                tracing::warn!("IDX-06: 预生成查 hash 失败 {rel_path}: {e}");
                return;
            }
        };
        let Ok(hash) = <[u8; 32]>::try_from(hash.as_slice()) else {
            return;
        };
        self.process(hash, false, permit).await;
    }

    async fn scan(self: Arc<Self>, retry_failed: bool) {
        let _only_one = self.scan_lock.lock().await;
        let mut cursor: Option<String> = None;
        let mut queued = 0u64;
        loop {
            let page = match self
                .engine
                .db
                .timeline_page(cursor.as_deref(), SCAN_PAGE)
                .await
            {
                Ok(p) => p,
                Err(e) => {
                    tracing::warn!("IDX-06: 缩略图补齐扫描失败，下次启动再试: {e}");
                    return;
                }
            };
            for asset in &page.assets {
                let wanted = asset.thumb_state == 0 || (retry_failed && asset.thumb_state == 2);
                if !wanted {
                    continue;
                }
                let Ok(hash) = <[u8; 32]>::try_from(asset.hash.as_slice()) else {
                    continue;
                };
                let Ok(permit) = Arc::clone(&self.permits).acquire_owned().await else {
                    return;
                };
                queued += 1;
                // The permit rides into `process`; at most `workers` rows
                // are in flight, and ingests interleave with the scan.
                let w = Arc::clone(&self);
                tokio::spawn(async move { w.process(hash, retry_failed, permit).await });
            }
            match page.next_cursor {
                Some(c) => cursor = Some(c),
                None => break,
            }
        }
        if queued > 0 {
            tracing::info!("IDX-06: 缩略图补齐处理 {queued} 条（retry_failed={retry_failed}）");
        }
    }

    /// One asset, holding one permit throughout.
    async fn process(&self, hash: [u8; 32], retry_failed: bool, permit: OwnedSemaphorePermit) {
        let _permit = permit;
        let engine = &self.engine;
        // Foreground first: never start while a `thumb.get` generation runs.
        engine.gate.foreground_idle().await;

        let asset = match engine.db.get_asset(&hash).await {
            Ok(Some(a)) => a,
            Ok(None) => return,
            Err(e) => {
                tracing::warn!(hash = %hash_prefix(&hash), "IDX-06: 预生成读资产失败: {e}");
                return;
            }
        };
        // DESK-35 (#441): a `thumb_state=2` row may still have an older
        // build's placeholder JPEGs at the final paths. They look like a
        // cache hit, so the disk check is skipped for it: regenerate, and
        // `settle_generation` purges them if this attempt fails too.
        let legacy_retry = asset.thumb_state == 2;
        if legacy_retry && !retry_failed {
            return;
        }
        if !legacy_retry && both_on_disk(&engine.thumbs_root, &hash) {
            if asset.thumb_state != 1 {
                let _ = engine.db.set_thumb_state(&hash, 1).await;
            }
            return;
        }
        let src = engine.library_root.join(&asset.rel_path);

        // Same gate as `thumb.get`. Nothing below may `.await` before the
        // job is submitted: a waiter's budget runs from the slot's start.
        let tx = match engine.gate.plan(&hash, engine.budget, engine.retry_after) {
            Plan::Spawn { tx, .. } => tx,
            // Someone is generating it, or it failed recently: not ours.
            Plan::Wait { .. } | Plan::Placeholder { .. } => return,
        };
        // A `thumb.get` may have finished this hash between the check above
        // and the reservation — do not generate it a second time.
        if !legacy_retry && both_on_disk(&engine.thumbs_root, &hash) {
            engine.gate.finish(&hash, false, engine.retry_after);
            let _ = tx.send(true);
            return;
        }
        let (reply, result) = tokio::sync::oneshot::channel();
        self.pool.submit_with(hash, src, move |r| {
            let _ = reply.send(r);
        });
        let joined = result
            .await
            .map_err(|_| "pre-generation worker dropped the job".to_string());
        settle_generation(
            &engine.db,
            &engine.gate,
            &engine.thumbs_root,
            &hash,
            joined,
            engine.retry_after,
            tx,
        )
        .await;
    }
}

fn both_on_disk(thumbs_root: &Path, hash: &[u8; 32]) -> bool {
    let paths = media_codec::thumb_paths(thumbs_root, hash);
    paths.t256.is_file() && paths.t1024.is_file()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    use proto::{ThumbGet, ThumbSize};
    use storage::Db;
    use transport::Blobs;

    use crate::query::ThumbGen;

    pub(crate) struct Fixture {
        pub engine: QueryEngine,
        pub root: tempfile::TempDir,
    }

    impl Fixture {
        pub fn library(&self) -> PathBuf {
            self.root.path().join("library")
        }
    }

    /// `assets`: (hash, rel_path, thumb_state).
    pub(crate) async fn fixture(
        generator: Option<ThumbGen>,
        retry_after: Duration,
        assets: &[([u8; 32], String, i64)],
    ) -> Fixture {
        let root = tempfile::tempdir().unwrap();
        let db = Db::open_in_memory().await.unwrap();
        for (i, (h, rel, state)) in assets.iter().enumerate() {
            db.insert_asset(&storage::Asset {
                hash: h.to_vec(),
                rel_path: rel.clone(),
                media_type: "image/jpeg".into(),
                bytes: 42,
                // Distinct taken_at: the scan walks the timeline newest-first.
                taken_at: Some(1_690_000_000_000 + i as i64),
                width: None,
                height: None,
                src_device: vec![9u8; 32],
                added_at: 1_690_000_000_000,
                thumb_state: *state,
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
        if let Some(g) = generator {
            engine.generator = g;
        }
        engine.budget = Duration::from_secs(3);
        engine.retry_after = retry_after;
        Fixture { engine, root }
    }

    pub(crate) fn write_jpeg(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        image::RgbImage::from_fn(320, 240, |x, y| {
            image::Rgb([(x % 256) as u8, (y % 256) as u8, 90])
        })
        .save_with_format(path, image::ImageFormat::Jpeg)
        .unwrap();
    }

    fn h(n: u8) -> [u8; 32] {
        [n; 32]
    }

    async fn state(f: &Fixture, hash: &[u8; 32]) -> i64 {
        f.engine
            .db
            .get_asset(hash)
            .await
            .unwrap()
            .unwrap()
            .thumb_state
    }

    async fn wait_state(f: &Fixture, hash: &[u8; 32], want: i64, what: &str) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while state(f, hash).await != want {
            assert!(
                Instant::now() < deadline,
                "{what}: thumb_state never reached {want}"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    fn get(hash: &[u8; 32]) -> ThumbGet {
        ThumbGet {
            hash: hex::encode(hash),
            size: ThumbSize::S256,
        }
    }

    /// Writes fake "real" thumbs for `hash` under `root`.
    fn write_fake_thumbs(root: &Path, hash: &[u8; 32]) -> media_codec::ThumbResult {
        let paths = media_codec::thumb_paths(root, hash);
        std::fs::create_dir_all(paths.t256.parent().unwrap()).unwrap();
        std::fs::write(&paths.t256, b"REAL-256").unwrap();
        std::fs::write(&paths.t1024, b"REAL-1024").unwrap();
        media_codec::ThumbResult {
            paths,
            outcome: media_codec::ThumbOutcome::Generated,
        }
    }

    /// E2: the startup backfill picks up `thumb_state=0` rows and generates
    /// both sizes with the real codec, on the low-priority pool's threads.
    #[tokio::test(flavor = "multi_thread")]
    async fn backfill_generates_every_state_0_row_on_pool_threads() {
        let threads = Arc::new(Mutex::new(Vec::new()));
        let t = Arc::clone(&threads);
        let generator: ThumbGen = Arc::new(move |hash: &[u8; 32], src: &Path, root: &Path| {
            t.lock()
                .unwrap()
                .push(std::thread::current().name().unwrap_or("").to_owned());
            media_codec::make_thumbs(hash, src, root)
        });
        let rows: Vec<_> = (1..=3u8)
            .map(|i| (h(i), format!("originals/p{i}.jpg"), 0))
            .collect();
        let f = fixture(Some(generator), Duration::from_secs(600), &rows).await;
        for (_, rel, _) in &rows {
            write_jpeg(&f.library().join(rel));
        }

        let pregen = f.engine.start_thumb_pregen(PREGEN_WORKERS);
        pregen.backfill(false);

        for (hash, _, _) in &rows {
            wait_state(&f, hash, 1, "backfill").await;
            let paths = media_codec::thumb_paths(&f.engine.thumbs_root, hash);
            for (p, edge) in [(&paths.t256, 256), (&paths.t1024, 1024)] {
                let img = image::open(p).unwrap_or_else(|e| panic!("{p:?} must decode: {e}"));
                assert!(img.width().max(img.height()) <= edge);
            }
        }
        let threads = threads.lock().unwrap().clone();
        assert_eq!(threads.len(), 3, "one generation per row");
        assert!(
            threads.iter().all(|n| n.starts_with("thumb-")),
            "pre-generation must run on the low-priority pool, ran on {threads:?}"
        );
    }

    /// E2: pre-generation and `thumb.get` on the same hash share the gate —
    /// the generator runs exactly once and the request gets the real thumb.
    #[tokio::test(flavor = "multi_thread")]
    async fn pregen_and_thumb_get_on_one_hash_generate_once() {
        let calls = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&calls);
        let generator: ThumbGen = Arc::new(move |hash: &[u8; 32], _src: &Path, root: &Path| {
            c.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(Duration::from_millis(500));
            write_fake_thumbs(root, hash)
        });
        let a = h(0xa1);
        let f = fixture(
            Some(generator),
            Duration::from_secs(600),
            &[(a, "originals/a.jpg".into(), 0)],
        )
        .await;
        let pregen = f.engine.start_thumb_pregen(PREGEN_WORKERS);
        pregen.ingested("originals/a.jpg");
        // Pre-generation goes first: wait until its generation is running.
        let deadline = Instant::now() + Duration::from_secs(5);
        while calls.load(Ordering::SeqCst) == 0 {
            assert!(Instant::now() < deadline, "pre-generation never started");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        let bytes = f.engine.thumb(&get(&a)).await.unwrap();
        assert_eq!(bytes, b"REAL-256", "thumb.get joins the running generation");
        wait_state(&f, &a, 1, "pregen").await;
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "pre-generation + thumb.get on one hash must generate once"
        );
    }

    /// E2: concurrency never exceeds the cap (and does reach it — a cap of
    /// 2 that only ever ran one at a time would not prove the bound).
    #[tokio::test(flavor = "multi_thread")]
    async fn pregen_concurrency_never_exceeds_the_cap() {
        const CAP: usize = 2;
        let now = Arc::new(AtomicUsize::new(0));
        let max = Arc::new(AtomicUsize::new(0));
        let (n, m) = (Arc::clone(&now), Arc::clone(&max));
        let generator: ThumbGen = Arc::new(move |hash: &[u8; 32], _src: &Path, root: &Path| {
            let cur = n.fetch_add(1, Ordering::SeqCst) + 1;
            m.fetch_max(cur, Ordering::SeqCst);
            std::thread::sleep(Duration::from_millis(120));
            n.fetch_sub(1, Ordering::SeqCst);
            write_fake_thumbs(root, hash)
        });
        let rows: Vec<_> = (1..=8u8)
            .map(|i| (h(i), format!("originals/c{i}.jpg"), 0))
            .collect();
        let f = fixture(Some(generator), Duration::from_secs(600), &rows).await;
        let pregen = f.engine.start_thumb_pregen(CAP);
        pregen.backfill(false);
        // Ingests interleave with the scan and share the same cap.
        for (_, rel, _) in rows.iter().step_by(2) {
            pregen.ingested(rel);
        }
        for (hash, _, _) in &rows {
            wait_state(&f, hash, 1, "cap").await;
        }
        let max = max.load(Ordering::SeqCst);
        assert!(max <= CAP, "{max} generations ran at once, cap is {CAP}");
        assert_eq!(max, CAP, "the pool never used its full width");
    }

    /// E2 (thumb.get 优先): while a `thumb.get` generation runs, the
    /// pre-generation pool does not start new work.
    #[tokio::test(flavor = "multi_thread")]
    async fn pregen_yields_while_a_thumb_get_generation_runs() {
        type Log = Arc<Mutex<Vec<(u8, &'static str, Instant)>>>;
        let log: Log = Arc::default();
        let l = Arc::clone(&log);
        let generator: ThumbGen = Arc::new(move |hash: &[u8; 32], _src: &Path, root: &Path| {
            l.lock().unwrap().push((hash[0], "start", Instant::now()));
            std::thread::sleep(Duration::from_millis(400));
            let r = write_fake_thumbs(root, hash);
            l.lock().unwrap().push((hash[0], "end", Instant::now()));
            r
        });
        let (fg, bg) = (h(0xf0), h(0xb0));
        let f = fixture(
            Some(generator),
            Duration::from_secs(600),
            &[
                (fg, "originals/fg.jpg".into(), 0),
                (bg, "originals/bg.jpg".into(), 0),
            ],
        )
        .await;
        let pregen = f.engine.start_thumb_pregen(PREGEN_WORKERS);
        let engine = f.engine.clone();
        let foreground = tokio::spawn(async move { engine.thumb(&get(&fg)).await.unwrap() });
        let deadline = Instant::now() + Duration::from_secs(5);
        while log.lock().unwrap().is_empty() {
            assert!(Instant::now() < deadline, "foreground never started");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        pregen.ingested("originals/bg.jpg");
        foreground.await.unwrap();
        wait_state(&f, &bg, 1, "background").await;

        let log = log.lock().unwrap().clone();
        let at = |who: u8, what: &str| {
            log.iter()
                .find(|(h, w, _)| *h == who && *w == what)
                .map(|(_, _, t)| *t)
                .unwrap()
        };
        assert!(
            at(0xb0, "start") >= at(0xf0, "end"),
            "pre-generation started while thumb.get was still generating: {log:?}"
        );
    }

    /// E2 DESK-35 (#441): a `thumb_state=2` row left by an older build (the
    /// placeholder JPEG sitting at the final paths, which `thumb.get` serves
    /// as a disk hit forever) is retried by the startup backfill — and only
    /// by that one (`retry_failed = true`).
    #[tokio::test(flavor = "multi_thread")]
    async fn startup_backfill_retries_legacy_placeholder_rows() {
        let a = h(0x2a);
        let f = fixture(
            None,
            Duration::from_secs(600),
            &[(a, "originals/l.jpg".into(), 2)],
        )
        .await;
        write_jpeg(&f.library().join("originals/l.jpg"));
        // What the pre-#441 codec left behind.
        let paths = media_codec::thumb_paths(&f.engine.thumbs_root, &a);
        std::fs::create_dir_all(paths.t256.parent().unwrap()).unwrap();
        let placeholder = media_codec::placeholder_jpeg(256);
        std::fs::write(&paths.t256, &placeholder).unwrap();
        std::fs::write(&paths.t1024, media_codec::placeholder_jpeg(1024)).unwrap();
        assert_eq!(f.engine.thumb(&get(&a)).await.unwrap(), placeholder);

        let pregen = f.engine.start_thumb_pregen(PREGEN_WORKERS);
        // The hourly (adopt) backfill leaves failed rows alone …
        pregen.backfill(false);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(state(&f, &a).await, 2, "retry_failed=false must not retry");
        // … the startup one retries them.
        pregen.backfill(true);
        wait_state(&f, &a, 1, "legacy retry").await;
        let bytes = f.engine.thumb(&get(&a)).await.unwrap();
        assert_ne!(
            bytes, placeholder,
            "a real thumbnail replaced the placeholder"
        );
        image::load_from_memory(&bytes).expect("real JPEG");
    }

    /// E2 DESK-35 (#441): when that retry fails again, the stale placeholder
    /// files are removed, so once the negative-cache window passes
    /// `thumb.get` retries instead of hitting disk forever.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_failed_legacy_retry_clears_the_stale_placeholder() {
        let a = h(0x2b);
        let f = fixture(
            None,
            Duration::from_secs(600),
            &[(a, "originals/bad.jpg".into(), 2)],
        )
        .await;
        let src = f.library().join("originals/bad.jpg");
        std::fs::create_dir_all(src.parent().unwrap()).unwrap();
        std::fs::write(&src, b"still not a jpeg").unwrap();
        let paths = media_codec::thumb_paths(&f.engine.thumbs_root, &a);
        std::fs::create_dir_all(paths.t256.parent().unwrap()).unwrap();
        std::fs::write(&paths.t256, media_codec::placeholder_jpeg(256)).unwrap();
        std::fs::write(&paths.t1024, media_codec::placeholder_jpeg(1024)).unwrap();

        let pregen = f.engine.start_thumb_pregen(PREGEN_WORKERS);
        pregen.backfill(true);
        let deadline = Instant::now() + Duration::from_secs(10);
        while paths.t256.exists() || paths.t1024.exists() {
            assert!(
                Instant::now() < deadline,
                "stale placeholder files were never removed"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert_eq!(state(&f, &a).await, 2);
    }
}
