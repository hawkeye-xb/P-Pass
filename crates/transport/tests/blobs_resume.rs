//! T-021 acceptance: 50MB transfer, receiver killed mid-flight, restarted
//! receiver resumes from partial data and the final file verifies BLAKE3.
//!
//! Two complementary tests, because a real kill has two separable claims:
//!
//! 1. **Crash safety** (`kill_mid_transfer_…`): the receiving task is
//!    aborted with no goodbye mid-transfer, a fresh endpoint reopens the
//!    same store, and the pull completes bit-identical — however many
//!    bytes the crash left durable (that amount is timing-dependent by
//!    the store's own batching design, so it is logged, not asserted).
//! 2. **Resume actually resumes** (`seeded_partial_…`): the store is
//!    seeded with a verified 8 MiB prefix (what a kill leaves behind,
//!    made deterministic), and the follow-up pull fetches only the
//!    missing remainder and verifies.

use std::fs;
use std::path::Path;

use transport::{Blobs, IrohTransport, TransportConfig};

const PAYLOAD: usize = 50 * 1024 * 1024;

// FIX-SC2 (2026-08-10): 取证桩——带时间戳的阶段进度标记。该测试在
// pr.yml lint+test 里 300s TIMEOUT 过 3 次（隔离复跑 6.4s 过），量级差
// 说明是并发时序下的 stall 而非慢。nextest 默认捕获 stderr、仅失败时
// 连同输出一起显示——所以每次 TIMEOUT 的日志会直接指出卡在哪个阶段，
// 变 rerun 碰运气为每次失败都在积累证据（用户拍板的取证桩方向）。
fn stamp(t0: &std::time::Instant, phase: &str, detail: impl std::fmt::Display) {
    eprintln!("[+{:>6.1}s] {phase}: {detail}", t0.elapsed().as_secs_f64());
}

/// Deterministic 50MB that doesn't compress to nothing (xorshift bytes).
fn payload() -> Vec<u8> {
    let mut v = Vec::with_capacity(PAYLOAD);
    let mut s: u64 = 0x5EED_2026_0730_0021;
    while v.len() < PAYLOAD {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        v.extend_from_slice(&s.to_le_bytes());
    }
    v.truncate(PAYLOAD);
    v
}

async fn provider(dir: &Path) -> (IrohTransport, Blobs, [u8; 32], String, Vec<u8>) {
    let tp = IrohTransport::bind(TransportConfig::loopback(
        vec![transport::ALPN_BLOBS.into()],
    ))
    .await
    .unwrap();
    let data = payload();
    let src = dir.join("original.bin");
    fs::write(&src, &data).unwrap();
    let hash = *blake3::hash(&data).as_bytes();

    let mut blobs = Blobs::open(&tp, &dir.join("provider-store")).await.unwrap();
    blobs.serve();
    let ticket = blobs.push(hash, &src).await.unwrap();
    (tp, blobs, hash, ticket, data)
}

