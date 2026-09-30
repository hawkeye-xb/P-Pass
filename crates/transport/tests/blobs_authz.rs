//! #546: the daemon-shape blobs data plane (`attach_to_listener` + `listen`)
//! serves only peers its gate admits — checked when the connection arrives
//! and again for every request on it — and never accepts a push.

use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use iroh_blobs::protocol::{ChunkRangesSeq, PushRequest};
use iroh_blobs::store::fs::FsStore;
use iroh_blobs::ticket::BlobTicket;
use transport::{Blobs, IrohTransport, NodeId, PeerGate, Transport, TransportConfig};

/// A whitelist the test can edit (pair / revoke) plus a count of how many
/// times the gate was asked.
#[derive(Clone, Default)]
struct Whitelist {
    allowed: Arc<Mutex<HashSet<NodeId>>>,
    asked: Arc<AtomicUsize>,
}

impl Whitelist {
    fn gate(&self) -> PeerGate {
        let allowed = Arc::clone(&self.allowed);
        let asked = Arc::clone(&self.asked);
        Arc::new(move |peer| {
            asked.fetch_add(1, Ordering::SeqCst);
            let ok = allowed.lock().unwrap().contains(&peer);
            Box::pin(async move { ok })
        })
    }
    fn pair(&self, peer: NodeId) {
        self.allowed.lock().unwrap().insert(peer);
    }
    fn revoke(&self, peer: NodeId) {
        self.allowed.lock().unwrap().remove(&peer);
    }
    fn asked(&self) -> usize {
        self.asked.load(Ordering::SeqCst)
    }
}

struct Daemon {
    tp: IrohTransport,
    blobs: Blobs,
}

async fn daemon(dir: &Path, whitelist: &Whitelist) -> Daemon {
    let tp = IrohTransport::bind(TransportConfig::loopback(vec![
        transport::ALPN_CTRL.into(),
        transport::ALPN_BLOBS.into(),
    ]))
    .await
    .unwrap();
    let blobs = Blobs::open(&tp, &dir.join("daemon-store")).await.unwrap();
    blobs.attach_to_listener(whitelist.gate());
    // The daemon's accept loop: blobs connections are dispatched inside
    // it; ctrl connections would surface on this stream.
    let listener = tp.clone();
    tokio::spawn(async move {
        let incoming = listener.listen().await;
        tokio::pin!(incoming);
        while std::future::poll_fn(|cx| incoming.as_mut().poll_next(cx))
            .await
            .is_some()
        {}
    });
    Daemon { tp, blobs }
}

use futures_core::Stream as _;

/// Import `bytes` into the daemon's store; returns (hash, ticket).
async fn seed(dir: &Path, d: &Daemon, name: &str, bytes: &[u8]) -> ([u8; 32], String) {
    let src = dir.join(name);
    fs::write(&src, bytes).unwrap();
    let hash = *blake3::hash(bytes).as_bytes();
    let ticket = d.blobs.push(hash, &src).await.unwrap();
    (hash, ticket)
}

async fn client(dir: &Path, name: &str, d: &Daemon) -> (IrohTransport, Blobs) {
    let tp = IrohTransport::bind(TransportConfig::loopback(
        vec![transport::ALPN_BLOBS.into()],
    ))
    .await
    .unwrap();
    tp.add_peer(d.tp.local_addr());
    let blobs = Blobs::open(&tp, &dir.join(name)).await.unwrap();
    (tp, blobs)
}

