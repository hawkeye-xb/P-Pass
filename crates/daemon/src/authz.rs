//! Authorization checkpoint (详细设计 §2.3): every inbound request passes
//! exactly one gate — the NodeId has a pairing record (#1117), and its role
//! allows the method. **没有其他任何认证机制——简单性即安全性。**
//!
//! Pure logic, fully unit-tested; the router feeds it the pairing record
//! from the in-memory copy (`Db::active_pairing`), never a database lookup.

use proto::msgs::methods;
use proto::Reason;
use storage::{Pairing, Role};

/// The verdict for one request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Allow,
    /// Denied: respond with this reason, close the stream, record a diag
    /// event.
    Deny {
        /// `not_paired` (no pairing record — never paired, disconnected,
        /// removed or the desktop changed identity: #1117 deletes the record,
        /// so they are all the same), `unsupported_method` (the method is in
        /// no role's table) or
        /// `role_forbidden` (the role does not permit the method).
        reason: Reason,
    },
}

/// #546: pseudo-method for the blobs data plane (`ALPN_BLOBS`). Not a wire
/// method — it never appears in a `Req` — but the blobs gate
/// (`blobs_gate.rs`) passes it through [`check`] so the data plane is judged
/// by this same table: peers without a pairing record are denied, every paired
/// role may read (a viewer can already obtain a ticket via
/// `asset.blob_ticket`).
pub const BLOBS_FETCH: &str = "blobs.fetch";

/// Methods an unpaired device may call: the pairing door and nothing else.
/// (`hello` is capability negotiation and carries no data.)
///
/// NET-10 (#128): `pair.status` is part of the pairing door. The gate
/// lets **every** caller through — unpaired and every role — because the
/// same phone keeps polling across its own state change (unpaired while
/// pending → member the moment the owner allows).
/// Scoping is done by the handler, not here: `router.rs`
/// `handle_pair_status` answers only for request_ids submitted by the
/// caller's own NodeId and reports any other id as `not_found`.
///
/// DEV-07 (#463): `pair.cancel` is the same door with the same scoping —
/// the withdrawing phone is exactly as unpaired as it was when it
/// submitted, and `handle_pair_cancel` only touches the caller's own ids.
///
/// #1118: `pair.confirm` (the phone's key confirmation) is the same door with the same
/// scoping — `handle_pair_confirm` only checks the caller's own request.
const UNPAIRED_METHODS: &[&str] = &[
    methods::HELLO,
    methods::PAIR_REQUEST,
    methods::PAIR_STATUS,
    methods::PAIR_CANCEL,
    methods::PAIR_CONFIRM,
];

/// #1070: a method some door admits — the unpaired door or any role's
/// table. Anything else is not "forbidden for this role", it does not exist.
fn is_known_method(method: &str) -> bool {
    UNPAIRED_METHODS.contains(&method) || role_allows(Role::Member, method)
}

/// 权限表 (T-030): viewer 只许浏览/诊断; member 加 backup.* 和新 Flow
/// delivery。pair 确认走 IPC 而非网络方法（见 T-034），所以没有任何已配对
/// 角色能经网络调 pair.request（#1050：Owner 角色已退役）。
fn role_allows(role: Role, method: &str) -> bool {
    let viewer_ok = matches!(
        method,
        methods::HELLO
            | methods::TIMELINE_PAGE
            | methods::ASSET_META
            | methods::THUMB_GET
            | methods::ASSET_BLOB_TICKET
            | methods::ASSET_DOWNLOAD
            | methods::DIAG_STATUS
            | methods::TIMELINE_SUBSCRIBE
            | BLOBS_FETCH
    );
    // UX-06: 任一端可单方停止——任何已配对角色都可以撤销自己
    // （device.unpair 只作用于调用者自身，无需 owner 在场）。
    let self_unpair = method == methods::DEVICE_UNPAIR;
    let member_delivery = method.starts_with("backup.") || method.starts_with("flow.");
    // NET-10: see UNPAIRED_METHODS — own-request scoping lives in the handler.
    if method == methods::PAIR_STATUS
        || method == methods::PAIR_CANCEL
        || method == methods::PAIR_CONFIRM
    {
        return true;
    }
    match role {
        Role::Viewer => viewer_ok || self_unpair,
        Role::Member => viewer_ok || self_unpair || member_delivery,
    }
}

