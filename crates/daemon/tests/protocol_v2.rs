//! #1070 protocol v2: in-band version negotiation and the reason registry,
//! end to end against a real Router (+ download plane + IPC device list).
//!
//! - A v1 envelope (no `ver`) is refused as `phone_outdated` on the control
//!   plane and the download plane, carries the frozen v1 shim, and changes
//!   no state: device row, pairing epoch, Flow grant and diag log are
//!   byte-for-byte what they were.
//! - The local IPC is exempt (the shell never sends `ver`).
//! - Every registered `Reason` has at least one send-point test
//!   ([`every_reason_has_a_send_point_test`]).

use std::sync::Arc;
use std::time::Duration;

use daemon::router::OutdatedPeers;
use daemon::{DiagAgg, IpcServer, Pairing, QueryEngine, Router};
use interprocess::local_socket::tokio::prelude::*;
use proto::{codes, Reason, Req, Resp};
use storage::{Db, Device, FlowGrant, FlowGrantState, Role};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use transport::{Blobs, IrohTransport, NodeId, Transport, TransportConfig};

const EPOCH: &str = "epoch-1";

async fn bind(alpns: Vec<String>) -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(alpns))
        .await
        .unwrap()
}

struct Desk {
    tp: IrohTransport,
    phone: IrohTransport,
    db: Db,
    socket: String,
    token_hex: String,
    _lib: tempfile::TempDir,
}

