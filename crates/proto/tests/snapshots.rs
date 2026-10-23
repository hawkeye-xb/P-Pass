//! Integration tests: golden snapshots for all message types.
//!
//! Run with: `cargo test -p proto`
//! Update snapshots with: `cargo insta review` or `INSTA_UPDATE=always cargo test -p proto`

use proto::codec;
use proto::msgs::*;

fn assert_roundtrip<
    T: serde::Serialize + serde::de::DeserializeOwned + std::fmt::Debug + PartialEq,
>(
    value: &T,
) {
    let frame = codec::encode(value).unwrap();
    let back: T = codec::decode(&frame).unwrap();
    assert_eq!(value, &back, "roundtrip mismatch");
}

fn snapshot_message<T: serde::Serialize>(name: &str, value: &T) {
    let json = serde_json::to_string_pretty(value).unwrap();
    insta::assert_snapshot!(name, json);
}

fn snapshot_frame<T: serde::Serialize>(name: &str, value: &T) {
    let frame = codec::encode(value).unwrap();
    // Show as hex for visual inspection
    let hex = frame
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ");
    insta::assert_snapshot!(format!("{name}_hex"), hex);
    // Also record the JSON as reference
    let decoded: serde_json::Value = {
        let payload_len = u32::from_le_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
        serde_json::from_slice(&frame[4..4 + payload_len]).unwrap()
    };
    let pretty = serde_json::to_string_pretty(&decoded).unwrap();
    insta::assert_snapshot!(format!("{name}_json"), pretty);
}

// ── Hello ───────────────────────────────────────────

#[test]
fn snapshot_hello() {
    let hello = Hello {
        proto_ver: 1,
        capabilities: vec!["thumbnail.v1".into(), "video.range.v1".into()],
        device_name: "Salamira's Phone".into(),
        pairing_id: None,
        health: None,
    };
    assert_roundtrip(&hello);
    snapshot_message("hello", &hello);
    snapshot_frame("hello", &hello);
}

// ── Pair ────────────────────────────────────────────

#[test]
fn snapshot_pair_request() {
    let pr = PairRequest {
        token: "abcd1234abcd1234abcd1234abcd1234".into(),
        device_name: "Mom's Phone".into(),
        role: "member".into(),
        ack_then_poll: false,
        pake_a: String::new(),
    };
    assert_roundtrip(&pr);
    snapshot_message("pair_request", &pr);
}

// NET-10 (#128): accept-then-poll pairing — new golden samples only; the
// legacy `pair_request` sample above must stay byte-identical.
#[test]
fn snapshot_pair_request_ack_then_poll() {
    let pr = PairRequest {
        token: "abcd1234abcd1234abcd1234abcd1234".into(),
        device_name: "Mom's Phone".into(),
        role: "member".into(),
        ack_then_poll: true,
        pake_a: String::new(),
    };
    assert_roundtrip(&pr);
    snapshot_message("pair_request_ack_then_poll", &pr);
}

// #1118: the request every current phone sends — with its SPAKE2 message.
#[test]
fn snapshot_pair_request_pake() {
    let pr = PairRequest {
        token: "abcd1234abcd1234abcd1234".into(),
        device_name: "Mom's Phone".into(),
        role: "member".into(),
        ack_then_poll: true,
        pake_a: format!("41{}", "5a".repeat(32)),
    };
    assert_roundtrip(&pr);
    snapshot_message("pair_request_pake", &pr);
}

// #1118: the owner typed the code — the desktop's SPAKE2 answer rides on a pending status.
#[test]
fn snapshot_pair_status_reply_pake_b() {
    let r = PairStatusReply {
        state: PairStatusState::Pending,
        pake_b: Some(format!("42{}", "6b".repeat(32))),
        ..Default::default()
    };
    assert_roundtrip(&r);
    snapshot_message("pair_status_reply_pake_b", &r);
}

// #1118: `pair.confirm` params.
#[test]
fn snapshot_pair_confirm_request() {
    let q = PairConfirmRequest {
        request_id: "0123456789abcdef0123456789abcdef".into(),
        confirm_a: "c1".repeat(32),
    };
    assert_roundtrip(&q);
    snapshot_message("pair_confirm_request", &q);
}

