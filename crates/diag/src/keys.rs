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
    /// Connected to the storage daemon over a direct (or LAN) path.
    DIAG_ONLINE_DIRECT => "diag.online_direct",
    /// Connected, but through a relay — bandwidth may be limited.
    DIAG_ONLINE_RELAY => "diag.online_relay",
    /// Storage daemon unreachable; UI shows last_seen in human terms.
    DIAG_STORAGE_OFFLINE => "diag.storage_offline",
    /// Media pipeline is (re)indexing the library.
    DIAG_INDEXING => "diag.indexing",
    /// A pairing request is waiting for owner confirmation.
    DIAG_PAIRING => "diag.pairing",
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
            DIAG_ONLINE_DIRECT,
            DIAG_ONLINE_RELAY,
            DIAG_STORAGE_OFFLINE,
            DIAG_INDEXING,
            DIAG_PAIRING,
        ] {
            assert!(ALL.contains(&key), "{key} missing from ALL");
        }
        assert_eq!(ALL.len(), 9);
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
                key.starts_with("err.") || key.starts_with("diag."),
                "msg_key must live under err.* or diag.*: {key}"
            );
        }
    }
}
