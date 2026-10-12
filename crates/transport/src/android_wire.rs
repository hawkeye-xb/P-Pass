//! JSON wire shapes the Android JNI binding hands to Kotlin (IOS-05 #312:
//! split out of the provider kernel). Compiled with `android-jni`, and under
//! `test` so the shape tests run in the default host build.

use crate::provider::{ActiveTransferStatus, ImportFallback, MediaImport, SourceFault};

/// Wire shape for [`ActiveTransferStatus`] over the JNI boundary — the
/// same `state`/`hash`/`connected`/`idle_for_ms` field vocabulary the
/// daemon's own `FlowStatusReply` uses for the analogous cross-process
/// concept. Built directly as a `serde_json::Value` (this crate depends
/// on `serde_json` alone, not `serde` — adding it just for one derive
/// pulled in a dependency-tree reresolution that broke iroh-blobs'
/// pinned `irpc` version; see NET-14 card notes).
///
/// BUILD-06: 闸门写成「存在即被使用」，IOS-05 起收在模块级（`lib.rs` 里
/// `#[cfg(any(feature = "android-jni", test))] mod android_wire`）：唯一的
/// 非测试调用方是 `android_jni.rs` 的 JNI 导出，feature 关闭时 lib target 里
/// 没有调用方，整个模块不编进来，而不是用 `#[allow(dead_code)]` 盖住；加
/// `test` 让这里的形状测试在默认 feature 下仍然跑得到。
impl ActiveTransferStatus {
    pub(crate) fn to_wire(&self) -> serde_json::Value {
        match self {
            ActiveTransferStatus::NoLease => serde_json::json!({ "state": "no_lease" }),
            ActiveTransferStatus::Completed { hash } => serde_json::json!({
                "state": "completed",
                "hash": hex_of(hash),
            }),
            ActiveTransferStatus::Aborted { hash } => serde_json::json!({
                "state": "aborted",
                "hash": hex_of(hash),
            }),
            ActiveTransferStatus::InProgress {
                connected,
                idle_for,
                bytes_sent,
                byte_idle_for,
            } => serde_json::json!({
                "state": "in_progress",
                "connected": connected,
                "idle_for_ms": idle_for.map(|d| d.as_millis() as u64),
                "bytes_sent": bytes_sent,
                "byte_idle_for_ms": byte_idle_for.map(|d| d.as_millis() as u64),
            }),
        }
    }
}

fn hex_of(bytes: &[u8; 32]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Wire shape of [`MediaImport`] over the JNI boundary.
pub(crate) fn import_wire(import: &MediaImport) -> serde_json::Value {
    serde_json::json!({
        "hash": hex_of(&import.hash),
        "size": import.size,
        "by_reference": import.by_reference,
        "fallback": import.fallback.map(ImportFallback::as_str),
        "detail": import.detail,
    })
}

/// [`ActiveTransferStatus::to_wire`] plus `"source"` when the lease's
/// referenced original is gone or changed. A completed pull already has
/// every byte, so no fault is attached to it.
pub(crate) fn status_wire(
    status: &ActiveTransferStatus,
    fault: Option<SourceFault>,
) -> serde_json::Value {
    let mut wire = status.to_wire();
    if let (Some(fault), false) = (
        fault,
        matches!(status, ActiveTransferStatus::Completed { .. }),
    ) {
        wire["source"] = serde_json::Value::from(fault.as_str());
    }
    wire
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn no_lease_has_only_a_state_field() {
        assert_eq!(
            ActiveTransferStatus::NoLease.to_wire(),
            serde_json::json!({ "state": "no_lease" }),
        );
    }

    #[test]
    fn completed_carries_lowercase_hex_hash() {
        let hash = [0xabu8; 32];
        let wire = ActiveTransferStatus::Completed { hash }.to_wire();
        assert_eq!(wire["state"], "completed");
        assert_eq!(wire["hash"], "ab".repeat(32));
    }

    #[test]
    fn in_progress_reports_connected_and_idle_ms() {
        let wire = ActiveTransferStatus::InProgress {
            connected: true,
            idle_for: Some(Duration::from_millis(1234)),
            bytes_sent: Some(4096),
            byte_idle_for: Some(Duration::from_millis(180_000)),
        }
        .to_wire();
        assert_eq!(wire["state"], "in_progress");
        assert_eq!(wire["connected"], true);
        assert_eq!(wire["idle_for_ms"], 1234);
        assert_eq!(wire["bytes_sent"], 4096);
        assert_eq!(wire["byte_idle_for_ms"], 180_000);
    }

    #[test]
    fn in_progress_with_no_activity_yet_reports_null_idle() {
        let wire = ActiveTransferStatus::InProgress {
            connected: false,
            idle_for: None,
            bytes_sent: None,
            byte_idle_for: None,
        }
        .to_wire();
        assert_eq!(wire["connected"], false);
        assert!(wire["idle_for_ms"].is_null());
        assert!(wire["bytes_sent"].is_null());
        assert!(wire["byte_idle_for_ms"].is_null());
    }

    #[test]
    fn import_wire_reports_fallback_reason() {
        let wire = import_wire(&MediaImport {
            hash: [0x01; 32],
            size: 7,
            by_reference: false,
            fallback: Some(ImportFallback::NoPath),
            detail: None,
        });
        assert_eq!(wire["hash"], "01".repeat(32));
        assert_eq!(wire["size"], 7);
        assert_eq!(wire["by_reference"], false);
        assert_eq!(wire["fallback"], "no_path");
        assert!(wire["detail"].is_null());
    }

    #[test]
    fn status_wire_attaches_source_fault_except_to_completed() {
        let aborted = ActiveTransferStatus::Aborted { hash: [2; 32] };
        assert_eq!(
            status_wire(&aborted, Some(SourceFault::Changed))["source"],
            "changed"
        );
        assert!(status_wire(&aborted, None).get("source").is_none());
        let completed = ActiveTransferStatus::Completed { hash: [2; 32] };
        assert!(status_wire(&completed, Some(SourceFault::Missing))
            .get("source")
            .is_none());
    }
}
