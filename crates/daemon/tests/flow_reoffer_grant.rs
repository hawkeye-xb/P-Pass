//! #1076：手机对同一张照片（同一 tuple：node、pairing_id、queue_sequence、
//! lease_token、content_hash）带一张新的 provider 票据重发 `flow.offer`，
//! 而桌面上一次的后台拉取任务仍在进行中。
//!
//! 身份规则：内容身份是 content_hash，记录身份是 tuple，provider 只表示从哪儿拿。
//! 所以重发只更新库里的 provider，正在跑的任务照常完成、入库、发回执，
//! 不推 `flow.failed`，也不起第二个任务。
//!
//! 确定性做法：第一次 offer 的 provider（P1）用 `attach_to_listener` 挂一个
//! 由测试控制的闸门。桌面的拉取任务连上 P1 后卡在闸门处，一个字节都拿不到，
//! 直到测试放行（或拒绝）——"拉取进行中"不依赖文件大小和机器速度。
//! 重发 offer 用另外几个独立的 provider（P2..），各自持有同一份内容、各自出
//! 一张票据；它们的闸门直接放行但计数，计数为 0 即证明没有第二个任务。
//! 「旧任务已过 require_active、尚未写回执」的窗口用
//! `FlowDelivery::with_fetch_stage_hook` 停住。

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use daemon::events;
use daemon::flow_delivery::{FetchStage, FlowDelivery};
use proto::FlowFetchRequest;
use storage::{Db, Pairing, Role};
use tempfile::{tempdir, TempDir};
use transport::{Blobs, IrohTransport, NodeId, PeerGate, Transport, TransportConfig, ALPN_BLOBS};

const PAYLOAD: usize = 8 * 1024 * 1024;

fn payload() -> Vec<u8> {
    let mut out = Vec::with_capacity(PAYLOAD);
    let mut s: u64 = 0x9E37_79B9_7F4A_7C15;
    while out.len() < PAYLOAD {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        out.extend_from_slice(&s.to_le_bytes());
    }
    out.truncate(PAYLOAD);
    out
}

fn offer_request(hash: [u8; 32], provider: String) -> FlowFetchRequest {
    FlowFetchRequest {
        queue_sequence: 7,
        pairing_id: "epoch-current".into(),
        lease_token: "lease-current".into(),
        content_hash: hex::encode(hash),
        file_name: "IMG_0007.jpg".into(),
        media_type: "image/jpeg".into(),
        provider,
        capture_at_ms: 0,
        size_bytes: PAYLOAD as i64,
        source: Default::default(),
    }
}

async fn paired_db(peer: NodeId) -> Db {
    let db = Db::open_in_memory().await.unwrap();
    db.accept_pairing(
        &peer.0,
        "phone",
        &Pairing {
            id: "epoch-current".into(),
            node_id: peer.0.to_vec(),
            role: Role::Member,
            paired_at: 1,
        },
    )
    .await
    .unwrap();
    db
}

/// 闸门的裁决：`None` 持住，`Some(true)` 放行，`Some(false)` 拒绝。
type Verdict = Option<bool>;

/// 一个持有内容、入站连接与请求都先过闸门的 provider。`hits` 记闸门被问了
/// 几次（每条连接和其上每个请求各一次），0 = 从没有人来拉过。
struct GatedProvider {
    _transport: IrohTransport,
    _blobs: Blobs,
    ticket: String,
    hits: Arc<AtomicUsize>,
    verdict: tokio::sync::watch::Sender<Verdict>,
}

impl GatedProvider {
    async fn open(
        dir: &std::path::Path,
        source: &std::path::Path,
        hash: [u8; 32],
        initial: Verdict,
    ) -> Self {
        let transport = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
        let blobs = Blobs::open(&transport, dir).await.unwrap();
        let ticket = blobs.push(hash, source).await.unwrap();
        let (verdict, rx) = tokio::sync::watch::channel(initial);
        let hits = Arc::new(AtomicUsize::new(0));
        let counter = hits.clone();
        let gate: PeerGate = Arc::new(move |_peer| {
            let mut rx = rx.clone();
            counter.fetch_add(1, Ordering::SeqCst);
            Box::pin(async move {
                match rx.wait_for(|v| v.is_some()).await {
                    Ok(v) => v.unwrap_or(false),
                    Err(_) => false,
                }
            })
        });
        blobs.attach_to_listener(gate);
        // 接受循环由 listen 起；blobs 连接在循环里直接交给闸门处理，不经过
        // 它返回的流，所以流不用留着。
        drop(transport.listen().await);
        Self {
            _transport: transport,
            _blobs: blobs,
            ticket,
            hits,
            verdict,
        }
    }