/// The checkpoint. `pairing` is the connection's pairing record (`None` =
/// not paired: never paired, or the record was deleted).
pub fn check(pairing: Option<&Pairing>, method: &str) -> Decision {
    match pairing {
        // 没有配对记录：只有配对这扇门。被移除 / 自己断开 / 电脑换了身份的
        // 设备都一样——它们的配对记录已删除（#1117），没有新令牌过不了配对。
        None => {
            if UNPAIRED_METHODS.contains(&method) {
                Decision::Allow
            } else {
                Decision::Deny {
                    reason: Reason::NotPaired,
                }
            }
        }
        Some(p) => {
            if role_allows(p.role, method) {
                Decision::Allow
            } else if !is_known_method(method) {
                Decision::Deny {
                    reason: Reason::UnsupportedMethod,
                }
            } else {
                Decision::Deny {
                    reason: Reason::RoleForbidden,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(role: Role) -> Pairing {
        Pairing {
            id: "p".into(),
            node_id: vec![7; 32],
            role,
            paired_at: 0,
        }
    }

    fn allowed(d: Option<&Pairing>, m: &str) -> bool {
        check(d, m) == Decision::Allow
    }

    #[test]
    fn unpaired_may_only_knock_on_the_pairing_door() {
        assert!(allowed(None, methods::HELLO));
        assert!(allowed(None, methods::PAIR_REQUEST));
        for m in [
            methods::TIMELINE_PAGE,
            methods::THUMB_GET,
            methods::BACKUP_BEGIN,
            methods::DIAG_STATUS,
            methods::TIMELINE_SUBSCRIBE,
        ] {
            assert_eq!(
                check(None, m),
                Decision::Deny {
                    reason: Reason::NotPaired
                },
                "unpaired must not reach {m}"
            );
        }
    }

    #[test]
    fn viewer_browses_but_never_backs_up() {
        let d = device(Role::Viewer);
        for m in [
            methods::HELLO,
            methods::TIMELINE_PAGE,
            methods::ASSET_META,
            methods::THUMB_GET,
            methods::ASSET_BLOB_TICKET,
            methods::DIAG_STATUS,
            methods::TIMELINE_SUBSCRIBE,
        ] {
            assert!(allowed(Some(&d), m), "viewer must reach {m}");
        }
        for m in [
            methods::BACKUP_BEGIN,
            methods::BACKUP_MANIFEST,
            methods::BACKUP_COMMIT,
            methods::FLOW_OFFER,
            methods::FLOW_STATUS,
            methods::FLOW_SUSPEND,
            methods::FLOW_CANCEL_TUPLE,
            methods::FLOW_AUDIT_SUBMIT,
            methods::PAIR_REQUEST,
        ] {
            assert!(!allowed(Some(&d), m), "viewer must not reach {m}");
        }
    }

    #[test]
    fn member_adds_backup_star() {
        let d = device(Role::Member);
        assert!(allowed(Some(&d), methods::BACKUP_BEGIN));
        assert!(allowed(Some(&d), methods::BACKUP_MANIFEST));
        assert!(allowed(Some(&d), methods::BACKUP_COMMIT));
        assert!(allowed(Some(&d), methods::FLOW_OFFER));
        assert!(allowed(Some(&d), methods::FLOW_STATUS));
        assert!(allowed(Some(&d), methods::FLOW_SUSPEND));
        assert!(allowed(Some(&d), methods::FLOW_CANCEL_TUPLE));
        assert!(allowed(Some(&d), methods::FLOW_AUDIT_SUBMIT));
        assert!(!allowed(Some(&d), methods::PAIR_REQUEST));
    }

    /// NET-10: the phone polls pair.status across its own state change —
    /// unpaired while pending, member right after Allow. Every
    /// state must pass the gate (scoping is the handler's job).
    #[test]
    fn pair_status_passes_the_gate_in_every_device_state() {
        assert!(allowed(None, methods::PAIR_STATUS));
        for role in [Role::Viewer, Role::Member] {
            assert!(
                allowed(Some(&device(role)), methods::PAIR_STATUS),
                "{role:?} must be able to read its own pair.status"
            );
        }
    }

    /// DEV-07 (#463): the withdrawing phone is in whatever state it was
    /// when it submitted (unpaired), or already a member if the
    /// owner's Allow won the race — every state must reach the handler,
    /// which scopes by NodeId and no-ops on settled requests.
    #[test]
    fn pair_cancel_passes_the_gate_in_every_device_state() {
        assert!(allowed(None, methods::PAIR_CANCEL));
        for role in [Role::Viewer, Role::Member] {
            assert!(
                allowed(Some(&device(role)), methods::PAIR_CANCEL),
                "{role:?} must be able to withdraw its own pair.request"
            );
        }
    }

    /// #546: the blobs data plane is one more door behind the same gate.
    #[test]
    fn blobs_fetch_needs_a_live_pairing() {
        assert_eq!(
            check(None, BLOBS_FETCH),
            Decision::Deny {
                reason: Reason::NotPaired
            }
        );
        for role in [Role::Viewer, Role::Member] {
            assert!(allowed(Some(&device(role)), BLOBS_FETCH));
        }
    }

    /// #1070: the denials carry distinct reasons. #1117: a deleted pairing
    /// record is simply "not paired" — there is no separate revoked state.
    #[test]
    fn each_denial_names_its_own_reason() {
        let deny = |reason| Decision::Deny { reason };
        assert_eq!(check(None, methods::TIMELINE_PAGE), deny(Reason::NotPaired));
        assert_eq!(
            check(Some(&device(Role::Viewer)), methods::FLOW_OFFER),
            deny(Reason::RoleForbidden)
        );
        assert_eq!(
            check(Some(&device(Role::Member)), methods::PAIR_REQUEST),
            deny(Reason::RoleForbidden),
            "pair.request is a known door, just not for a paired role"
        );
        assert_eq!(
            check(Some(&device(Role::Member)), "asset.delete_all"),
            deny(Reason::UnsupportedMethod)
        );
        assert_eq!(
            check(Some(&device(Role::Viewer)), "asset.delete_all"),
            deny(Reason::UnsupportedMethod)
        );
        // No pairing record wins over "unknown method".
        assert_eq!(check(None, "asset.delete_all"), deny(Reason::NotPaired));
    }

    #[test]
    fn unknown_methods_are_denied_for_everyone() {
        assert!(!allowed(None, "asset.delete_all"));
        assert!(!allowed(Some(&device(Role::Member)), "asset.delete_all"));
    }

    // UX-06: 任一端可单方停止——已配对设备撤销自己是放行的，
    // 没有配对记录的不行（只剩配对这扇门）。
    #[test]
    fn paired_roles_may_unpair_themselves() {
        for role in [Role::Viewer, Role::Member] {
            assert!(
                allowed(Some(&device(role)), methods::DEVICE_UNPAIR),
                "{role:?} must be able to unpair itself"
            );
        }
    }

    #[test]
    fn unpaired_may_not_unpair() {
        assert!(!allowed(None, methods::DEVICE_UNPAIR));
    }
}