// #1118: `pair.confirm` / `pair.status` after the code matched — the desktop's confirmation.
#[test]
fn snapshot_pair_status_reply_confirmed() {
    let r = PairStatusReply {
        state: PairStatusState::Accepted,
        accepted: Some(PairAccepted {
            storage_device_name: "Home PC".into(),
            pairing_id: "epoch-1".into(),
        }),
        confirm_b: Some("cb".repeat(32)),
        ..Default::default()
    };
    assert_roundtrip(&r);
    snapshot_message("pair_status_reply_confirmed", &r);
}

// #1118: the code confirmation did not match — the request is void.
#[test]
fn snapshot_pair_status_reply_failed() {
    let r = PairStatusReply {
        state: PairStatusState::Failed,
        ..Default::default()
    };
    assert_roundtrip(&r);
    snapshot_message("pair_status_reply_failed", &r);
}

#[test]
fn snapshot_pair_submitted() {
    let ps = PairSubmitted {
        accepted: true,
        request_id: "0123456789abcdef0123456789abcdef".into(),
        ttl_ms: 600_000,
    };
    assert_roundtrip(&ps);
    snapshot_message("pair_submitted", &ps);
}

#[test]
fn snapshot_pair_status_request() {
    let q = PairStatusRequest {
        request_id: "0123456789abcdef0123456789abcdef".into(),
    };
    assert_roundtrip(&q);
    snapshot_message("pair_status_request", &q);
}

#[test]
fn snapshot_pair_status_reply_accepted() {
    let r = PairStatusReply {
        state: PairStatusState::Accepted,
        accepted: Some(PairAccepted {
            storage_device_name: "Home PC".into(),
            pairing_id: "epoch-1".into(),
        }),
        ..Default::default()
    };
    assert_roundtrip(&r);
    snapshot_message("pair_status_reply_accepted", &r);
}

#[test]
fn snapshot_pair_status_reply_denied() {
    // #1070: a denial is the state alone — no reason key on the wire.
    let r = PairStatusReply {
        state: PairStatusState::Denied,
        ..Default::default()
    };
    assert_roundtrip(&r);
    snapshot_message("pair_status_reply_denied", &r);
}

#[test]
fn snapshot_pair_accepted() {
    let pa = PairAccepted {
        storage_device_name: "Home PC".into(),
        pairing_id: "epoch-1".into(),
    };
    assert_roundtrip(&pa);
    snapshot_message("pair_accepted", &pa);
}

// ── Timeline ────────────────────────────────────────

#[test]
fn snapshot_timeline_query() {
    let tq = TimelineQuery {
        cursor: Some("opaque-cursor-001".into()),
        limit: 200,
    };
    assert_roundtrip(&tq);
    snapshot_message("timeline_query", &tq);
}

#[test]
fn snapshot_timeline_page() {
    let tp = TimelinePage {
        items: vec![
            AssetMeta {
                hash: "b4f8e9c2d1a00000000000000000000000000000000000000000000000000000".into(),
                taken_at: 1690000000,
                media_type: "photo".into(),
                width: 4032,
                height: 3024,
                bytes: 3_500_000,
                src_device: Some(
                    "0101010101010101010101010101010101010101010101010101010101010101".into(),
                ),
            },
            AssetMeta {
                hash: "c3d2e1f0a0000000000000000000000000000000000000000000000000000000".into(),
                taken_at: 1690003600,
                media_type: "video".into(),
                width: 1920,
                height: 1080,
                bytes: 50_000_000,
                src_device: Some(
                    "0202020202020202020202020202020202020202020202020202020202020202".into(),
                ),
            },
        ],
        next: Some("next-cursor-002".into()),
    };
    assert_roundtrip(&tp);
    snapshot_message("timeline_page", &tp);
}

// ── Thumbnail ───────────────────────────────────────

#[test]
fn snapshot_thumb_get_256() {
    let tg = ThumbGet {
        hash: "b4f8e9c2d1a00000000000000000000000000000000000000000000000000000".into(),
        size: ThumbSize::S256,
    };
    assert_roundtrip(&tg);
    snapshot_message("thumb_get_256", &tg);
}

#[test]
fn snapshot_thumb_get_1024() {
    let tg = ThumbGet {
        hash: "b4f8e9c2d1a00000000000000000000000000000000000000000000000000000".into(),
        size: ThumbSize::S1024,
    };
    assert_roundtrip(&tg);
    snapshot_message("thumb_get_1024", &tg);
}

#[test]
fn snapshot_thumb_data_real() {
    // DESK-34 (#428): a real thumb must serialize exactly as before the
    // placeholder fields existed — only `jpeg_base64`.
    let td = ThumbData {
        jpeg_base64: "/9j/4AAQ".into(),
        ..Default::default()
    };
    assert_roundtrip(&td);
    snapshot_message("thumb_data_real", &td);
}