    fn hits(&self) -> usize {
        self.hits.load(Ordering::SeqCst)
    }

    fn decide(&self, verdict: bool) {
        self.verdict.send(Some(verdict)).unwrap();
    }
}

/// 接收端 + 推送收集器。
struct Desk {
    root: TempDir,
    hash: [u8; 32],
    source: std::path::PathBuf,
    phone: NodeId,
    _control: IrohTransport,
    _receiver: IrohTransport,
    db: Db,
    library: std::path::PathBuf,
    delivery: FlowDelivery,
    events: Arc<Mutex<Vec<serde_json::Value>>>,
    collector: tokio::task::JoinHandle<()>,
}

impl Desk {
    async fn open(stage_hook: Option<StageGate>) -> Self {
        let root = tempdir().unwrap();
        let bytes = payload();
        let source = root.path().join("source.bin");
        std::fs::write(&source, &bytes).unwrap();
        let hash = *blake3::hash(&bytes).as_bytes();

        // 控制面 peer（手机的身份）。provider 都是独立 endpoint，正如 Android
        // 原生 provider 自有 endpoint 与票据。
        let control = IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
            .await
            .unwrap();
        let phone = control.node_id();

        let receiver_transport =
            IrohTransport::bind(TransportConfig::loopback(vec![ALPN_BLOBS.into()]))
                .await
                .unwrap();
        let receiver_blobs = Arc::new(
            Blobs::open(&receiver_transport, &root.path().join("receiver-store"))
                .await
                .unwrap(),
        );
        let db = paired_db(phone).await;
        let (event_bus, mut event_rx) = events::bus();
        let library = root.path().join("library");
        std::fs::create_dir_all(&library).unwrap();
        let mut delivery = FlowDelivery::new(db.clone(), receiver_blobs, &library)
            .with_events_and_window(event_bus, Duration::from_millis(20))
            // 持闸期间不能被字节停滞看门狗误杀。
            .with_fetch_byte_stall(Duration::from_secs(120));
        if let Some(gate) = stage_hook {
            delivery = delivery.with_fetch_stage_hook(move |stage| gate.pass(stage));
        }

        let events = Arc::new(Mutex::new(Vec::<serde_json::Value>::new()));
        let sink = events.clone();
        let collector = tokio::spawn(async move {
            while let Ok(event) = event_rx.recv().await {
                sink.lock().unwrap().push(event);
            }
        });
        Self {
            root,
            hash,
            source,
            phone,
            _control: control,
            // FlowDelivery 的 Blobs 用它拨号，必须活到测试结束。
            _receiver: receiver_transport,
            db,
            library,
            delivery,
            events,
            collector,
        }
    }

    async fn provider(&self, name: &str, initial: Verdict) -> GatedProvider {
        GatedProvider::open(
            &self.root.path().join(format!("{name}-store")),
            &self.source,
            self.hash,
            initial,
        )
        .await
    }

    async fn offer(&self, provider: &GatedProvider) -> Result<(String, bool), String> {
        match self
            .delivery
            .offer(
                self.phone,
                &offer_request(self.hash, provider.ticket.clone()),
            )
            .await
        {
            Ok(reply) => Ok((reply.state, reply.task_running)),
            Err(e) => Err(e.wire_code().to_string()),
        }
    }

