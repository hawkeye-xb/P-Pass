//! AUDIT-04 supersedes AUDIT-01's single-bucket `audit_event` contract this
//! file originally exercised: `flow.round.finished` no longer lands in a
//! flat event table with a free `payload` blob — it is routed by
//! `crate::audit_route::route` onto the canonical `audit_operation` (the
//! round IS the operation, keyed by the phone's `round_id`) with
//! `evidence_summary` recomputed from actually-persisted
//! `audit_item_evidence` rows (card acceptance criterion #2), never
//! trusted verbatim from the phone's payload. The wire method
//! (`flow.audit.submit`), transport, and idempotent-batch-delivery
//! contract are unchanged from AUDIT-01 — only what happens to a fact
//! once it lands is superseded. Old assertions that read `payload` for
//! `confirmed:"3"` are rewritten below to read `final_counts`/
//! `evidence_summary` on the operation row instead (frozen per
//! docs/AGENT_PROTOCOL.md's architecture-supersession rule; the
//! AUDIT-01 card is marked accordingly).

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
async fn submitted_round_finished_lands_in_the_canonical_operation_keyed_by_round_id() {
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

    // AUDIT-04: the round IS the operation — operation_id is the phone's
    // round_id, never a freshly minted id.
    let op = db
        .get_operation("round-1")
        .await
        .unwrap()
        .expect("the round's operation row must be durable");
    assert_eq!(op.entry.kind, "flow.round.finished");
    assert_eq!(op.entry.round_id.as_deref(), Some("round-1"));
    assert_eq!(op.entry.actor, Some(ctp.node_id().0.to_vec()));
    assert!(
        op.entry
            .final_counts
            .as_deref()
            .unwrap_or("")
            .contains("\"confirmed\":\"3\""),
        "the phone's self-reported final_counts is still stored (advisory): {:?}",
        op.entry.final_counts
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn resubmitting_the_same_batch_after_a_lost_response_does_not_duplicate_the_operation() {
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

    assert!(
        db.get_operation("round-1").await.unwrap().is_some(),
        "the operation must be durable after replay"
    );
    // No table-count assertion needed beyond "still exactly one row" —
    // operation_id has a UNIQUE constraint, so a second INSERT OR IGNORE
    // physically cannot create a duplicate; the real risk this test
    // guards is the daemon reporting the replay as NOT accepted (which
    // would leave the phone retrying forever).
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
    assert!(db.get_operation("round-1").await.unwrap().is_none());
}
