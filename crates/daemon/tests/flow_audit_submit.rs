//! AUDIT-01 closing gap: the phone -> daemon leg of the durable Flow audit
//! outbox. Without this, `flow.round.controlled` / `flow.round.finished` /
//! `flow.scope.changed` / `flow.epoch.invalidated` / `flow.item.attention` /
//! `flow.reconciliation.resolved` events written to the phone's local ledger
//! outbox (crates unrelated — see apps/android AUDIT01LedgerOutboxTest) would
//! never reach Desktop's `audit_event` table. This test drives the real
//! `flow.audit.submit` wire method end to end: submit -> durable v2 row ->
//! idempotent replay -> unauthenticated/unauthorized rejection.

use daemon::Router;
use proto::msgs::methods;
use proto::{codes, FlowAuditAccepted, FlowAuditEvent, FlowAuditSubmit, Req, Resp};
use storage::{Db, Device, Role};
use transport::{IrohTransport, Transport, TransportConfig};

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(vec![transport::ALPN_CTRL.into()]))
        .await
        .unwrap()
}

async fn send_method(
    ctp: &IrohTransport,
    daemon: transport::NodeId,
    method: &str,
    params: serde_json::Value,
) -> Resp {
    let mut stream = ctp.connect(daemon, transport::ALPN_CTRL).await.unwrap();
    let req = Req {
        id: format!("m-{method}"),
        method: method.into(),
        params,
        ..Default::default()
    };
    stream
        .send_frame(&proto::codec::encode(&req).unwrap())
        .await
        .unwrap();
    stream.finish().unwrap();
    let frame = stream.recv_frame().await.unwrap().expect("a response");
    proto::codec::decode::<Resp>(&frame).unwrap()
}

fn one_event() -> FlowAuditEvent {
    FlowAuditEvent {
        event_id: "phone-outbox-event-1".into(),
        kind: "flow.round.finished".into(),
        round_id: Some("round-1".into()),
        occurred_at_ms: 1_700_000_000_000,
        payload: std::collections::BTreeMap::from([("confirmed".to_string(), "3".to_string())]),
    }
}

async fn paired_client(db: &Db) -> (IrohTransport, IrohTransport, transport::PeerAddr) {
    let daemon_tp = endpoint().await;
    let daddr = daemon_tp.local_addr();
    let ctp = endpoint().await;
    ctp.add_peer(daddr.clone());
    db.upsert_device(&Device {
        node_id: ctp.node_id().0.to_vec(),
        name: "手机".into(),
        role: Role::Member,
        paired_at: 1,
        last_seen: None,
        revoked: false,
        device_hint: None,
    })
    .await
    .unwrap();
    (daemon_tp, ctp, daddr)
}

#[tokio::test(flavor = "multi_thread")]
async fn submitted_outbox_event_lands_in_the_v2_audit_table_with_the_phone_event_id() {
    let db = Db::open_in_memory().await.unwrap();
    let (daemon_tp, ctp, _) = paired_client(&db).await;
    let router = Router::new(db.clone(), "客厅的电脑");
    let tp2 = daemon_tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });

    let event = one_event();
    let resp = send_method(
        &ctp,
        daemon_tp.node_id(),
        methods::FLOW_AUDIT_SUBMIT,
        serde_json::to_value(FlowAuditSubmit {
            events: vec![event.clone()],
        })
        .unwrap(),
    )
    .await;
    assert!(resp.ok, "flow.audit.submit must succeed: {resp:?}");
    let accepted: FlowAuditAccepted = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert_eq!(accepted.event_ids, vec![event.event_id.clone()]);

    let audit = db.list_audit(10).await.unwrap();
    let row = audit
        .iter()
        .find(|r| r.entry.event_id == event.event_id)
        .expect("the phone's exact event_id must be preserved, not regenerated");
    assert_eq!(row.entry.kind, "flow.round.finished");
    assert_eq!(row.entry.round_id.as_deref(), Some("round-1"));
    assert_eq!(row.entry.actor, Some(ctp.node_id().0.to_vec()));
    assert!(row
        .entry
        .payload
        .as_deref()
        .unwrap_or("")
        .contains("\"confirmed\":\"3\""));
}

#[tokio::test(flavor = "multi_thread")]
async fn resubmitting_the_same_batch_after_a_lost_response_does_not_duplicate_the_row() {
    let db = Db::open_in_memory().await.unwrap();
    let (daemon_tp, ctp, _) = paired_client(&db).await;
    let router = Router::new(db.clone(), "客厅的电脑");
    let tp2 = daemon_tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });

    let event = one_event();
    let params = serde_json::to_value(FlowAuditSubmit {
        events: vec![event.clone()],
    })
    .unwrap();

    let first = send_method(
        &ctp,
        daemon_tp.node_id(),
        methods::FLOW_AUDIT_SUBMIT,
        params.clone(),
    )
    .await;
    assert!(first.ok);
    // Simulate the phone never seeing the (successful) response and
    // retransmitting the identical batch on its next flush.
    let second = send_method(
        &ctp,
        daemon_tp.node_id(),
        methods::FLOW_AUDIT_SUBMIT,
        params,
    )
    .await;
    assert!(second.ok);
    let accepted: FlowAuditAccepted = serde_json::from_value(second.result.unwrap()).unwrap();
    assert_eq!(
        accepted.event_ids,
        vec![event.event_id.clone()],
        "the daemon must still report the id as accepted so the phone can ack it"
    );

    let audit = db.list_audit(10).await.unwrap();
    assert_eq!(
        audit
            .iter()
            .filter(|r| r.entry.event_id == event.event_id)
            .count(),
        1,
        "a retransmitted outbox batch must never create a second audit row"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn unpaired_device_cannot_submit_audit_events() {
    let db = Db::open_in_memory().await.unwrap();
    let daemon_tp = endpoint().await;
    let daddr = daemon_tp.local_addr();
    let router = Router::new(db.clone(), "客厅的电脑");
    let tp2 = daemon_tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });

    let ctp = endpoint().await;
    ctp.add_peer(daddr);
    let resp = send_method(
        &ctp,
        daemon_tp.node_id(),
        methods::FLOW_AUDIT_SUBMIT,
        serde_json::to_value(FlowAuditSubmit {
            events: vec![one_event()],
        })
        .unwrap(),
    )
    .await;
    assert!(!resp.ok, "unpaired device must not reach flow.audit.submit");
    assert_eq!(resp.error.unwrap().code, codes::NOT_AUTHORIZED);
    assert!(db.list_audit(10).await.unwrap().is_empty());
}
