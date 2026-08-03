//! msg_key dictionary — the single registry of user-visible message keys.
//!
//! Every key registered here MUST have a translation in both
//! `assets/i18n/en.json` and `assets/i18n/zh.json`; this is enforced by
//! [`crate::assert_all_keys_translated`], which runs as a test.

/// Registers msg_keys as compile-time constants and collects them into
/// [`ALL`] so coverage tests can iterate the full dictionary.
macro_rules! msg_keys {
    ($($(#[$doc:meta])* $name:ident => $key:literal),+ $(,)?) => {
        $($(#[$doc])* pub const $name: &str = $key;)+

        /// Every registered msg_key.
        pub const ALL: &[&str] = &[$($key),+];
    };
}

msg_keys! {
    /// Peer NodeId is not in the device whitelist (or was revoked).
    ERR_NOT_AUTHORIZED => "err.not_authorized",
    /// Peer attempted an operation that requires pairing first.
    ERR_NOT_PAIRED => "err.not_paired",
    /// Storage-side disk has no room for further ingest.
    ERR_DISK_FULL => "err.disk_full",
    /// Method exists in no shipped version, or is not implemented yet
    /// (a newer client talking to an older storage daemon).
    ERR_UNSUPPORTED => "err.unsupported",
    /// A backup batch could not be completed (transfer or ingest failed);
    /// the client retries — the pipeline is idempotent.
    ERR_BACKUP_FAILED => "err.backup_failed",
    /// Connected to the storage daemon over a direct (or LAN) path.
    DIAG_ONLINE_DIRECT => "diag.online_direct",
    /// Connected, but through a relay — bandwidth may be limited.
    DIAG_ONLINE_RELAY => "diag.online_relay",
    /// Storage daemon unreachable; UI shows last_seen in human terms.
    /// Phone-perspective (the phone is looking at the storage computer).
    DIAG_STORAGE_OFFLINE => "diag.storage_offline",
    /// Media pipeline is (re)indexing the library. Phone-perspective.
    DIAG_INDEXING => "diag.indexing",
    /// A pairing request is waiting for owner confirmation.
    /// Phone-perspective ("waiting on the storage computer").
    DIAG_PAIRING => "diag.pairing",

    // ── Desktop-perspective variants (T-042b) ─────────────────────────
    // The phone-perspective keys above read oddly ON the storage computer
    // itself ("存储电脑离线了" shown by the storage computer is nonsense).
    // The desktop shell maps STATE_KEYS to these; msg_key sharing stays,
    // the dictionary gains per-surface variants. Placeholder-free on
    // purpose: the daemon status payload carries no progress/last_seen
    // values, so a placeholder would render as a literal "{progress}".
    /// Desktop shell: this computer's network link is down.
    DIAG_DESKTOP_STORAGE_OFFLINE => "diag.desktop.storage_offline",
    /// Desktop shell: a device is waiting for the owner to confirm pairing.
    DIAG_DESKTOP_PAIRING => "diag.desktop.pairing",
    /// Desktop shell: the library is being indexed (no progress value).
    DIAG_DESKTOP_INDEXING => "diag.desktop.indexing",
    /// Desktop shell: this computer's disk is full.
    DIAG_DESKTOP_DISK_FULL => "diag.desktop.disk_full",

    // ── Desktop shell UI copy (T-042b: finish the screen) ─────────────
    // UI-layer strings that were hardcoded zh in App.svelte — half-migrated
    // (locale-aware badge + zh buttons) is worse than not migrated.
    UI_OFFLINE_BANNER => "ui.offline_banner",
    UI_OFFLINE_ACTION => "ui.offline_action",
    UI_START_SERVICE => "ui.start_service",
    UI_STARTING => "ui.starting",
    UI_REFRESH_HINT => "ui.refresh_hint",
    UI_PAIRED_COUNT => "ui.paired_count",
    UI_REVOKED_COUNT => "ui.revoked_count",
    UI_PENDING_PAIRS => "ui.pending_pairs",
    UI_ALLOW => "ui.allow",
    UI_DENY => "ui.deny",
    UI_ADD_DEVICE => "ui.add_device",
    UI_GENERATE_QR => "ui.generate_qr",
    UI_QR_FALLBACK => "ui.qr_fallback",
    UI_QR_HINT => "ui.qr_hint",
    UI_DEVICES => "ui.devices",
    UI_NO_DEVICES => "ui.no_devices",
    UI_REVOKED_TAG => "ui.revoked_tag",
    UI_REMOVE => "ui.remove",
    UI_SETTINGS => "ui.settings",
    UI_OPEN_LIBRARY => "ui.open_library",
    UI_CHANGE_LIBRARY => "ui.change_library",
    UI_EXPORT_LOGS => "ui.export_logs",
    UI_LOGS_HINT => "ui.logs_hint",
    UI_STOP_SERVICE => "ui.stop_service",
    UI_STOP_HINT => "ui.stop_hint",
    UI_STOP_CONFIRM_TITLE => "ui.stop_confirm_title",
    UI_STOP_CONFIRM_BODY => "ui.stop_confirm_body",
    UI_SERVICE_STOPPED => "ui.service_stopped",
    UI_STOP_FAILED => "ui.stop_failed",
    UI_START_FAILED => "ui.start_failed",
    UI_PAIR_FAILED => "ui.pair_failed",
    UI_PAIR_ALLOWED => "ui.pair_allowed",
    UI_PAIR_DENIED => "ui.pair_denied",
    UI_CONFIRM_FAILED => "ui.confirm_failed",
    UI_REVOKE_CONFIRM_TITLE => "ui.revoke_confirm_title",
    UI_REVOKE_CONFIRM_BODY => "ui.revoke_confirm_body",
    UI_REVOKED => "ui.revoked",
    UI_REVOKE_FAILED => "ui.revoke_failed",
    UI_OPEN_FAILED => "ui.open_failed",
    UI_CHANGE_TITLE => "ui.change_title",
    UI_CHANGE_BODY => "ui.change_body",
    UI_CHANGE_SAVED => "ui.change_saved",
    UI_SAVE_FAILED => "ui.save_failed",
    UI_LOGS_EXPORTED => "ui.logs_exported",
    UI_EXPORT_FAILED => "ui.export_failed",
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_contains_every_constant() {
        for key in [
            ERR_NOT_AUTHORIZED,
            ERR_NOT_PAIRED,
            ERR_DISK_FULL,
            ERR_UNSUPPORTED,
            ERR_BACKUP_FAILED,
            DIAG_ONLINE_DIRECT,
            DIAG_ONLINE_RELAY,
            DIAG_STORAGE_OFFLINE,
            DIAG_INDEXING,
            DIAG_PAIRING,
            DIAG_DESKTOP_STORAGE_OFFLINE,
            DIAG_DESKTOP_PAIRING,
            DIAG_DESKTOP_INDEXING,
            DIAG_DESKTOP_DISK_FULL,
            UI_OFFLINE_BANNER,
            UI_OFFLINE_ACTION,
            UI_START_SERVICE,
            UI_STARTING,
            UI_REFRESH_HINT,
            UI_PAIRED_COUNT,
            UI_REVOKED_COUNT,
            UI_PENDING_PAIRS,
            UI_ALLOW,
            UI_DENY,
            UI_ADD_DEVICE,
            UI_GENERATE_QR,
            UI_QR_FALLBACK,
            UI_QR_HINT,
            UI_DEVICES,
            UI_NO_DEVICES,
            UI_REVOKED_TAG,
            UI_REMOVE,
            UI_SETTINGS,
            UI_OPEN_LIBRARY,
            UI_CHANGE_LIBRARY,
            UI_EXPORT_LOGS,
            UI_LOGS_HINT,
            UI_STOP_SERVICE,
            UI_STOP_HINT,
            UI_STOP_CONFIRM_TITLE,
            UI_STOP_CONFIRM_BODY,
            UI_SERVICE_STOPPED,
            UI_STOP_FAILED,
            UI_START_FAILED,
            UI_PAIR_FAILED,
            UI_PAIR_ALLOWED,
            UI_PAIR_DENIED,
            UI_CONFIRM_FAILED,
            UI_REVOKE_CONFIRM_TITLE,
            UI_REVOKE_CONFIRM_BODY,
            UI_REVOKED,
            UI_REVOKE_FAILED,
            UI_OPEN_FAILED,
            UI_CHANGE_TITLE,
            UI_CHANGE_BODY,
            UI_CHANGE_SAVED,
            UI_SAVE_FAILED,
            UI_LOGS_EXPORTED,
            UI_EXPORT_FAILED,
        ] {
            assert!(ALL.contains(&key), "{key} missing from ALL");
        }
        assert_eq!(ALL.len(), 59);
    }

    #[test]
    fn keys_are_unique_and_well_formed() {
        let mut seen = std::collections::HashSet::new();
        for key in ALL {
            assert!(seen.insert(key), "duplicate msg_key: {key}");
            assert!(
                key.chars()
                    .all(|c| c.is_ascii_lowercase() || c == '.' || c == '_'),
                "msg_key must be lowercase dotted snake_case: {key}"
            );
            assert!(
                key.starts_with("err.") || key.starts_with("diag.") || key.starts_with("ui."),
                "msg_key must live under err.*, diag.* or ui.*: {key}"
            );
        }
    }
}
