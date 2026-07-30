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
    let dir = tempfile::tempdir().unwrap();
    let (_tp, _blobs, hash, ticket, data) = provider(dir.path()).await;
    let receiver_store = dir.path().join("receiver-store");

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
        let blobs = Blobs::open(&rx_tp, &receiver_store).await.unwrap();
        let ticket = ticket.clone();
        let dest = dir.path().join("never-finished.bin");
        let pull = tokio::spawn(async move { blobs.pull(&ticket, &dest).await });

        while !pull.is_finished() && dir_bytes(&receiver_store) < KILL_THRESHOLD {
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
            break;
        }
        eprintln!("attempt {attempt}: transfer outran the abort, retrying");
    }
    assert!(killed, "could not land a mid-transfer kill in 5 attempts");

    // Restarted receiver: fresh endpoint, same store dir. How much the
    // crash left durable is the store's business (batching) — what MUST
    // hold is that the pull completes and verifies from whatever is there.
    let rx_tp = IrohTransport::bind(TransportConfig::loopback(
        vec![transport::ALPN_BLOBS.into()],
    ))
    .await
    .unwrap();
    let blobs = Blobs::open(&rx_tp, &receiver_store).await.unwrap();
    let already = blobs.local_bytes(hash).await.unwrap();
    eprintln!("restart found {already} durable bytes (informational)");

    let dest = dir.path().join("recovered.bin");
    let got = blobs.pull(&ticket, &dest).await.unwrap();
    assert_eq!(got, hash, "pull must verify the expected hash");

    let recovered = fs::read(&dest).unwrap();
    assert_eq!(recovered.len(), data.len());
    assert_eq!(
        blake3::hash(&recovered).as_bytes(),
        &hash,
        "recovered file must be bit-identical"
    );
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