    fn pushes(&self, kind: &str) -> Vec<serde_json::Value> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e["event"].as_str() == Some(kind))
            .cloned()
            .collect()
    }

    fn failed_reasons(&self) -> Vec<String> {
        self.pushes(events::FLOW_FAILED)
            .iter()
            .map(|e| e["data"]["reason"].as_str().unwrap_or("<none>").to_string())
            .collect()
    }

    fn delivered_receipts(&self) -> Vec<String> {
        self.pushes(events::FLOW_DELIVERED)
            .iter()
            .map(|e| {
                e["data"]["receipt"]["receipt_id"]
                    .as_str()
                    .unwrap_or("")
                    .to_string()
            })
            .collect()
    }

    /// 等旧任务的结局（delivered 或 failed 推送），期间不轮询 status，
    /// 免得轮询本身改变任务注册表。
    async fn await_first_terminal_push(&self) {
        tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                if !self.pushes(events::FLOW_FAILED).is_empty()
                    || !self.pushes(events::FLOW_DELIVERED).is_empty()
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("旧任务必须以 flow.delivered 或 flow.failed 结束");
    }

    async fn receipt_now(&self) -> Option<String> {
        self.db
            .flow_receipt(self.phone.0.as_slice(), "epoch-current", 7)
            .await
            .unwrap()
            .map(|r| r.receipt_id)
    }

    /// 像手机一样轮询 flow.status 直到终态（NET-15：轮询会重起丢失的任务，
    /// 读的是库里最新的 provider）。
    async fn poll_to_terminal(&self, provider: &GatedProvider) -> Result<String, String> {
        let request = offer_request(self.hash, provider.ticket.clone());
        let result = match common::await_receipt(&self.delivery, self.phone, &request).await {
            Ok(receipt) => Ok(receipt.receipt_id),
            Err(e) => Err(e.wire_code().to_string()),
        };
        // 让轮询引发的推送也落进收集器。
        tokio::time::sleep(Duration::from_millis(200)).await;
        result
    }

    async fn asset_count(&self) -> i64 {
        self.db.count_assets().await.unwrap()
    }

    fn staging_empty(&self) -> bool {
        std::fs::read_dir(self.library.join(".ppf/flow-staging"))
            .map(|d| d.count() == 0)
            .unwrap_or(true)
    }

    fn dump(&self, label: &str) {
        for e in self.events.lock().unwrap().iter() {
            if matches!(
                e["event"].as_str(),
                Some(events::FLOW_FAILED) | Some(events::FLOW_DELIVERED)
            ) {
                eprintln!("{label} push: {e}");
            }
        }
    }
}

impl Drop for Desk {
    fn drop(&mut self) {
        self.collector.abort();
    }
}

/// 在某个 [`FetchStage`] 停住后台拉取，直到测试放行。
#[derive(Clone)]
struct StageGate {
    stop_at: FetchStage,
    reached: tokio::sync::watch::Sender<bool>,
    release: tokio::sync::watch::Sender<bool>,
}

impl StageGate {
    fn new(stop_at: FetchStage) -> Self {
        Self {
            stop_at,
            reached: tokio::sync::watch::channel(false).0,
            release: tokio::sync::watch::channel(false).0,
        }
    }

    fn pass(
        &self,
        stage: FetchStage,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        if stage != self.stop_at {
            return Box::pin(async {});
        }
        self.reached.send_replace(true);
        let mut release = self.release.subscribe();
        Box::pin(async move {
            let _ = release.wait_for(|open| *open).await;
        })
    }

    async fn wait_reached(&self) {
        let mut reached = self.reached.subscribe();
        tokio::time::timeout(Duration::from_secs(60), reached.wait_for(|r| *r))
            .await
            .expect("后台拉取必须走到这个阶段")
            .unwrap();
    }

    fn open(&self) {
        self.release.send_replace(true);
    }
}

/// 第一次 offer 挂在持闸的 P1 上；拉取进行中按 `interval` 重发 `reoffers` 次，
/// 每次一个新 provider（放行但计数）；然后按 `p1_verdict` 放行或拒绝 P1。
struct Scenario {
    desk: Desk,
    p1: GatedProvider,
    others: Vec<GatedProvider>,
    replies: Vec<Result<(String, bool), String>>,
}