#[tokio::test(flavor = "multi_thread")]
async fn kill_mid_transfer_then_resume_verifies() {
    let t0 = std::time::Instant::now();
    stamp(&t0, "setup", "tempdir + provider");
    let dir = tempfile::tempdir().unwrap();
    let (_tp, _blobs, hash, ticket, data) = provider(dir.path()).await;
    let receiver_store = dir.path().join("receiver-store");
    stamp(&t0, "setup", "provider ready");

    // Phase 1: start pulling, kill the receiver mid-flight. The store dir
    // is probed via the file system only — opening the redb store from a
    // second handle would block on its lock. If the localhost transfer
    // ever outruns the abort, wipe and retry with a fresh store (the kill
    // must land mid-flight for the test to mean anything).
    // 8 MiB: safely above redb's fixed file overhead (~1 MiB, present
    // before any payload arrives) and safely below the 50 MiB payload.
    const KILL_THRESHOLD: u64 = 8 * 1024 * 1024;
    let mut killed = false;
    for attempt in 0..5 {
        let _ = fs::remove_dir_all(&receiver_store);
        let rx_tp =
            IrohTransport::bind(TransportConfig::loopback(
                vec![transport::ALPN_BLOBS.into()],
            ))
            .await
            .unwrap();
        stamp(&t0, &format!("attempt {attempt}"), "receiver bound");
        let blobs = Blobs::open(&rx_tp, &receiver_store).await.unwrap();
        let ticket = ticket.clone();
        let dest = dir.path().join("never-finished.bin");
        let pull = tokio::spawn(async move { blobs.pull(&ticket, &dest).await });
        stamp(&t0, &format!("attempt {attempt}"), "pull spawned");

        // Deadline: if the pull never even starts moving bytes (slow CI
        // runner, transient bind failure), fail fast with a diagnosis
        // instead of spinning until the CI job's global timeout kills us.
        let started = std::time::Instant::now();
        let mut last_stamp = 0u64;
        while !pull.is_finished() && dir_bytes(&receiver_store) < KILL_THRESHOLD {
            // FIX-SC2: 周期打点——每 ~250ms 报一次已落盘字节数。若卡在
            // 传输前/传输中，日志直接显示字节不再增长（stall 现场）。
            let bytes = dir_bytes(&receiver_store);
            if bytes / 1024 / 1024 != last_stamp {
                last_stamp = bytes / 1024 / 1024;
                stamp(
                    &t0,
                    &format!("attempt {attempt}"),
                    format_args!("waiting for kill threshold: {bytes} bytes on disk"),
                );
            }
            assert!(
                started.elapsed() < std::time::Duration::from_secs(120),
                "pull moved no bytes in 120 s — transfer never started                  (store bytes: {})",
                dir_bytes(&receiver_store)
            );
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
        pull.abort(); // kill: no graceful anything
        let was_killed = match pull.await {
            Err(e) => e.is_cancelled(),
            Ok(_) => false, // finished before the abort landed — retry
        };
        rx_tp.close().await;
        // Let the aborted task's store handle drop fully (releases the
        // redb lock) before the restarted receiver opens the same dir.
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        if was_killed {
            killed = true;
            stamp(
                &t0,
                &format!("attempt {attempt}"),
                "kill landed mid-transfer",
            );
            break;
        }
        eprintln!("attempt {attempt}: transfer outran the abort, retrying");
        stamp(
            &t0,
            &format!("attempt {attempt}"),
            "transfer outran abort, retrying",
        );
    }
    assert!(killed, "could not land a mid-transfer kill in 5 attempts");

    // Restarted receiver: fresh endpoint, same store dir. How much the
    // crash left durable is the store's business (batching) — what MUST
    // hold is that the pull completes and verifies from whatever is there.
    // FIX-SC2: 细化打点——CI 现场停在「rebinding receiver endpoint」，
    // 但 bind / store open / local_bytes 之间没有桩，无法定位卡点。
    // 三步分开打：bind 完 / store 开完 / durable 读完。
    stamp(&t0, "restart", "rebinding receiver endpoint");
    let rx_tp = IrohTransport::bind(TransportConfig::loopback(
        vec![transport::ALPN_BLOBS.into()],
    ))
    .await
    .unwrap();
    stamp(&t0, "restart", "endpoint bound");
    let blobs = Blobs::open(&rx_tp, &receiver_store).await.unwrap();
    stamp(&t0, "restart", "store opened");
    let already = blobs.local_bytes(hash).await.unwrap();
    eprintln!("restart found {already} durable bytes (informational)");
    stamp(
        &t0,
        "restart",
        format_args!("durable bytes on restart: {already}"),
    );

    let dest = dir.path().join("recovered.bin");
    stamp(&t0, "restart", "resume pull started");
    let got = blobs.pull(&ticket, &dest).await.unwrap();
    assert_eq!(got, hash, "pull must verify the expected hash");
    stamp(&t0, "restart", "resume pull completed + hash verified");

    let recovered = fs::read(&dest).unwrap();
    assert_eq!(recovered.len(), data.len());
    assert_eq!(
        blake3::hash(&recovered).as_bytes(),
        &hash,
        "recovered file must be bit-identical"
    );
    stamp(&t0, "verify", "recovered file bit-identical, ALL GREEN");
    blobs.close().await;
    rx_tp.close().await;
}

/// Resume, made deterministic: the receiver store is seeded with a
/// BLAKE3-verified 8 MiB prefix (replicating iroh-blobs' own test-side
/// `create_n0_bao`), so "restart found partial data" is a fact, not a
/// race. The pull must then complete from there and verify.
#[tokio::test(flavor = "multi_thread")]
async fn seeded_partial_resumes_and_verifies() {
    use bao_tree::io::outboard::PreOrderMemOutboard;
    use bao_tree::{ChunkNum, ChunkRanges};

    let dir = tempfile::tempdir().unwrap();
    let (_tp, _blobs, hash, ticket, data) = provider(dir.path()).await;
    let receiver_store = dir.path().join("receiver-store");

    // Seed: verified bao stream for the first 8 MiB (8192 KiB-chunks).
    let seed_chunks = 8 * 1024;
    let ranges = ChunkRanges::from(..ChunkNum(seed_chunks));
    let outboard = PreOrderMemOutboard::create(&data[..], iroh_blobs::store::IROH_BLOCK_SIZE);
    assert_eq!(
        outboard.root.as_bytes(),
        &hash,
        "bao root must be the same BLAKE3 the index uses"
    );
    let mut encoded = Vec::new();
    encoded.extend_from_slice(&(data.len() as u64).to_le_bytes());
    bao_tree::io::sync::encode_ranges_validated(&data[..], &outboard, &ranges, &mut encoded)
        .unwrap();
    {
        let store = iroh_blobs::store::fs::FsStore::load(&receiver_store)
            .await
            .unwrap();
        store
            .blobs()
            .import_bao_bytes(iroh_blobs::Hash::from_bytes(hash), ranges, encoded)
            .await
            .unwrap();
        store.shutdown().await.unwrap();
    }

    let rx_tp = IrohTransport::bind(TransportConfig::loopback(
        vec![transport::ALPN_BLOBS.into()],
    ))
    .await
    .unwrap();
    let blobs = Blobs::open(&rx_tp, &receiver_store).await.unwrap();
    let already = blobs.local_bytes(hash).await.unwrap();
    assert_eq!(
        already,
        seed_chunks * 1024,
        "the seeded 8 MiB prefix must be visible as durable local data"
    );

    let dest = dir.path().join("resumed.bin");
    let got = blobs.pull(&ticket, &dest).await.unwrap();
    assert_eq!(got, hash);
    assert_eq!(
        blake3::hash(&fs::read(&dest).unwrap()).as_bytes(),
        &hash,
        "resumed file must be bit-identical"
    );
    blobs.close().await;
    rx_tp.close().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn push_rejects_hash_mismatch() {
    let dir = tempfile::tempdir().unwrap();
    let tp = IrohTransport::bind(TransportConfig::loopback(
        vec![transport::ALPN_BLOBS.into()],
    ))
    .await
    .unwrap();
    let blobs = Blobs::open(&tp, &dir.path().join("store")).await.unwrap();
    let src = dir.path().join("f.bin");
    fs::write(&src, b"actual content").unwrap();

    let err = blobs.push([0xEE; 32], &src).await.unwrap_err();
    assert!(
        err.to_string().contains("no longer matches"),
        "wrong-hash push must fail loudly: {err}"
    );
}

/// Total bytes under a directory tree (the receiver store's partial data).
fn dir_bytes(dir: &Path) -> u64 {
    let mut total = 0;
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            total += dir_bytes(&p);
        } else if let Ok(m) = e.metadata() {
            total += m.len();
        }
    }
    total
}