/// Router + download plane + IpcServer sharing one `OutdatedPeers`, the way
/// `main.rs` wires them. The phone is a paired member on [`EPOCH`].
async fn desk(tag: &str) -> Desk {
    let lib = tempfile::tempdir().unwrap();
    let db = Db::open_in_memory().await.unwrap();
    let tp = bind(vec![
        transport::ALPN_CTRL.into(),
        transport::ALPN_BLOBS.into(),
        transport::ALPN_DOWNLOAD.into(),
    ])
    .await;
    let blobs = Arc::new(
        Blobs::open(&tp, &lib.path().join(".ppf/blobs"))
            .await
            .unwrap(),
    );
    let (bus, _probe) = daemon::events::bus();
    let (pairing, pending_rx) = Pairing::new(db.clone(), tp.node_id(), None);
    let pairing = pairing.with_events(bus.clone());
    let outdated = OutdatedPeers::new();

    let mut ipc = IpcServer::new(
        db.clone(),
        pairing.clone(),
        DiagAgg::new(db.clone()),
        lib.path().to_path_buf(),
        pending_rx,
        bus,
    );
    ipc.set_outdated_peers(outdated.clone());
    let ipc = Arc::new(ipc);
    let socket = format!("ppf-test-{}-v2-{tag}", std::process::id());
    let token = [0x6C; 32];
    let token_hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
    tokio::spawn({
        let ipc = Arc::clone(&ipc);
        let socket = socket.clone();
        async move {
            let _ = ipc.serve(&socket, token).await;
        }
    });

    let delivery = daemon::flow_delivery::FlowDelivery::new(db.clone(), blobs.clone(), lib.path());
    let router = Router::new(db.clone(), "v2-desk")
        .with_outdated_peers(outdated)
        .with_pairing(pairing)
        .with_flow_delivery(delivery)
        .with_query(QueryEngine::new(db.clone(), blobs, lib.path()))
        .with_download(daemon::download::DownloadPlane::new(
            db.clone(),
            lib.path().to_path_buf(),
        ));
    let tp2 = tp.clone();
    tokio::spawn(async move { router.serve(&tp2).await });

    let phone = bind(vec![transport::ALPN_CTRL.into()]).await;
    phone.add_peer(tp.local_addr());
    db.upsert_device(&member(phone.node_id(), Role::Member))
        .await
        .unwrap();
    db.set_pairing_epoch(&phone.node_id().0, EPOCH)
        .await
        .unwrap();

    // Wait until the IPC socket accepts.
    let name = socket
        .clone()
        .to_ns_name::<interprocess::local_socket::GenericNamespaced>()
        .unwrap();
    for _ in 0..200 {
        if interprocess::local_socket::tokio::Stream::connect(name.clone())
            .await
            .is_ok()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    Desk {
        tp,
        phone,
        db,
        socket,
        token_hex,
        _lib: lib,
    }
}

fn member(node: NodeId, role: Role) -> Device {
    Device {
        node_id: node.0.to_vec(),
        name: "phone".into(),
        role,
        paired_at: 1,
        last_seen: Some(1_700_000_000_000),
        revoked: false,
        revoked_at: None,
        revoked_by: None,
    }
}

/// One raw frame on one stream of `alpn`; the first frame back as JSON.
async fn raw(
    from: &IrohTransport,
    to: NodeId,
    alpn: &str,
    frame: serde_json::Value,
) -> serde_json::Value {
    tokio::time::timeout(Duration::from_secs(15), async {
        let mut stream = from.connect(to, alpn).await.unwrap();
        stream
            .send_frame(&proto::codec::encode(&frame).unwrap())
            .await
            .unwrap();
        stream.finish().unwrap();
        let reply = stream.recv_frame().await.unwrap().expect("a response");
        proto::codec::decode::<serde_json::Value>(&reply).unwrap()
    })
    .await
    .expect("answer within the control-tier cap")
}

/// A v2 request (this build's `Req::default()` versions).
async fn call(d: &Desk, method: &str, params: serde_json::Value) -> Resp {
    let req = Req {
        id: method.into(),
        method: method.into(),
        params,
        ..Default::default()
    };
    let v = raw(
        &d.phone,
        d.tp.node_id(),
        transport::ALPN_CTRL,
        serde_json::to_value(req).unwrap(),
    )
    .await;
    serde_json::from_value(v).unwrap()
}

async fn ipc_raw(d: &Desk, line: &str) -> serde_json::Value {
    let name = d
        .socket
        .as_str()
        .to_ns_name::<interprocess::local_socket::GenericNamespaced>()
        .unwrap();
    let conn = interprocess::local_socket::tokio::Stream::connect(name)
        .await
        .unwrap();
    let (rx, mut tx) = conn.split();
    tx.write_all(format!("{}\n{line}\n", d.token_hex).as_bytes())
        .await
        .unwrap();
    let mut lines = tokio::io::BufReader::new(rx).lines();
    let resp = lines.next_line().await.unwrap().expect("a response");
    serde_json::from_str(&resp).unwrap()
}

async fn needs_update(d: &Desk) -> serde_json::Value {
    let resp = ipc_raw(
        d,
        r#"{"id":"l","method":"devices.list","params":{"include_revoked":true}}"#,
    )
    .await;
    assert_eq!(resp["ok"], true, "{resp}");
    let me = hex(&d.phone.node_id().0);
    resp["result"]["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["node_id"] == me.as_str())
        .unwrap_or_else(|| panic!("phone row missing: {resp}"))["needs_update"]
        .clone()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn grant(d: &Desk) -> FlowGrant {
    FlowGrant {
        node_id: d.phone.node_id().0.to_vec(),
        queue_sequence: 7,
        pairing_epoch: EPOCH.into(),
        lease_token: "lease-7".into(),
        content_hash: vec![0xAB; 32],
        file_name: "IMG_7.jpg".into(),
        media_type: "image/jpeg".into(),
        provider: "provider".into(),
        state: FlowGrantState::Active,
        receipt_id: None,
    }
}

fn offer_params(epoch: &str) -> serde_json::Value {
    serde_json::to_value(proto::FlowFetchRequest {
        queue_sequence: 7,
        pairing_epoch: epoch.into(),
        lease_token: "lease-7".into(),
        content_hash: "ab".repeat(32),
        file_name: "IMG_7.jpg".into(),
        media_type: "image/jpeg".into(),
        provider: "provider".into(),
        capture_at_ms: 0,
        size_bytes: 0,
    })
    .unwrap()
}

/// Everything a version rejection must leave alone.
async fn state_of(d: &Desk) -> (Option<Device>, Option<String>, Option<FlowGrant>, usize) {
    let me = d.phone.node_id().0;
    (
        d.db.get_device(&me).await.unwrap(),
        d.db.pairing_epoch(&me).await.unwrap(),
        d.db.flow_grant(&me, EPOCH, 7).await.unwrap(),
        d.db.list_diag(10_000).await.unwrap().len(),
    )
}

fn assert_phone_outdated(resp: &serde_json::Value, shim: &str, what: &str) {
    assert_eq!(resp["ok"], false, "{what}: {resp}");
    let e = &resp["error"];
    assert_eq!(e["code"], codes::VERSION_MISMATCH, "{what}: {resp}");
    assert_eq!(e["reason"], "phone_outdated", "{what}: {resp}");
    assert_eq!(
        e["params"]["min_ver"],
        proto::MIN_SUPPORTED_VER,
        "{what}: {resp}"
    );
    assert_eq!(e["msg_key"], shim, "{what}: frozen v1 shim: {resp}");
    assert_eq!(resp["ver"], proto::PROTO_VER, "{what}: {resp}");
}

/// Acceptance 6: v1 envelopes (no `ver`) are refused as `phone_outdated` on
/// every plane, with the per-method shim, and no state moves.
#[tokio::test(flavor = "multi_thread")]
async fn v1_envelopes_are_refused_as_phone_outdated_and_change_nothing() {
    let d = desk("v1").await;
    d.db.upsert_flow_grant(&grant(&d)).await.unwrap();
    let before = state_of(&d).await;
    assert!(before.0.is_some() && before.1.is_some() && before.2.is_some());

    // What released Android 0.9.12 puts on the wire: `min_ver` but no `ver`.
    let cases = [
        ("hello", serde_json::json!({}), "fetch_failed"),
        ("flow.offer", offer_params(EPOCH), "fetch_failed"),
        (
            "flow.status",
            serde_json::json!({"queue_sequence":7,"pairing_epoch":EPOCH,"lease_token":"lease-7"}),
            "fetch_failed",
        ),
        (
            "device.unpair",
            serde_json::json!({"pairing_epoch": EPOCH}),
            "fetch_failed",
        ),
        ("timeline.page", serde_json::json!({}), "fetch_failed"),
        (
            "pair.request",
            serde_json::json!({"token":"00","device_name":"old","role":"member","ack_then_poll":true}),
            "err.unsupported",
        ),
        (
            "pair.status",
            serde_json::json!({"request_id":"x"}),
            "err.unsupported",
        ),
        (
            "pair.cancel",
            serde_json::json!({"request_id":"x"}),
            "err.unsupported",
        ),
    ];
    for (method, params, shim) in cases {
        let resp = raw(
            &d.phone,
            d.tp.node_id(),
            transport::ALPN_CTRL,
            serde_json::json!({"id": method, "method": method, "params": params, "min_ver": 1}),
        )
        .await;
        assert_phone_outdated(&resp, shim, method);
    }
    // A frame with neither key is v1 too.
    let resp = raw(
        &d.phone,
        d.tp.node_id(),
        transport::ALPN_CTRL,
        serde_json::json!({"id": "bare", "method": "hello", "params": {}}),
    )
    .await;
    assert_phone_outdated(&resp, "fetch_failed", "bare hello");

    // Download plane: same answer before a single byte.
    let resp = raw(
        &d.phone,
        d.tp.node_id(),
        transport::ALPN_DOWNLOAD,
        serde_json::json!({"id":"","method":"asset.download","params":{"hash":"ab".repeat(32)},"min_ver":1}),
    )
    .await;
    assert_phone_outdated(&resp, "fetch_failed", "asset.download");

    assert_eq!(
        state_of(&d).await,
        before,
        "a version rejection must not touch the device row (incl. last_seen), \
         the pairing epoch, the grant, or the diag log"
    );
    // The device list flags it; a compatible request clears the flag.
    assert_eq!(needs_update(&d).await, "phone");
    let ok = call(&d, "hello", serde_json::json!({})).await;
    assert!(ok.ok, "a v2 hello passes: {ok:?}");
    assert_eq!(needs_update(&d).await, serde_json::Value::Null);
}

/// A peer that requires a newer Desktop: `desktop_outdated`, `params.min_ver`
/// is what the Desktop must reach, and no v1 shim (the envelope is v2+).
#[tokio::test(flavor = "multi_thread")]
async fn a_peer_requiring_a_newer_desktop_gets_desktop_outdated() {
    let d = desk("newer").await;
    let resp = raw(
        &d.phone,
        d.tp.node_id(),
        transport::ALPN_CTRL,
        serde_json::json!({"id":"h","method":"hello","params":{},"ver":3,"min_ver":3}),
    )
    .await;
    assert_eq!(resp["error"]["code"], codes::VERSION_MISMATCH, "{resp}");
    assert_eq!(resp["error"]["reason"], "desktop_outdated", "{resp}");
    assert_eq!(resp["error"]["params"]["min_ver"], 3, "{resp}");
    assert!(resp["error"].get("msg_key").is_none(), "{resp}");
    assert_eq!(needs_update(&d).await, "desktop");
    // A newer peer that still accepts us is served.
    let resp = raw(
        &d.phone,
        d.tp.node_id(),
        transport::ALPN_CTRL,
        serde_json::json!({"id":"h","method":"hello","params":{},"ver":3,"min_ver":2}),
    )
    .await;
    assert_eq!(resp["ok"], true, "{resp}");
}

/// The shell ↔ daemon IPC is outside the protocol-version rule: a line
/// without `ver` is served, and v2 errors there carry no `msg_key`.
#[tokio::test(flavor = "multi_thread")]
async fn local_ipc_is_exempt_from_the_version_check() {
    let d = desk("ipc").await;
    let resp = ipc_raw(&d, r#"{"id":"s","method":"devices.list","params":{}}"#).await;
    assert_eq!(resp["ok"], true, "{resp}");
    let resp = ipc_raw(&d, r#"{"id":"x","method":"no.such.method","params":{}}"#).await;
    assert_eq!(resp["error"]["reason"], "unsupported_method", "{resp}");
    assert!(resp["error"].get("msg_key").is_none(), "{resp}");
}

/// v2 send points that are cheap to hit over the wire.
#[tokio::test(flavor = "multi_thread")]
async fn v2_errors_name_their_reason_on_the_wire() {
    let d = desk("reasons").await;
    let reason_of = |r: &Resp| r.error.as_ref().map(|e| e.reason().clone());

    // unsupported_method: in no role's table.
    let r = call(&d, "asset.delete_all", serde_json::json!({})).await;
    assert_eq!(reason_of(&r), Some(Reason::UnsupportedMethod), "{r:?}");
    // bad_request: params of the wrong shape.
    let r = call(&d, "flow.offer", serde_json::json!("nonsense")).await;
    assert_eq!(reason_of(&r), Some(Reason::BadRequest), "{r:?}");
    // not_found: an asset the library does not hold.
    let r = call(
        &d,
        "asset.meta",
        serde_json::json!({"hash": "cd".repeat(32)}),
    )
    .await;
    assert_eq!(reason_of(&r), Some(Reason::NotFound), "{r:?}");
    // epoch_mismatch: an offer under a stale pairing epoch.
    let r = call(&d, "flow.offer", offer_params("epoch-stale")).await;
    assert_eq!(reason_of(&r), Some(Reason::EpochMismatch), "{r:?}");
    assert_eq!(r.error.as_ref().unwrap().code(), codes::FLOW_REJECTED);
    // grant_not_found: suspend a tuple that was never offered.
    let r = call(
        &d,
        "flow.suspend",
        serde_json::json!({"queue_sequence": 99, "pairing_epoch": EPOCH, "lease_token": "never"}),
    )
    .await;
    assert_eq!(reason_of(&r), Some(Reason::GrantNotFound), "{r:?}");
    // grant_conflict: seq 7 already completed with other content.
    let mut done = grant(&d);
    done.content_hash = vec![0xEE; 32];
    d.db.upsert_flow_grant(&done).await.unwrap();
    assert!(d.db.complete_flow_grant(&done, "receipt-7").await.unwrap());
    let mut params = offer_params(EPOCH);
    params["provider"] = serde_json::json!(d.phone.local_addr().to_string());
    params["lease_token"] = serde_json::json!("lease-other");
    let r = call(&d, "flow.offer", params).await;
    assert_eq!(reason_of(&r), Some(Reason::GrantConflict), "{r:?}");

    // role_forbidden: a viewer offering a photo.
    d.db.upsert_device(&member(d.phone.node_id(), Role::Viewer))
        .await
        .unwrap();
    let r = call(&d, "flow.offer", offer_params(EPOCH)).await;
    assert_eq!(reason_of(&r), Some(Reason::RoleForbidden), "{r:?}");
}

/// Acceptance 6 bookkeeping: every registered reason names the test that
/// asserts it at a send point. A new `Reason` without a test fails here.
#[test]
fn every_reason_has_a_send_point_test() {
    let files: &[(&str, &str)] = &[
        ("protocol_v2.rs", include_str!("protocol_v2.rs")),
        ("authz_flow.rs", include_str!("authz_flow.rs")),
        ("pairing_flow.rs", include_str!("pairing_flow.rs")),
        ("backup_flow.rs", include_str!("backup_flow.rs")),
        ("flow_health.rs", include_str!("flow_health.rs")),
        ("flow_delivery.rs", include_str!("flow_delivery.rs")),
        ("flow_revoke.rs", include_str!("flow_revoke.rs")),
        (
            "../src/flow_delivery.rs",
            include_str!("../src/flow_delivery.rs"),
        ),
    ];
    // (reason, file, test fn, evidence string that must appear in the file)
    let table: &[(Reason, &str, &str, &str)] = &[
        (
            Reason::NotPaired,
            "authz_flow.rs",
            "unpaired_node_gets_not_authorized",
            "Reason::NotPaired",
        ),
        (
            Reason::Revoked,
            "authz_flow.rs",
            "revoked_device_is_shut_out_at_once",
            "Reason::Revoked",
        ),
        (
            Reason::RoleForbidden,
            "authz_flow.rs",
            "viewer_browses_but_backup_is_denied",
            "Reason::RoleForbidden",
        ),
        (
            Reason::PairTokenInvalid,
            "pairing_flow.rs",
            "token_replay_is_rejected",
            "Reason::PairTokenInvalid",
        ),
        (
            Reason::PhoneOutdated,
            "protocol_v2.rs",
            "v1_envelopes_are_refused_as_phone_outdated_and_change_nothing",
            "\"phone_outdated\"",
        ),
        (
            Reason::DesktopOutdated,
            "protocol_v2.rs",
            "a_peer_requiring_a_newer_desktop_gets_desktop_outdated",
            "\"desktop_outdated\"",
        ),
        (
            Reason::UnsupportedMethod,
            "protocol_v2.rs",
            "v2_errors_name_their_reason_on_the_wire",
            "Reason::UnsupportedMethod",
        ),
        (
            Reason::BadRequest,
            "protocol_v2.rs",
            "v2_errors_name_their_reason_on_the_wire",
            "Reason::BadRequest",
        ),
        (
            Reason::NotFound,
            "protocol_v2.rs",
            "v2_errors_name_their_reason_on_the_wire",
            "Reason::NotFound",
        ),
        // No wire path can make the store fail on demand; the mapping of the
        // one Flow source of `internal` is pinned at unit level.
        (
            Reason::Internal,
            "../src/flow_delivery.rs",
            "delivery_errors_map_to_registered_reasons",
            "Reason::Internal",
        ),
        (
            Reason::BackupFailed,
            "backup_flow.rs",
            "interrupted_commit_rerun_converges_and_survives_rebuild",
            "Reason::BackupFailed",
        ),
        (
            Reason::StorageFull,
            "flow_health.rs",
            "offer_that_cannot_fit_is_refused_with_the_storage_full_reason",
            "Reason::StorageFull",
        ),
        (
            Reason::LibraryUnavailable,
            "flow_health.rs",
            "offer_refuses_with_library_unavailable_when_the_library_folder_is_gone",
            "Reason::LibraryUnavailable",
        ),
        (
            Reason::StorageFailed,
            "flow_health.rs",
            "materialize_failure_is_pushed_as_storage_failed_on_a_healthy_desktop",
            "storage_failed",
        ),
        (
            Reason::FetchFailed,
            "flow_delivery.rs",
            "failed_background_fetch_pushes_flow_failed_with_node_id_and_tuple",
            "\"fetch_failed\"",
        ),
        (
            Reason::EpochMismatch,
            "protocol_v2.rs",
            "v2_errors_name_their_reason_on_the_wire",
            "Reason::EpochMismatch",
        ),
        (
            Reason::GrantNotFound,
            "protocol_v2.rs",
            "v2_errors_name_their_reason_on_the_wire",
            "Reason::GrantNotFound",
        ),
        (
            Reason::GrantConflict,
            "protocol_v2.rs",
            "v2_errors_name_their_reason_on_the_wire",
            "Reason::GrantConflict",
        ),
        (
            Reason::Cancelled,
            "flow_revoke.rs",
            "device_revoke_cancels_the_in_flight_fetch_before_it_can_finish",
            "DeliveryError::Cancelled",
        ),
    ];
    for reason in Reason::ALL {
        let Some((_, file, test, evidence)) = table.iter().find(|(r, ..)| r == reason) else {
            panic!("{reason}: no send-point test registered");
        };
        let src = files
            .iter()
            .find(|(name, _)| name == file)
            .unwrap_or_else(|| panic!("{file} not loaded"))
            .1;
        assert!(src.contains(test), "{reason}: {file} has no {test}");
        assert!(
            src.contains(evidence),
            "{reason}: {file} never asserts {evidence}"
        );
    }
}
