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
    };
    assert_roundtrip(&pr);
    snapshot_message("pair_request", &pr);
}

#[test]
fn snapshot_pair_accepted() {
    let pa = PairAccepted {
        storage_device_name: "Home PC".into(),
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
            },
            AssetMeta {
                hash: "c3d2e1f0a0000000000000000000000000000000000000000000000000000000".into(),
                taken_at: 1690003600,
                media_type: "video".into(),
                width: 1920,
                height: 1080,
                bytes: 50_000_000,
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