/// T-032 precondition: after an inbound ctrl connection, the LISTENER can
/// dial back to the dialer (address observed on accept) and pull a blob —
/// the backup receive path's transport shape.
#[tokio::test(flavor = "multi_thread")]
async fn listener_can_dial_back_and_fetch() {
    let dir = tempfile::tempdir().unwrap();

    // "Storage side": listens on ctrl + blobs.
    let storage_tp = IrohTransport::bind(TransportConfig::loopback(vec![
        transport::ALPN_CTRL.into(),
        transport::ALPN_BLOBS.into(),
    ]))
    .await
    .unwrap();
    let storage_blobs = Blobs::open(&storage_tp, &dir.path().join("storage-store"))
        .await
        .unwrap();
    use transport::Transport as _;
    let incoming = storage_tp.listen().await;
    tokio::pin!(incoming);

    // "Phone": serves a blob, dials the storage side over ctrl.
    let phone_tp = IrohTransport::bind(TransportConfig::loopback(vec![
        transport::ALPN_CTRL.into(),
        transport::ALPN_BLOBS.into(),
    ]))
    .await
    .unwrap();
    let content = b"a photo, allegedly".to_vec();
    let src = dir.path().join("photo.jpg");
    fs::write(&src, &content).unwrap();
    let hash = *blake3::hash(&content).as_bytes();
    let mut phone_blobs = Blobs::open(&phone_tp, &dir.path().join("phone-store"))
        .await
        .unwrap();
    phone_blobs.serve();
    phone_blobs.import(hash, &src).await.unwrap();

    phone_tp.add_peer(storage_tp.local_addr());
    let mut stream = phone_tp
        .connect(storage_tp.node_id(), transport::ALPN_CTRL)
        .await
        .unwrap();
    stream
        .send_frame(
            &5u32
                .to_le_bytes()
                .iter()
                .chain(b"hello")
                .copied()
                .collect::<Vec<_>>(),
        )
        .await
        .unwrap();

    // Storage side accepts, then dials BACK for the blob — no ticket, no
    // discovery, only the address observed on accept.
    use futures_core::Stream as _;
    let conn = std::future::poll_fn(|cx| incoming.as_mut().poll_next(cx))
        .await
        .expect("inbound ctrl connection");
    let phone_id = conn.peer();
    storage_blobs.fetch_from(phone_id, hash).await.unwrap();
    let dest = dir.path().join("landed.jpg");
    storage_blobs.export_to(hash, &dest).await.unwrap();
    assert_eq!(fs::read(&dest).unwrap(), content);
}
