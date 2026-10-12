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
        pairing_epoch: None,
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
    };
    assert_roundtrip(&pr);
    snapshot_message("pair_request_ack_then_poll", &pr);
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
        state: "accepted".into(),
        accepted: Some(PairAccepted {
            storage_device_name: "Home PC".into(),
            pairing_epoch: "epoch-1".into(),
        }),
        msg_key: None,
    };
    assert_roundtrip(&r);
    snapshot_message("pair_status_reply_accepted", &r);
}

#[test]
fn snapshot_pair_status_reply_denied() {
    let r = PairStatusReply {
        state: "denied".into(),
        accepted: None,
        msg_key: Some("err.not_authorized".into()),
    };
    assert_roundtrip(&r);
    snapshot_message("pair_status_reply_denied", &r);
}

#[test]
fn snapshot_pair_accepted() {
    let pa = PairAccepted {
        storage_device_name: "Home PC".into(),
        pairing_epoch: "epoch-1".into(),
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

    let uh = UploadHeader {
        hash: "eee4444444444444444444444444444444444444444444444444444444444444".into(),
        bytes: 3_500_000,
        file_name: "IMG_0099.HEIC".into(),
    };
    assert_roundtrip(&uh);
    snapshot_message("upload_header", &uh);
}

// ── #851 flow.supersede ─────────────────────────────

#[test]
fn snapshot_flow_supersede() {
    let req = FlowSupersedeRequest {
        pairing_epoch: "epoch-7".into(),
        old_hash: "aaa1111111111111111111111111111111111111111111111111111111111111".into(),
        new_hash: "bbb2222222222222222222222222222222222222222222222222222222222222".into(),
        provider: "blobticket-example".into(),
    };
    assert_roundtrip(&req);
    snapshot_message("flow_supersede_request", &req);

    let replaced = FlowSupersedeReply {
        outcome: "replaced".into(),
        reason: String::new(),
    };
    assert_roundtrip(&replaced);
    snapshot_message("flow_supersede_reply_replaced", &replaced);

    let refused = FlowSupersedeReply {
        outcome: "refused".into(),
        reason: "not_a_redaction".into(),
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
    // A paired Desktop's hello reply: pairing_epoch + health present.
    let hello = Hello {
        proto_ver: 1,
        capabilities: vec!["thumbnail.v1".into(), "flow.supersede.v1".into()],
        device_name: "Home PC".into(),
        pairing_epoch: Some("epoch-7".into()),
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
        pairing_epoch: "epoch-7".into(),
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
        pairing_epoch: "epoch-7".into(),
        lease_token: "lease-1790574682018".into(),
    };
    assert_roundtrip(&tuple);
    snapshot_message("flow_tuple_ref", &tuple);

    let receipt = FlowCompletionReceipt {
        queue_sequence: 1_790_574_682_018,
        receipt_id: "460400000000000000000000000000000000000000000000000000000000510f".into(),
        pairing_epoch: "epoch-7".into(),
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
        min_ver: 1,
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
        proto::RespError::new("NOT_FOUND", "err.not_found"),
    );
    assert_roundtrip(&resp);
    snapshot_message("resp_err_envelope", &resp);
    snapshot_frame("resp_err_envelope", &resp);
}
