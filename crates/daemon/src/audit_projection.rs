//! 审计的用户投影（#1044 B1）：哪些审计事件给用户看、每轮计数怎么分类，
//! 由 daemon 决定；桌面只按 kind 取文案渲染。
//!
//! 过去这两条规则写在桌面 JS（`auditProjection.js`），daemon 先按条数截断
//! 再交给前端过滤——监听一次拖入几百张写几百条 `ingest.new`，可见事件被挤出
//! 窗口。现在 `audit.list(visibility:"user")` 在 SQL 里先排除隐藏 kind，再截断。
//!
//! 分类（每个 daemon 自己写的 kind 都必须落在「有文案」或「隐藏」之一，
//! 单测钉住）：
//! - 有文案：[`USER_KINDS_WITH_COPY`]——桌面字典里各有一条。
//! - 隐藏：[`HIDDEN_KINDS`]、[`HIDDEN_PREFIXES`]——连接/控制/逐项入库与索引
//!   维护噪音，留在诊断层（诊断包 `audit.json` 不经此过滤）。
//! - 其余（手机将来新增、桌面尚无文案的 kind）照旧可见，桌面出兜底文案，
//!   事实不被静默吞掉。

/// 桌面有专门文案的 kind。
pub const USER_KINDS_WITH_COPY: &[&str] = &[
    "pair.requested",
    "pair.accepted",
    "pair.denied",
    "pair.cancelled",
    "pair.expired",
    "asset.removed_external",
    "device.renamed",
    "device.revoked",
    "device.unpaired",
    "device.merged",
    "flow.round.finished",
    "flow.reconciliation.resolved",
];

/// 不给用户看的 kind（精确名）。
pub const HIDDEN_KINDS: &[&str] = &[
    "device.connected",
    "flow.round.controlled",
    "flow.scope.changed",
    "flow.epoch.invalidated",
    // 入库例外与索引维护：数据层面的事实，用户层面没有可做的事。
    "asset.relocated",
    "asset.replaced_in_place",
    "asset.superseded",
    "index.rebuild",
    "index.adopted",
    "backup.commit",
];

/// 不给用户看的 kind 族（前缀）。
pub const HIDDEN_PREFIXES: &[&str] = &["ingest.", "flow.item."];

/// `visibility:"user"` 口径下这条 kind 是否可见。
pub fn is_user_visible(kind: &str) -> bool {
    !HIDDEN_KINDS.contains(&kind) && !HIDDEN_PREFIXES.iter().any(|p| kind.starts_with(p))
}

/// 一轮备份的用户口径计数，由 daemon 重算的 `evidence_summary`（按 item
/// evidence outcome 计数）分类得出——绝不读手机自报的 final_counts。
/// 已备份 = confirmed；需处理 = failed + remote_missing；已跳过 = source_missing。
pub fn round_counts(evidence_summary: &serde_json::Value) -> serde_json::Value {
    let n = |k: &str| {
        evidence_summary
            .get(k)
            .and_then(|v| v.as_u64())
            .unwrap_or(0)
    };
    serde_json::json!({
        "backedUp": n("confirmed"),
        "needsAttention": n("failed") + n("remote_missing"),
        "skipped": n("source_missing"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// daemon（含 core-index、storage）自己写进 `audit_operation` 的全部 kind。
    /// 新增写审计的地方必须同步登记，并在下面的分类里二选一。
    const DAEMON_WRITTEN_KINDS: &[&str] = &[
        // pairing.rs
        "pair.requested",
        "pair.accepted",
        "pair.denied",
        "pair.cancelled",
        "pair.expired",
        // ipc.rs / router.rs / storage device_repo.rs
        "device.revoked",
        "device.renamed",
        "device.unpaired",
        // reconcile.rs
        "asset.removed_external",
        // flow_delivery.rs（#851）
        "asset.superseded",
        // core-index ingest.rs / rebuild.rs
        "ingest.new",
        "ingest.duplicate",
        "asset.relocated",
        "asset.replaced_in_place",
        "index.rebuild",
        "index.adopted",
        // audit_route.rs（手机事实路由成 operation）
        "flow.round.finished",
        "flow.reconciliation.resolved",
        "flow.round.controlled",
        "flow.scope.changed",
        "flow.epoch.invalidated",
    ];

    #[test]
    fn every_daemon_written_kind_has_copy_or_is_explicitly_hidden() {
        for kind in DAEMON_WRITTEN_KINDS {
            let has_copy = USER_KINDS_WITH_COPY.contains(kind);
            let hidden = !is_user_visible(kind);
            assert!(
                has_copy ^ hidden,
                "{kind}: 必须恰好落在「有文案」或「隐藏」之一（has_copy={has_copy}, hidden={hidden}）"
            );
        }
    }

    /// 源码对账：daemon / core-index 里写审计的调用点出现的 kind 字面量都已
    /// 登记在 [`DAEMON_WRITTEN_KINDS`]。防止新写一种审计却忘了分类。
    #[test]
    fn registry_covers_every_audit_literal_in_source() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        let kind_re = |line: &str| -> Vec<String> {
            line.split('"')
                .skip(1)
                .step_by(2)
                .filter(|s| {
                    let parts: Vec<&str> = s.split('.').collect();
                    parts.len() >= 2
                        && [
                            "pair", "device", "asset", "index", "ingest", "flow", "backup",
                        ]
                        .contains(&parts[0])
                        && parts.iter().all(|p| {
                            !p.is_empty() && p.chars().all(|c| c.is_ascii_lowercase() || c == '_')
                        })
                })
                .map(str::to_string)
                .collect()
        };
        let mut missing = Vec::new();
        for dir in ["daemon/src", "core-index/src"] {
            for entry in std::fs::read_dir(root.join(dir)).unwrap() {
                let path = entry.unwrap().path();
                if path.extension().is_none_or(|e| e != "rs") {
                    continue;
                }
                let text = std::fs::read_to_string(&path).unwrap();
                // 只看非测试代码。
                let text = text.split("#[cfg(test)]").next().unwrap_or("");
                let lines: Vec<&str> = text.lines().collect();
                for (i, line) in lines.iter().enumerate() {
                    if !(line.contains("AuditEntry::local(") || line.contains("self.audit(")) {
                        continue;
                    }
                    for l in &lines[i..(i + 8).min(lines.len())] {
                        for k in kind_re(l) {
                            if !DAEMON_WRITTEN_KINDS.contains(&k.as_str()) {
                                missing.push(format!("{}: {k}", path.display()));
                            }
                        }
                    }
                }
            }
        }
        assert!(missing.is_empty(), "未登记的审计 kind：{missing:?}");
    }

    #[test]
    fn unknown_future_kinds_stay_visible_with_fallback_copy() {
        assert!(is_user_visible("flow.some_future_kind"));
        assert!(!USER_KINDS_WITH_COPY.contains(&"flow.some_future_kind"));
    }

    #[test]
    fn round_counts_classify_evidence_outcomes() {
        let summary = serde_json::json!({ "confirmed": 2, "failed": 1, "remote_missing": 2, "source_missing": 1 });
        assert_eq!(
            round_counts(&summary),
            serde_json::json!({ "backedUp": 2, "needsAttention": 3, "skipped": 1 })
        );
        assert_eq!(
            round_counts(&serde_json::Value::Null),
            serde_json::json!({ "backedUp": 0, "needsAttention": 0, "skipped": 0 })
        );
    }
}
