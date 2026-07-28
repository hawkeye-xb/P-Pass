//! Diagnostics — msg_key dictionary + daemon state machine (T-003).
//!
//! Pure logic crate: no IO, no transport, no platform. The i18n JSON files
//! are embedded at compile time so translation coverage is enforced by
//! `cargo test` (and thus CI) — a missing key never reaches runtime.

pub mod keys;
pub mod state;

pub use state::{DaemonEvent, DaemonState};

/// English translation table, embedded from `assets/i18n/en.json`.
pub const I18N_EN: &str = include_str!("../../../assets/i18n/en.json");
/// Chinese translation table, embedded from `assets/i18n/zh.json`.
pub const I18N_ZH: &str = include_str!("../../../assets/i18n/zh.json");

/// Panics if any registered msg_key lacks a translation in either language,
/// or if a translation file contains keys that are not registered (drift in
/// the other direction). Intended to be called from tests — including the
/// UI layers' own test suites when they add keys (T-072).
pub fn assert_all_keys_translated() {
    for (lang, raw) in [("en", I18N_EN), ("zh", I18N_ZH)] {
        let table: serde_json::Value =
            serde_json::from_str(raw).unwrap_or_else(|e| panic!("i18n/{lang}.json invalid: {e}"));
        let table = table
            .as_object()
            .unwrap_or_else(|| panic!("i18n/{lang}.json must be a flat JSON object"));

        for key in keys::ALL {
            let value = table
                .get(*key)
                .unwrap_or_else(|| panic!("i18n/{lang}.json missing msg_key: {key}"));
            let text = value
                .as_str()
                .unwrap_or_else(|| panic!("i18n/{lang}.json value for {key} must be a string"));
            assert!(
                !text.trim().is_empty(),
                "i18n/{lang}.json has empty translation for {key}"
            );
        }
        for key in table.keys() {
            assert!(
                keys::ALL.contains(&key.as_str()),
                "i18n/{lang}.json contains unregistered key: {key} (register it in keys.rs)"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn all_keys_translated_in_en_and_zh() {
        super::assert_all_keys_translated();
    }
}
