//! Diagnostics — msg_key dictionary + daemon state machine (T-003).
//!
//! Pure logic crate: no IO, no transport, no platform. The i18n JSON files
//! are embedded at compile time so translation coverage is enforced by
//! `cargo test` (and thus CI) — a missing key never reaches runtime.

pub mod keys;
pub mod state;

pub use state::{DaemonEvent, DaemonState};

/// Desktop translation table (English), embedded from `apps/desktop/src/i18n/en.json`.
/// #1302: the desktop's own copy — every `ui.*` key plus desktop-only diag
/// variants. The daemon is desktop-side only, so its own lookups use this table.
pub const I18N_EN: &str = include_str!("../../../apps/desktop/src/i18n/en.json");
/// Desktop translation table (Chinese), embedded from `apps/desktop/src/i18n/zh.json`.
pub const I18N_ZH: &str = include_str!("../../../apps/desktop/src/i18n/zh.json");
/// Cross-end table (English), embedded from `assets/i18n/en.json`: the msg_keys
/// the daemon puts on the wire, which the phones also bundle (byte-for-byte copies).
/// Changing it rebuilds every end, so keep it to keys a phone can actually receive.
pub const I18N_SHARED_EN: &str = include_str!("../../../assets/i18n/en.json");
/// Cross-end table (Chinese), embedded from `assets/i18n/zh.json`.
pub const I18N_SHARED_ZH: &str = include_str!("../../../assets/i18n/zh.json");

fn parse_table(name: &str, raw: &str) -> serde_json::Map<String, serde_json::Value> {
    let table: serde_json::Value =
        serde_json::from_str(raw).unwrap_or_else(|e| panic!("{name} invalid: {e}"));
    match table {
        serde_json::Value::Object(m) => m,
        _ => panic!("{name} must be a flat JSON object"),
    }
}

/// Panics if any registered msg_key lacks a translation in either language,
/// if a key sits in both the desktop and the cross-end table (#1302: each key
/// has exactly one home, so a release decision by file is unambiguous), or if
/// a translation file contains keys that are not registered (drift in the
/// other direction). Intended to be called from tests — including the UI
/// layers' own test suites when they add keys (T-072).
pub fn assert_all_keys_translated() {
    for (lang, desktop_raw, shared_raw) in [
        ("en", I18N_EN, I18N_SHARED_EN),
        ("zh", I18N_ZH, I18N_SHARED_ZH),
    ] {
        let desktop_name = format!("apps/desktop/src/i18n/{lang}.json");
        let shared_name = format!("assets/i18n/{lang}.json");
        let desktop = parse_table(&desktop_name, desktop_raw);
        let shared = parse_table(&shared_name, shared_raw);

        for key in shared.keys() {
            assert!(
                !desktop.contains_key(key),
                "{key} is in both {shared_name} and {desktop_name} — keep it in one"
            );
        }
        for key in keys::ALL {
            let (name, value) = match (shared.get(*key), desktop.get(*key)) {
                (Some(v), _) => (&shared_name, v),
                (None, Some(v)) => (&desktop_name, v),
                (None, None) => {
                    panic!("msg_key {key} missing from both {shared_name} and {desktop_name}")
                }
            };
            let text = value
                .as_str()
                .unwrap_or_else(|| panic!("{name} value for {key} must be a string"));
            assert!(
                !text.trim().is_empty(),
                "{name} has empty translation for {key}"
            );
        }
        for (name, table) in [(&shared_name, &shared), (&desktop_name, &desktop)] {
            for key in table.keys() {
                assert!(
                    keys::ALL.contains(&key.as_str()),
                    "{name} contains unregistered key: {key} (register it in keys.rs)"
                );
            }
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