#[tokio::test(flavor = "multi_thread")]
async fn unpaired_identity_cannot_fetch_by_hash() {
    let dir = tempfile::tempdir().unwrap();
    let whitelist = Whitelist::default();
    let d = daemon(dir.path(), &whitelist).await;
    let (hash, ticket) = seed(dir.path(), &d, "photo.jpg", b"a private original").await;

    let (_stranger_tp, stranger) = client(dir.path(), "stranger-store", &d).await;
    assert!(
        stranger.fetch_from(d.tp.node_id(), hash).await.is_err(),
        "a never-paired identity must not fetch a daemon blob by hash"
    );
    let dest = dir.path().join("leaked.jpg");
    assert!(
        stranger.pull(&ticket, &dest).await.is_err(),
        "a full ticket does not help an unpaired identity either"
    );
    assert_eq!(
        stranger.local_bytes(hash).await.unwrap(),
        0,
        "no byte left the daemon"
    );
    assert!(!dest.exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn paired_peer_fetches_and_revocation_cuts_its_open_connection() {
    let dir = tempfile::tempdir().unwrap();
    let whitelist = Whitelist::default();
    let d = daemon(dir.path(), &whitelist).await;
    let (first, _) = seed(dir.path(), &d, "one.jpg", b"first original").await;
    let (second, _) = seed(dir.path(), &d, "two.jpg", b"second original").await;

    let (phone_tp, phone) = client(dir.path(), "phone-store", &d).await;
    whitelist.pair(phone_tp.node_id());
    phone.fetch_from(d.tp.node_id(), first).await.unwrap();
    assert_eq!(
        phone.local_bytes(first).await.unwrap(),
        b"first original".len() as u64
    );
    // One connection admitted + one request admitted.
    assert_eq!(whitelist.asked(), 2);

    whitelist.revoke(phone_tp.node_id());
    // `fetch_from` reuses the cached (daemon, ALPN_BLOBS) connection, so
    // this request travels on the connection admitted while paired.
    assert!(
        phone.fetch_from(d.tp.node_id(), second).await.is_err(),
        "a revoked device must be refused on its already-open connection"
    );
    assert_eq!(
        whitelist.asked(),
        3,
        "the refusal came from the per-request check on the SAME connection \
         (no new connection was admitted or asked about)"
    );
    assert_eq!(phone.local_bytes(second).await.unwrap(), 0);

    // And a fresh connection after revocation is refused too.
    assert!(phone.fetch_from(d.tp.node_id(), second).await.is_err());
    assert_eq!(phone.local_bytes(second).await.unwrap(), 0);
}

/// iroh-blobs 0.103 lets push requests through unless the event handler
/// refuses them (its `push: Disabled` mask is not consulted). Nobody —
/// paired or not — may write into the daemon's store over the network.
#[tokio::test(flavor = "multi_thread")]
async fn nobody_can_push_into_the_daemon_store() {
    let dir = tempfile::tempdir().unwrap();
    let whitelist = Whitelist::default();
    let d = daemon(dir.path(), &whitelist).await;
    let (_, ticket) = seed(dir.path(), &d, "anchor.jpg", b"anchor").await;
    let daemon_addr = ticket.parse::<BlobTicket>().unwrap().addr().clone();

    for paired in [false, true] {
        let ep = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
            .bind()
            .await
            .unwrap();
        if paired {
            whitelist.pair(NodeId(*ep.id().as_bytes()));
        }
        let store_dir = dir.path().join(format!("pusher-{paired}"));
        let store = FsStore::load(&store_dir).await.unwrap();
        let payload = format!("planted by pusher paired={paired}").into_bytes();
        let tag = store.blobs().add_bytes(payload.clone()).await.unwrap();
        let hash = *tag.hash.as_bytes();

        let conn = ep
            .connect(daemon_addr.clone(), transport::ALPN_BLOBS.as_bytes())
            .await;
        if let Ok(conn) = conn {
            let _ = store
                .remote()
                .execute_push(conn, PushRequest::new(tag.hash, ChunkRangesSeq::root()))
                .complete()
                .await;
        }
        // The provider finishes writing a push after the pusher's side
        // reports done; watch the store for a while before concluding.
        for _ in 0..20 {
            if d.blobs.local_bytes(hash).await.unwrap() != 0 {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert_eq!(
            d.blobs.local_bytes(hash).await.unwrap(),
            0,
            "push (paired={paired}) must not plant data in the daemon store"
        );
        store.shutdown().await.ok();
        ep.close().await;
    }
}
