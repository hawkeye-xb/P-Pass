//! Authorization checkpoint (详细设计 §2.3): every inbound request passes
//! exactly one gate — NodeId in the whitelist and not revoked, role allows
//! the method. **没有其他任何认证机制——简单性即安全性。**
//!
//! Pure logic, fully unit-tested; the router feeds it the device row.

use proto::msgs::methods;
use storage::{Device, Role};

/// The verdict for one request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Allow,
    /// Denied: respond `NOT_AUTHORIZED` with this msg_key, close the
    /// stream, record a diag event.
    Deny {
        /// `err.not_paired` (unknown NodeId) or `err.not_authorized`
        /// (revoked, or role does not permit the method).
        msg_key: &'static str,
    },
}

/// Methods an unpaired device may call: the pairing door and nothing else.
/// (`hello` is capability negotiation and carries no data.)
const UNPAIRED_METHODS: &[&str] = &[methods::HELLO, methods::PAIR_REQUEST];

/// 权限表 (T-030 卡面): viewer 只许浏览/诊断; member 加 backup.*;
/// owner 全部（pair 确认走 IPC 而非网络方法，见 T-034）.
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
    );
    // UX-06: 任一端可单方停止——任何已配对角色都可以撤销自己
    // （device.unpair 只作用于调用者自身，无需 owner 在场）。
    let self_unpair = method == methods::DEVICE_UNPAIR;
    match role {
        Role::Viewer => viewer_ok || self_unpair,
        Role::Member => viewer_ok || self_unpair || method.starts_with("backup."),
        Role::Owner => {
            viewer_ok
                || self_unpair
                || method.starts_with("backup.")
                || method == methods::PAIR_REQUEST
        }
    }
}

/// The checkpoint. `device` is the whitelist row for the connection's
/// NodeId (`None` = never paired).
pub fn check(device: Option<&Device>, method: &str) -> Decision {
    match device {
        None => {
            if UNPAIRED_METHODS.contains(&method) {
                Decision::Allow
            } else {
                Decision::Deny {
                    msg_key: diag::keys::ERR_NOT_PAIRED,
                }
            }
        }
        // 吊销即拒连 (§2.2)……除了重新配对这一扇门：误移除的家人设备
        // 必须能重新加入。它没有新令牌就过不了配对（令牌在 owner 手里
        // = owner 授权），其余方法一律拒绝（走查实测抓到的产品 bug）。
        Some(d) if d.revoked => {
            if method == methods::PAIR_REQUEST {
                Decision::Allow
            } else {
                Decision::Deny {
                    msg_key: diag::keys::ERR_NOT_AUTHORIZED,
                }
            }
        }
        Some(d) => {
            if role_allows(d.role, method) {
                Decision::Allow
            } else {
                Decision::Deny {
                    msg_key: diag::keys::ERR_NOT_AUTHORIZED,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(role: Role, revoked: bool) -> Device {
        Device {
            node_id: vec![7; 32],
            name: "t".into(),
            role,
            paired_at: 0,
            last_seen: None,
            revoked,
            device_hint: None,
        }
    }

    fn allowed(d: Option<&Device>, m: &str) -> bool {
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
        ] {
            assert_eq!(
                check(None, m),
                Decision::Deny {
                    msg_key: diag::keys::ERR_NOT_PAIRED
                },
                "unpaired must not reach {m}"
            );
        }
    }

    #[test]
    fn revoked_gets_nothing_not_even_hello() {
        let d = device(Role::Owner, true);
        for m in [
            methods::HELLO,
            methods::TIMELINE_PAGE,
            methods::BACKUP_BEGIN,
        ] {
            assert_eq!(
                check(Some(&d), m),
                Decision::Deny {
                    msg_key: diag::keys::ERR_NOT_AUTHORIZED
                },
                "revoked must not reach {m}"
            );
        }
    }

    #[test]
    fn viewer_browses_but_never_backs_up() {
        let d = device(Role::Viewer, false);
        for m in [
            methods::HELLO,
            methods::TIMELINE_PAGE,
            methods::ASSET_META,
            methods::THUMB_GET,
            methods::ASSET_BLOB_TICKET,
            methods::DIAG_STATUS,
        ] {
            assert!(allowed(Some(&d), m), "viewer must reach {m}");
        }
        for m in [
            methods::BACKUP_BEGIN,
            methods::BACKUP_MANIFEST,
            methods::BACKUP_COMMIT,
            methods::PAIR_REQUEST,
        ] {
            assert!(!allowed(Some(&d), m), "viewer must not reach {m}");
        }
    }

    #[test]
    fn member_adds_backup_star() {
        let d = device(Role::Member, false);
        assert!(allowed(Some(&d), methods::BACKUP_BEGIN));
        assert!(allowed(Some(&d), methods::BACKUP_MANIFEST));
        assert!(allowed(Some(&d), methods::BACKUP_COMMIT));
        assert!(!allowed(Some(&d), methods::PAIR_REQUEST));
    }

    #[test]
    fn owner_has_everything() {
        let d = device(Role::Owner, false);
        for m in [
            methods::HELLO,
            methods::TIMELINE_PAGE,
            methods::BACKUP_COMMIT,
            methods::PAIR_REQUEST,
        ] {
            assert!(allowed(Some(&d), m), "owner must reach {m}");
        }
    }

    #[test]
    fn unknown_methods_are_denied_for_everyone() {
        assert!(!allowed(None, "asset.delete_all"));
        assert!(!allowed(
            Some(&device(Role::Owner, false)),
            "asset.delete_all"
        ));
    }

    // UX-06: 任一端可单方停止——已配对设备撤销自己是放行的，
    // 未配对/已吊销的不行（吊销只剩 pair.request 一扇门）。
    #[test]
    fn paired_roles_may_unpair_themselves() {
        for role in [Role::Viewer, Role::Member, Role::Owner] {
            assert!(
                allowed(Some(&device(role, false)), methods::DEVICE_UNPAIR),
                "{role:?} must be able to unpair itself"
            );
        }
    }

    #[test]
    fn unpaired_and_revoked_may_not_unpair() {
        assert!(!allowed(None, methods::DEVICE_UNPAIR));
        assert!(!allowed(
            Some(&device(Role::Member, true)),
            methods::DEVICE_UNPAIR
        ));
    }
}