#[test]
fn snapshot_thumb_data_placeholder() {
    let td = ThumbData {
        jpeg_base64: "/9j/4AAQ".into(),
        placeholder: true,
        retry_after_ms: 600_000,
    };
    assert_roundtrip(&td);
    snapshot_message("thumb_data_placeholder", &td);
}

#[test]
fn thumb_data_from_an_old_daemon_decodes_as_a_real_thumb() {
    let td: ThumbData = serde_json::from_str(r#"{"jpeg_base64":"/9j/"}"#).unwrap();
    assert!(!td.placeholder);
    assert_eq!(td.retry_after_ms, 0);
}

// ── Blob ticket ─────────────────────────────────────

#[test]
fn snapshot_blob_ticket() {
    let btq = BlobTicketRequest {
        hash: "b4f8e9c2d1a00000000000000000000000000000000000000000000000000000".into(),
    };
    assert_roundtrip(&btq);
    snapshot_message("blob_ticket_request", &btq);

    let btr = BlobTicketResponse {
        ticket: "blob:abcd1234".into(),
    };
    assert_roundtrip(&btr);
    snapshot_message("blob_ticket_response", &btr);
}

// ── Backup ──────────────────────────────────────────

#[test]
fn snapshot_backup() {
    let bb = BackupBegin {};
    assert_roundtrip(&bb);
    snapshot_message("backup_begin", &bb);

    let bm = BackupManifest {
        hashes: vec![
            "aaa0000000000000000000000000000000000000000000000000000000000000".into(),
            "bbb11111111111111111111111111111111111111111111111111111111111111".into(),
            "ccc22222222222222222222222222222222222222222222222222222222222222".into(),
        ],
        ..Default::default()
    };
    assert_roundtrip(&bm);
    // items is empty here, so the frame must be byte-identical to the
    // pre-T-032 snapshot — that IS the compatibility guarantee.
    snapshot_message("backup_manifest", &bm);

    let bm2 = BackupManifest {
        hashes: vec![],
        items: vec![BackupItem {
            hash: "ddd3333333333333333333333333333333333333333333333333333333333333".into(),
            file_name: "IMG_0042.HEIC".into(),
            media_type: "image/heic".into(),
        }],
        provider: None,
    };
    assert_roundtrip(&bm2);
    snapshot_message("backup_manifest_with_items", &bm2);

    let bmiss = BackupMissing {
        hashes: vec!["ccc22222222222222222222222222222222222222222222222222222222222222".into()],
    };
    assert_roundtrip(&bmiss);
    snapshot_message("backup_missing", &bmiss);

    let bc = BackupCommit::default();
    assert_roundtrip(&bc);
    // generation is None here → byte-identical to the pre-T-032 snapshot.
    snapshot_message("backup_commit", &bc);

    let bc2 = BackupCommit {
        generation: Some(31337),
    };
    assert_roundtrip(&bc2);
    snapshot_message("backup_commit_with_generation", &bc2);
}

// ── #851 flow.supersede ─────────────────────────────

#[test]
fn snapshot_flow_supersede() {
    let req = FlowSupersedeRequest {
        pairing_id: "epoch-7".into(),
        old_hash: "aaa1111111111111111111111111111111111111111111111111111111111111".into(),
        new_hash: "bbb2222222222222222222222222222222222222222222222222222222222222".into(),
        provider: "blobticket-example".into(),
    };
    assert_roundtrip(&req);
    snapshot_message("flow_supersede_request", &req);

    let replaced = FlowSupersedeReply {
        outcome: "replaced".into(),
        reason: None,
    };
    assert_roundtrip(&replaced);
    snapshot_message("flow_supersede_reply_replaced", &replaced);

    let refused = FlowSupersedeReply {
        outcome: "refused".into(),
        reason: Some(SupersedeRefusal::NotARedaction),
    };
    assert_roundtrip(&refused);
    snapshot_message("flow_supersede_reply_refused", &refused);
}

// ── #890: Flow per-item delivery goldens ────────────
//
// The phone mirrors (Android `GoldenDriftTest`, iOS `PPassCore`
// `GoldenContractTests`) decode these exact files. New samples only — every
// sample above stays byte-identical.

#[test]
fn snapshot_hello_paired_with_health() {
    // A paired Desktop's hello reply: pairing_id + health present.
    let hello = Hello {
        proto_ver: 1,
        capabilities: vec!["thumbnail.v1".into(), "flow.supersede.v1".into()],
        device_name: "Home PC".into(),
        pairing_id: Some("epoch-7".into()),
        health: Some(DesktopHealth {
            free_bytes: Some(123_456_789_000),
            library_writable: true,
            index_ok: true,
        }),
    };
    assert_roundtrip(&hello);
    snapshot_message("hello_paired_with_health", &hello);

    // `free_bytes: null` is a real answer ("this platform could not say"),
    // serialised as an explicit null — not omitted.
    let unknown = Hello {
        health: Some(DesktopHealth {
            free_bytes: None,
            library_writable: false,
            index_ok: true,
        }),
        ..hello
    };
    assert_roundtrip(&unknown);
    snapshot_message("hello_health_free_bytes_unknown", &unknown);
}

#[test]
fn snapshot_flow_delivery() {
    let fetch = FlowFetchRequest {
        queue_sequence: 1_790_574_682_018,
        pairing_id: "epoch-7".into(),
        lease_token: "lease-1790574682018".into(),
        content_hash: "e0635a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a398c".into(),
        file_name: "IMG_0042.HEIC".into(),
        media_type: "image/heic".into(),
        provider: "blobticket-example".into(),
        capture_at_ms: 1_690_000_000_000,
        size_bytes: 3_500_000,
    };
    assert_roundtrip(&fetch);
    snapshot_message("flow_fetch_request", &fetch);

    let tuple = FlowTupleRef {
        queue_sequence: 1_790_574_682_018,
        pairing_id: "epoch-7".into(),
        lease_token: "lease-1790574682018".into(),
    };
    assert_roundtrip(&tuple);
    snapshot_message("flow_tuple_ref", &tuple);

    let receipt = FlowCompletionReceipt {
        queue_sequence: 1_790_574_682_018,
        receipt_id: "460400000000000000000000000000000000000000000000000000000000510f".into(),
        pairing_id: "epoch-7".into(),
        lease_token: "lease-1790574682018".into(),
        content_hash: "e0635a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a398c".into(),
    };
    assert_roundtrip(&receipt);
    snapshot_message("flow_completion_receipt", &receipt);

    let completed = FlowStatusReply {
        state: "completed".into(),
        receipt: Some(receipt),
        task_running: false,
    };
    assert_roundtrip(&completed);
    snapshot_message("flow_status_reply_completed", &completed);

    let active = FlowStatusReply {
        state: "active".into(),
        receipt: None,
        task_running: true,
    };
    assert_roundtrip(&active);
    snapshot_message("flow_status_reply_active", &active);
}

#[test]
fn snapshot_flow_audit() {
    let submit = FlowAuditSubmit {
        events: vec![
            FlowAuditEvent {
                event_id: "8f14e45f-ceea-467f-a8f0-6f2c3b5d9a10".into(),
                kind: "flow.item.confirmed".into(),
                round_id: Some("c9f0f895-fb98-4b91-8d6c-1f2e3d4c5b6a".into()),
                occurred_at_ms: 1_790_574_700_000,
                payload: [
                    ("itemRef", "media:30333"),
                    ("queueSequence", "1790574682018"),
                    ("sourceVersion", "1790569136:30333"),
                ]
                .into_iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            },
            FlowAuditEvent {
                event_id: "45c48cce-2e2d-4fbd-9d7a-3b2c1d0e9f8a".into(),
                kind: "flow.round.controlled".into(),
                round_id: None,
                occurred_at_ms: 1_790_574_800_000,
                payload: [("action".to_string(), "pause".to_string())]
                    .into_iter()
                    .collect(),
            },
        ],
    };
    assert_roundtrip(&submit);
    snapshot_message("flow_audit_submit", &submit);

    let accepted = FlowAuditAccepted {
        event_ids: vec!["8f14e45f-ceea-467f-a8f0-6f2c3b5d9a10".into()],
    };
    assert_roundtrip(&accepted);
    snapshot_message("flow_audit_accepted", &accepted);
}

#[test]
fn snapshot_backup_presence_query() {
    let q = BackupPresenceQuery {
        hashes: vec![
            "aaa0000000000000000000000000000000000000000000000000000000000000".into(),
            "bbb1111111111111111111111111111111111111111111111111111111111111".into(),
        ],
    };
    assert_roundtrip(&q);
    snapshot_message("backup_presence_query", &q);
}

// ── Diagnostics ─────────────────────────────────────

#[test]
fn snapshot_diag() {
    let ds = DiagStatus {
        state: "ONLINE_DIRECT".into(),
        detail: Some("last_seen: 2026-07-25T23:11:03Z".into()),
    };
    assert_roundtrip(&ds);
    snapshot_message("diag_status", &ds);
}

// ── Envelope ────────────────────────────────────────

#[test]
fn snapshot_req_envelope() {
    let req = Req {
        id: "550e8400-e29b-41d4-a716-446655440000".into(),
        method: "timeline.page".into(),
        params: serde_json::json!({"cursor": null, "limit": 200}),
        ..Req::default()
    };
    assert_roundtrip(&req);
    snapshot_message("req_envelope", &req);
    snapshot_frame("req_envelope", &req);
}

#[test]
fn snapshot_resp_ok_envelope() {
    let resp = Resp::ok(
        "550e8400-e29b-41d4-a716-446655440000",
        serde_json::json!({"items": [], "next": null}),
    );
    assert_roundtrip(&resp);
    snapshot_message("resp_ok_envelope", &resp);
    snapshot_frame("resp_ok_envelope", &resp);
}

#[test]
fn snapshot_resp_err_envelope() {
    let resp = Resp::err(
        "550e8400-e29b-41d4-a716-446655440000",
        proto::RespError::new(proto::Reason::NotFound),
    );
    assert_roundtrip(&resp);
    snapshot_message("resp_err_envelope", &resp);
    snapshot_frame("resp_err_envelope", &resp);
}

// ── #1070 protocol v2: errors and version negotiation ─

/// An error with params: the version rejection a v2 phone sees.
#[test]
fn snapshot_resp_err_with_params() {
    let resp = Resp::err(
        "550e8400-e29b-41d4-a716-446655440000",
        proto::RespError::new(proto::Reason::PhoneOutdated)
            .with_param("min_ver", proto::MIN_SUPPORTED_VER),
    );
    assert_roundtrip(&resp);
    snapshot_message("resp_err_with_params", &resp);
}

/// The rejection a v1 envelope gets: the same error plus the frozen shim key.
/// (Not round-tripped: the shim is send-only, decoders drop it.)
#[test]
fn snapshot_resp_err_v1_shim() {
    for (name, method) in [
        ("resp_err_v1_shim_flow", "flow.offer"),
        ("resp_err_v1_shim_pair", "pair.request"),
    ] {
        let resp = Resp::err(
            "550e8400-e29b-41d4-a716-446655440000",
            proto::RespError::new(proto::Reason::PhoneOutdated)
                .with_param("min_ver", proto::MIN_SUPPORTED_VER)
                .with_v1_shim(method),
        );
        snapshot_message(name, &resp);
    }
}

/// Every registered reason's wire string and the code it travels under.
#[test]
fn snapshot_reasons_registry() {
    let registry: Vec<serde_json::Value> = proto::Reason::ALL
        .iter()
        .map(|r| serde_json::json!({"reason": r, "code": r.category()}))
        .collect();
    snapshot_message("reasons_registry", &registry);
}

/// An unknown reason from a newer peer decodes and keeps its string.
#[test]
fn unknown_reason_from_a_newer_peer_decodes() {
    let json = r#"{"id":"1","ok":false,"error":{"code":"FUTURE","reason":"from_the_future"},"ver":3,"min_ver":2}"#;
    let resp: Resp = serde_json::from_str(json).unwrap();
    let error = resp.error.unwrap();
    assert_eq!(error.reason().as_str(), "from_the_future");
    assert!(matches!(error.reason(), proto::Reason::Unknown(_)));
}

#[test]
fn snapshot_flow_failed_push() {
    let push = FlowFailedPush {
        node_id: "ab".repeat(32),
        queue_sequence: 7,
        pairing_id: "epoch-1".into(),
        lease_token: "lease-7".into(),
        reason: proto::Reason::StorageFull,
    };
    assert_roundtrip(&push);
    snapshot_message("flow_failed_push", &push);
}

/// #1122：关闭码注册表（两端手机的契约测试读这个快照）。
#[test]
fn close_codes_registry() {
    let json: Vec<_> = proto::close_codes::ALL
        .iter()
        .map(|(code, reason)| serde_json::json!({ "code": code, "reason": reason }))
        .collect();
    insta::assert_json_snapshot!(json);
}
