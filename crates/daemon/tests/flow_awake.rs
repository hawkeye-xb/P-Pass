//! NET-26 (#419): background flow fetches hold the platform "stay awake"
//! assertion — acquired when the first task starts, released when the last
//! one ends, whether it completed, failed, or was cancelled. The platform
//! guard is replaced by an injected counting fake.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use daemon::awake::{AwakeHold, AwakeToken};
use daemon::flow_delivery::FlowDelivery;
use proto::FlowFetchRequest;
use storage::{Db, Device, Role};
use tempfile::{tempdir, TempDir};
use transport::{Blobs, IrohTransport, NodeId, TransportConfig, ALPN_BLOBS};

fn request(seq: u64, lease: &str, hash: [u8; 32], provider: String) -> FlowFetchRequest {
    FlowFetchRequest {
        queue_sequence: seq,
        pairing_epoch: "epoch-current".into(),
        lease_token: lease.into(),
        content_hash: hex::encode(hash),
        file_name: format!("IMG_{seq:04}.jpg"),
        media_type: "image/jpeg".into(),
        provider,
        capture_at_ms: 0,
        size_bytes: 0,
    }
}

async fn paired_db(peer: NodeId) -> Db {
    let db = Db::open_in_memory().await.unwrap();
    db.upsert_device(&Device {
        node_id: peer.0.to_vec(),
        name: "phone".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
        revoked_at: None,
        revoked_by: None,
    })
    .await
    .unwrap();
    db.set_pairing_epoch(&peer.0, "epoch-current")
        .await
        .unwrap();
    db
}

/// Counting stand-in for `platform::assert_awake`.
struct FakeAwake {
    acquired: Arc<AtomicUsize>,
    released: Arc<AtomicUsize>,
}

struct FakeGuard(Arc<AtomicUsize>);
impl Drop for FakeGuard {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

impl FakeAwake {
    fn new() -> (Self, AwakeHold) {
        let acquired = Arc::new(AtomicUsize::new(0));
        let released = Arc::new(AtomicUsize::new(0));
        let (a, r) = (Arc::clone(&acquired), Arc::clone(&released));
        let hold = AwakeHold::new(move || {
            a.fetch_add(1, Ordering::SeqCst);
            Some(Box::new(FakeGuard(Arc::clone(&r))) as AwakeToken)
        });
        (Self { acquired, released }, hold)
    }

    fn acquired(&self) -> usize {
        self.acquired.load(Ordering::SeqCst)
    }

    fn released(&self) -> usize {
        self.released.load(Ordering::SeqCst)
    }

    async fn wait_released(&self, want: usize, budget: Duration) {
        let started = std::time::Instant::now();
        while self.released() < want {
            assert!(
                started.elapsed() < budget,
                "awake assertion not released within {budget:?} (acquired={}, released={})",
                self.acquired(),
                self.released()
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

struct Fixture {
    root: TempDir,
    provider_transport: IrohTransport,
    provider_blobs: Blobs,
    receiver_blobs: Arc<Blobs>,
    _receiver_transport: IrohTransport,
}

impl Fixture {
    async fn new(serve: bool) -> Self {
        let root = tempdir().unwrap();
        let provider_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let mut provider_blobs =
            Blobs::open(&provider_transport, &root.path().join("provider-store"))
                .await
                .unwrap();
        if serve {
            provider_blobs.serve();
        }
        let receiver_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let receiver_blobs = Arc::new(
            Blobs::open(&receiver_transport, &root.path().join("receiver-store"))
                .await
                .unwrap(),
        );
        Self {
            root,
            provider_transport,
            provider_blobs,
            receiver_blobs,
            _receiver_transport: receiver_transport,
        }
    }

    fn provider(&self) -> NodeId {
        self.provider_transport.node_id()
    }

    async fn item(&self, name: &str) -> ([u8; 32], String) {
        let bytes = format!("NET-26 awake fixture {name}").into_bytes();
        let source = self.root.path().join(name);
        std::fs::write(&source, &bytes).unwrap();
        let hash = *blake3::hash(&bytes).as_bytes();
        let ticket = self.provider_blobs.push(hash, &source).await.unwrap();
        (hash, ticket)
    }

    async fn delivery(&self, awake: AwakeHold) -> FlowDelivery {
        let db = paired_db(self.provider()).await;
        FlowDelivery::new(db, self.receiver_blobs.clone(), self.root.path()).with_awake(awake)
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn completed_fetch_acquires_then_releases_the_awake_assertion() {
    let fx = Fixture::new(true).await;
    let (fake, hold) = FakeAwake::new();
    let delivery = fx.delivery(hold.clone()).await;
    let (hash, ticket) = fx.item("done.jpg").await;
    let offer = request(7, "lease-7", hash, ticket);

    delivery.offer(fx.provider(), &offer).await.unwrap();
    assert_eq!(
        fake.acquired(),
        1,
        "starting a fetch task must assert awake"
    );
    delivery.fetch(fx.provider(), &offer).await.unwrap();

    fake.wait_released(1, Duration::from_secs(10)).await;
    assert_eq!(fake.acquired(), 1);
    assert_eq!(hold.active_leases(), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn failed_fetch_still_releases_the_awake_assertion() {
    let fx = Fixture::new(true).await;
    let (fake, hold) = FakeAwake::new();
    let delivery = fx.delivery(hold.clone()).await;
    let (hash, ticket) = fx.item("fail.jpg").await;
    let offer = request(7, "lease-7", hash, ticket);

    // A real network failure: the provider is gone before the task runs.
    fx.provider_transport.close().await;
    delivery.offer(fx.provider(), &offer).await.unwrap();
    assert_eq!(fake.acquired(), 1);

    fake.wait_released(1, Duration::from_secs(45)).await;
    assert_eq!(hold.active_leases(), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn overlapping_fetches_share_one_assertion_until_the_last_is_cancelled() {
    // The provider never accepts, so both fetches hang in the handshake
    // until they are cancelled.
    let fx = Fixture::new(false).await;
    let (fake, hold) = FakeAwake::new();
    let delivery = fx.delivery(hold.clone()).await;
    let (hash_a, ticket_a) = fx.item("a.jpg").await;
    let (hash_b, ticket_b) = fx.item("b.jpg").await;
    let first = request(7, "lease-7", hash_a, ticket_a);
    let second = request(8, "lease-8", hash_b, ticket_b);

    delivery.offer(fx.provider(), &first).await.unwrap();
    delivery.offer(fx.provider(), &second).await.unwrap();
    // Idempotent re-offer of a running tuple takes no extra lease.
    delivery.offer(fx.provider(), &first).await.unwrap();
    assert_eq!(fake.acquired(), 1, "overlapping tasks share one assertion");
    assert_eq!(hold.active_leases(), 2);

    delivery.cancel(fx.provider(), &first).await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while hold.active_leases() > 1 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("cancelled task must drop its lease");
    assert_eq!(
        fake.released(),
        0,
        "one transfer still running — must stay awake"
    );

    delivery.cancel(fx.provider(), &second).await.unwrap();
    fake.wait_released(1, Duration::from_secs(5)).await;
    assert_eq!(fake.acquired(), 1);
    assert_eq!(hold.active_leases(), 0);
}