async fn run_scenario(reoffers: usize, interval: Duration, p1_verdict: bool) -> Scenario {
    let desk = Desk::open(None).await;
    let p1 = desk.provider("p1", None).await;
    let mut others = Vec::new();
    for i in 0..reoffers {
        others.push(desk.provider(&format!("p{}", i + 2), Some(true)).await);
    }

    let mut replies = vec![desk.offer(&p1).await];
    tokio::time::timeout(Duration::from_secs(20), async {
        while p1.hits() == 0 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("第一次拉取必须连上 P1 并停在闸门处");

    for other in &others {
        assert_ne!(
            other.ticket, p1.ticket,
            "每次重发必须是一张不同的 provider 票据"
        );
        tokio::time::sleep(interval).await;
        replies.push(desk.offer(other).await);
    }
    // 对照组也持同样的闸时长下限，保证差异只来自"是否重发"。
    tokio::time::sleep(Duration::from_millis(500)).await;

    p1.decide(p1_verdict);
    desk.await_first_terminal_push().await;
    Scenario {
        desk,
        p1,
        others,
        replies,
    }
}

fn others_hits(others: &[GatedProvider]) -> Vec<usize> {
    others.iter().map(GatedProvider::hits).collect()
}

/// 验收 1：拉取进行中同 tuple、新票据重发 —— 没有任何 flow.failed；不靠轮询
/// 就有回执；只入库一次；整个过程只有一个拉取任务（重发的 provider 一次都
/// 没被拉过：若有第二次 spawn，它必然拿库里最新的 provider 去连 P2..）。
async fn assert_reoffer_keeps_the_running_task(reoffers: usize, interval: Duration) {
    let s = run_scenario(reoffers, interval, true).await;
    let d = &s.desk;
    let receipt_before_poll = d.receipt_now().await;
    let assets_before_poll = d.asset_count().await;
    let final_status = d.poll_to_terminal(&s.p1).await;
    d.dump(&format!("reoffers={reoffers}"));
    eprintln!(
        "RESULT reoffers={reoffers} replies={:?} failed={:?} delivered={:?} \
         receipt_before_poll={receipt_before_poll:?} assets_before_poll={assets_before_poll} \
         p1_hits={} others_hits={:?} final={final_status:?} assets={}",
        s.replies,
        d.failed_reasons(),
        d.delivered_receipts(),
        s.p1.hits(),
        others_hits(&s.others),
        d.asset_count().await,
    );

    assert_eq!(s.replies.len(), reoffers + 1);
    for reply in &s.replies {
        assert_eq!(reply, &Ok(("active".to_string(), true)), "{:?}", s.replies);
    }
    assert!(d.failed_reasons().is_empty(), "{:?}", d.failed_reasons());
    let receipt = receipt_before_poll.expect("旧任务自己写回执，不靠轮询");
    assert_eq!(assets_before_poll, 1);
    assert_eq!(d.delivered_receipts(), vec![receipt.clone()]);
    assert_eq!(final_status, Ok(receipt));
    assert!(s.p1.hits() > 0);
    assert!(
        others_hits(&s.others).iter().all(|&h| h == 0),
        "重发不许起第二个拉取任务: {:?}",
        others_hits(&s.others)
    );
    assert_eq!(d.asset_count().await, 1);
    assert!(d.staging_empty());
}

/// 验收 2（对照组）：只 offer 一次，同样持闸后放行。
#[tokio::test(flavor = "multi_thread")]
async fn control_single_offer_completes_without_grant_reasons() {
    let s = run_scenario(0, Duration::ZERO, true).await;
    let d = &s.desk;
    assert_eq!(s.replies, vec![Ok(("active".to_string(), true))]);
    assert!(d.failed_reasons().is_empty(), "{:?}", d.failed_reasons());
    let receipt = d.receipt_now().await.expect("单次 offer 不靠轮询就完成");
    assert_eq!(d.poll_to_terminal(&s.p1).await, Ok(receipt.clone()));
    assert_eq!(d.delivered_receipts(), vec![receipt]);
    assert_eq!(d.asset_count().await, 1);
}

/// 验收 1：拉取进行中，同 tuple、新票据重发一次。
#[tokio::test(flavor = "multi_thread")]
async fn reoffer_once_with_new_ticket_keeps_the_running_fetch() {
    assert_reoffer_keeps_the_running_task(1, Duration::from_millis(200)).await;
}

/// 验收 1：拉取进行中，同 tuple、每次新票据，间隔约 1 秒，共重发 5 次。
#[tokio::test(flavor = "multi_thread")]
async fn reoffer_five_times_one_second_apart_keeps_the_running_fetch() {
    assert_reoffer_keeps_the_running_task(5, Duration::from_secs(1)).await;
}

/// 验收 3：P1 失效（闸门拒绝），重发时带了新的 provider P2。旧任务如实以
/// `fetch_failed` 结束（P1 确实拿不到）；之后的尝试——手机轮询 status 触发的
/// 重起，或手机重新 offer——用的都是库里最新的 P2，照片完成、只入库一次，
/// 全程没有 grant_* / cancelled。
async fn dead_first_provider_then(recover_by_reoffer: bool) {
    let s = run_scenario(1, Duration::from_millis(200), false).await;
    let d = &s.desk;
    let p2 = &s.others[0];
    let receipt_before_recovery = d.receipt_now().await;
    let hits_before_recovery = p2.hits();
    let reoffer_reply = if recover_by_reoffer {
        Some(d.offer(p2).await)
    } else {
        None
    };
    let final_status = d.poll_to_terminal(p2).await;
    d.dump(&format!("recover_by_reoffer={recover_by_reoffer}"));
    eprintln!(
        "RESULT dead_p1 recover_by_reoffer={recover_by_reoffer} replies={:?} reoffer_reply={reoffer_reply:?} \
         failed={:?} delivered={:?} p2_hits_before={hits_before_recovery} p2_hits_after={} \
         final={final_status:?} assets={}",
        s.replies,
        d.failed_reasons(),
        d.delivered_receipts(),
        p2.hits(),
        d.asset_count().await,
    );

    assert_eq!(s.replies.len(), 2);
    assert!(receipt_before_recovery.is_none());
    assert_eq!(hits_before_recovery, 0, "P1 失败前没有第二个任务去连 P2");
    assert_eq!(d.failed_reasons(), vec!["fetch_failed".to_string()]);
    let receipt = final_status.expect("换了 provider 之后照片必须完成");
    assert!(p2.hits() > 0, "恢复后的尝试必须从 P2 拿");
    assert_eq!(d.delivered_receipts(), vec![receipt]);
    assert_eq!(d.asset_count().await, 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn dead_first_provider_recovers_from_the_stored_provider_on_status_poll() {
    dead_first_provider_then(false).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn dead_first_provider_recovers_on_phone_reoffer() {
    dead_first_provider_then(true).await;
}

/// 验收 4：旧任务已过 `require_active`、尚未写回执的窗口内重发。
/// (a) `Verified`：已拉完、尚未入库 —— 重发沿用旧任务；
/// (b) `Ingested`：已入库、尚未写回执 —— 重发发现库里已有这张照片，直接完成
///     这条 tuple；旧任务随后写回执抢输，必须认这张回执，不推 flow.failed。
async fn reoffer_inside_the_receipt_window(stop_at: FetchStage) {
    let gate = StageGate::new(stop_at);
    let desk = Desk::open(Some(gate.clone())).await;
    let p1 = desk.provider("p1", Some(true)).await;
    let p2 = desk.provider("p2", Some(true)).await;

    let first = desk.offer(&p1).await;
    gate.wait_reached().await;
    let assets_in_window = desk.asset_count().await;
    let reoffer = desk.offer(&p2).await;
    gate.open();
    desk.await_first_terminal_push().await;
    // (b) 的重发自己先推一条 delivered；等旧任务也走完再看。
    tokio::time::sleep(Duration::from_millis(500)).await;
    let receipt_before_poll = desk.receipt_now().await;
    let final_status = desk.poll_to_terminal(&p2).await;
    desk.dump(&format!("{stop_at:?}"));
    eprintln!(
        "RESULT window={stop_at:?} first={first:?} reoffer={reoffer:?} assets_in_window={assets_in_window} \
         failed={:?} delivered={:?} receipt_before_poll={receipt_before_poll:?} p2_hits={} \
         final={final_status:?} assets={}",
        desk.failed_reasons(),
        desk.delivered_receipts(),
        p2.hits(),
        desk.asset_count().await,
    );

    assert_eq!(first, Ok(("active".to_string(), true)));
    assert!(
        desk.failed_reasons().is_empty(),
        "{:?}",
        desk.failed_reasons()
    );
    let receipt = receipt_before_poll.expect("不靠轮询就有回执");
    assert_eq!(final_status, Ok(receipt.clone()));
    assert!(!desk.delivered_receipts().is_empty());
    assert!(
        desk.delivered_receipts().iter().all(|r| r == &receipt),
        "只有一张回执: {:?}",
        desk.delivered_receipts()
    );
    assert_eq!(p2.hits(), 0, "重发不许起第二个拉取任务");
    assert_eq!(desk.asset_count().await, 1);
    match stop_at {
        FetchStage::Verified => {
            assert_eq!(assets_in_window, 0);
            assert_eq!(reoffer, Ok(("active".to_string(), true)));
        }
        FetchStage::Ingested => {
            assert_eq!(assets_in_window, 1);
            assert_eq!(reoffer, Ok(("completed".to_string(), false)));
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn reoffer_after_fetch_before_ingest_keeps_the_running_task() {
    reoffer_inside_the_receipt_window(FetchStage::Verified).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn reoffer_after_ingest_before_receipt_yields_one_receipt() {
    reoffer_inside_the_receipt_window(FetchStage::Ingested).await;
}
