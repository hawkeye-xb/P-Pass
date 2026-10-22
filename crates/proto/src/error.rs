//! P-Pass protocol — error types (protocol v2, #1070).
//!
//! An error on the wire is three layers: a coarse `code` (derived from the
//! reason, never chosen freely), a fine `reason` from the [`Reason`]
//! registry, and optional `params`. No localisation key travels: each end
//! decides its own words from `reason`.
//!
//! ```compile_fail
//! // Only a registered Reason builds an error — never a string.
//! let _ = proto::RespError::new("err.not_paired");
//! ```
//!
//! ```compile_fail
//! // The unknown-reason holder is decode-only: nothing outside this crate can fill it.
//! let _ = proto::RespError::new(proto::Reason::Unknown(proto::UnknownReason("x".into())));
//! ```
//!
//! ```compile_fail
//! // ... nor through the decode-side parser.
//! let _ = proto::RespError::new(proto::Reason::from_wire("err.not_paired"));
//! ```
//!
//! ```
//! // The public parser only yields registered reasons.
//! assert!(proto::Reason::registered("err.not_paired").is_none());
//! assert_eq!(proto::Reason::registered("not_paired"), Some(proto::Reason::NotPaired));
//! ```
//!
//! The one remaining way to hold an unregistered reason is decoding a peer's
//! frame (`serde`) — by design, so a newer peer's reason survives.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Well-known error codes — the coarse class each [`Reason`] belongs to.
pub mod codes {
    pub const NOT_AUTHORIZED: &str = "NOT_AUTHORIZED";
    pub const VERSION_MISMATCH: &str = "VERSION_MISMATCH";
    pub const INVALID_REQUEST: &str = "INVALID_REQUEST";
    pub const NOT_FOUND: &str = "NOT_FOUND";
    pub const INTERNAL: &str = "INTERNAL";
    /// The Desktop cannot store the item (full / library gone / write failed).
    pub const DESKTOP_STORAGE: &str = "DESKTOP_STORAGE";
    /// The Desktop could not pull the bytes (relay throttled, network down, peer busy).
    pub const PATH_FAILED: &str = "PATH_FAILED";
    /// A Flow request names a grant the Desktop will not advance.
    pub const FLOW_REJECTED: &str = "FLOW_REJECTED";
}

/// A reason string this build does not know. Kept verbatim so a newer
/// peer's reason survives decode (and re-encode); only this crate can
/// build one, so it can never be *sent* as a fresh error.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct UnknownReason(String);

impl UnknownReason {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// The reason registry. Adding a value does not bump the protocol version;
/// renaming or removing one does.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Reason {
    // ── Authorization ──
    /// No pairing record for this NodeId (never paired, or the record was
    /// deleted: disconnected, removed, or the desktop changed identity —
    /// #1117 removed the separate `revoked` reason).
    NotPaired,
    /// The device's role does not allow this method.
    RoleForbidden,
    /// The pairing token is invalid or already used.
    PairTokenInvalid,
    // ── Version ──
    PhoneOutdated,
    DesktopOutdated,
    // ── Request ──
    UnsupportedMethod,
    BadRequest,
    NotFound,
    // ── Server ──
    Internal,
    /// Legacy batch backup pipeline failure (retires with #990).
    BackupFailed,
    // ── Desktop storage ──
    StorageFull,
    LibraryUnavailable,
    StorageFailed,
    // ── Path ──
    FetchFailed,
    // ── Flow ──
    /// The request names a pairing record that is not the current one.
    PairingMismatch,
    /// No grant matches this exact tuple and can still advance.
    GrantNotFound,
    /// The same `queue_sequence` is already held by another completed item.
    GrantConflict,
    Cancelled,
    /// Decode-only: a reason this build does not know.
    Unknown(UnknownReason),
}

impl Reason {
    /// Every registered reason, in registry order (the `reasons_registry`
    /// snapshot pins their wire strings).
    pub const ALL: &'static [Reason] = &[
        Reason::NotPaired,
        Reason::RoleForbidden,
        Reason::PairTokenInvalid,
        Reason::PhoneOutdated,
        Reason::DesktopOutdated,
        Reason::UnsupportedMethod,
        Reason::BadRequest,
        Reason::NotFound,
        Reason::Internal,
        Reason::BackupFailed,
        Reason::StorageFull,
        Reason::LibraryUnavailable,
        Reason::StorageFailed,
        Reason::FetchFailed,
        Reason::PairingMismatch,
        Reason::GrantNotFound,
        Reason::GrantConflict,
        Reason::Cancelled,
    ];

    /// The wire string (snake_case).
    pub fn as_str(&self) -> &str {
        match self {
            Reason::NotPaired => "not_paired",
            Reason::RoleForbidden => "role_forbidden",
            Reason::PairTokenInvalid => "pair_token_invalid",
            Reason::PhoneOutdated => "phone_outdated",
            Reason::DesktopOutdated => "desktop_outdated",
            Reason::UnsupportedMethod => "unsupported_method",
            Reason::BadRequest => "bad_request",
            Reason::NotFound => "not_found",
            Reason::Internal => "internal",
            Reason::BackupFailed => "backup_failed",
            Reason::StorageFull => "storage_full",
            Reason::LibraryUnavailable => "library_unavailable",
            Reason::StorageFailed => "storage_failed",
            Reason::FetchFailed => "fetch_failed",
            Reason::PairingMismatch => "pairing_mismatch",
            Reason::GrantNotFound => "grant_not_found",
            Reason::GrantConflict => "grant_conflict",
            Reason::Cancelled => "cancelled",
            Reason::Unknown(u) => u.as_str(),
        }
    }

    /// A registered reason by its wire string (`None` for anything else).
    pub fn registered(s: &str) -> Option<Reason> {
        Reason::ALL.iter().find(|r| r.as_str() == s).cloned()
    }

    /// Decode-side parse: anything unregistered is kept as [`Reason::Unknown`].
    /// Crate-private so no caller can turn a string into a sendable error.
    pub(crate) fn from_wire(s: &str) -> Reason {
        Reason::ALL
            .iter()
            .find(|r| r.as_str() == s)
            .cloned()
            .unwrap_or_else(|| Reason::Unknown(UnknownReason(s.to_string())))
    }

    /// The coarse `code` this reason travels under.
    pub fn category(&self) -> &'static str {
        match self {
            Reason::NotPaired | Reason::RoleForbidden | Reason::PairTokenInvalid => {
                codes::NOT_AUTHORIZED
            }
            Reason::PhoneOutdated | Reason::DesktopOutdated => codes::VERSION_MISMATCH,
            Reason::UnsupportedMethod | Reason::BadRequest => codes::INVALID_REQUEST,
            Reason::NotFound => codes::NOT_FOUND,
            Reason::Internal | Reason::BackupFailed | Reason::Unknown(_) => codes::INTERNAL,
            Reason::StorageFull | Reason::LibraryUnavailable | Reason::StorageFailed => {
                codes::DESKTOP_STORAGE
            }
            Reason::FetchFailed => codes::PATH_FAILED,
            Reason::PairingMismatch
            | Reason::GrantNotFound
            | Reason::GrantConflict
            | Reason::Cancelled => codes::FLOW_REJECTED,
        }
    }
}

impl std::fmt::Display for Reason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl Serialize for Reason {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for Reason {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Ok(Reason::from_wire(&s))
    }
}

/// v1 phone safe-downgrade shim — FROZEN. The one localisation key left on
/// the wire, carried only by a version rejection of a v1 envelope. Released
/// Android 0.9.12 picks its path by this key alone: `pair.*` → the pairing
/// page's "one side may need an update"; anything else → a path failure
/// (not counted, item stays resumable). Layout: `[key, pair.* value, other value]`.
const V1_SHIM: [&str; 3] = ["msg_key", "err.unsupported", "fetch_failed"];

/// Error payload for unsuccessful responses. Built only from a [`Reason`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RespError {
    code: String,
    reason: Reason,
    params: BTreeMap<String, Value>,
    v1_shim: Option<&'static str>,
}

impl RespError {
    /// The only constructor: `code` is derived from `reason`.
    pub fn new(reason: Reason) -> Self {
        Self {
            code: reason.category().to_string(),
            reason,
            params: BTreeMap::new(),
            v1_shim: None,
        }
    }

    /// Append one parameter.
    pub fn with_param(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.params.insert(key.into(), value.into());
        self
    }

    /// Attach the frozen v1 shim for a rejection of a v1 envelope calling
    /// `method`. Only a version rejection may carry it; any other reason is
    /// returned unchanged.
    pub fn with_v1_shim(mut self, method: &str) -> Self {
        if self.reason.category() == codes::VERSION_MISMATCH {
            self.v1_shim = Some(if method.starts_with("pair.") {
                V1_SHIM[1]
            } else {
                V1_SHIM[2]
            });
        }
        self
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn reason(&self) -> &Reason {
        &self.reason
    }

    pub fn params(&self) -> &BTreeMap<String, Value> {
        &self.params
    }

    /// The v1 shim value this error carries, if any (tests and diagnostics).
    pub fn v1_shim(&self) -> Option<&'static str> {
        self.v1_shim
    }
}

impl Serialize for RespError {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let len = 2 + usize::from(!self.params.is_empty()) + usize::from(self.v1_shim.is_some());
        let mut map = s.serialize_map(Some(len))?;
        map.serialize_entry("code", &self.code)?;
        map.serialize_entry("reason", &self.reason)?;
        if !self.params.is_empty() {
            map.serialize_entry("params", &self.params)?;
        }
        if let Some(shim) = self.v1_shim {
            map.serialize_entry(V1_SHIM[0], shim)?;
        }
        map.end()
    }
}

impl<'de> Deserialize<'de> for RespError {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize, Default)]
        #[serde(default)]
        struct Wire {
            code: String,
            reason: String,
            params: BTreeMap<String, Value>,
        }
        let wire = Wire::deserialize(d)?;
        Ok(Self {
            // The code is kept as sent: a newer peer's reason may sit under a
            // class this build would not derive.
            code: wire.code,
            reason: Reason::from_wire(&wire.reason),
            params: wire.params,
            v1_shim: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_registered_reason_round_trips_and_has_a_category() {
        let known_codes = [
            codes::NOT_AUTHORIZED,
            codes::VERSION_MISMATCH,
            codes::INVALID_REQUEST,
            codes::NOT_FOUND,
            codes::INTERNAL,
            codes::DESKTOP_STORAGE,
            codes::PATH_FAILED,
            codes::FLOW_REJECTED,
        ];
        let mut seen = std::collections::HashSet::new();
        for r in Reason::ALL {
            assert!(seen.insert(r.as_str()), "duplicate wire string {r}");
            assert!(known_codes.contains(&r.category()), "{r}");
            assert_eq!(&Reason::from_wire(r.as_str()), r);
            assert!(!matches!(r, Reason::Unknown(_)));
            let e = RespError::new(r.clone());
            assert_eq!(e.code(), r.category());
        }
    }

    #[test]
    fn category_matrix_is_pinned() {
        use Reason::*;
        let expect = [
            (NotPaired, codes::NOT_AUTHORIZED),
            (RoleForbidden, codes::NOT_AUTHORIZED),
            (PairTokenInvalid, codes::NOT_AUTHORIZED),
            (PhoneOutdated, codes::VERSION_MISMATCH),
            (DesktopOutdated, codes::VERSION_MISMATCH),
            (UnsupportedMethod, codes::INVALID_REQUEST),
            (BadRequest, codes::INVALID_REQUEST),
            (NotFound, codes::NOT_FOUND),
            (Internal, codes::INTERNAL),
            (BackupFailed, codes::INTERNAL),
            (StorageFull, codes::DESKTOP_STORAGE),
            (LibraryUnavailable, codes::DESKTOP_STORAGE),
            (StorageFailed, codes::DESKTOP_STORAGE),
            (FetchFailed, codes::PATH_FAILED),
            (PairingMismatch, codes::FLOW_REJECTED),
            (GrantNotFound, codes::FLOW_REJECTED),
            (GrantConflict, codes::FLOW_REJECTED),
            (Cancelled, codes::FLOW_REJECTED),
        ];
        assert_eq!(expect.len(), Reason::ALL.len());
        for (r, code) in expect {
            assert_eq!(r.category(), code, "{r}");
        }
    }

    #[test]
    fn unknown_reason_decodes_and_keeps_its_string() {
        let e: RespError = serde_json::from_str(
            r#"{"code":"SOMETHING_NEW","reason":"from_the_future","params":{"n":1}}"#,
        )
        .unwrap();
        assert_eq!(e.reason().as_str(), "from_the_future");
        assert!(matches!(e.reason(), Reason::Unknown(_)));
        assert_eq!(e.code(), "SOMETHING_NEW");
        assert_eq!(
            serde_json::to_value(&e).unwrap(),
            serde_json::json!({"code":"SOMETHING_NEW","reason":"from_the_future","params":{"n":1}})
        );
    }

    #[test]
    fn params_are_omitted_when_empty() {
        let v = serde_json::to_value(RespError::new(Reason::NotFound)).unwrap();
        assert_eq!(
            v,
            serde_json::json!({"code":"NOT_FOUND","reason":"not_found"})
        );
    }

    #[test]
    fn v1_shim_only_rides_on_version_rejections() {
        let e = RespError::new(Reason::PhoneOutdated).with_v1_shim("pair.request");
        assert_eq!(e.v1_shim(), Some("err.unsupported"));
        let e = RespError::new(Reason::PhoneOutdated).with_v1_shim("flow.offer");
        assert_eq!(e.v1_shim(), Some("fetch_failed"));
        let e = RespError::new(Reason::NotPaired).with_v1_shim("hello");
        assert_eq!(e.v1_shim(), None);
        let v = serde_json::to_value(RespError::new(Reason::PhoneOutdated).with_v1_shim("hello"))
            .unwrap();
        assert_eq!(v[V1_SHIM[0]], "fetch_failed");
        assert_eq!(v["code"], codes::VERSION_MISMATCH);
    }

    /// The frozen values: never a pairing-lost substring, never a storage reason,
    /// never NOT_AUTHORIZED (#1069 §5).
    #[test]
    fn v1_shim_values_are_frozen_and_safe() {
        assert_eq!(V1_SHIM, ["msg_key", "err.unsupported", "fetch_failed"]);
        for v in &V1_SHIM[1..] {
            assert!(!v.contains("err.not_paired") && !v.contains("err.not_authorized"));
            assert!(!v.starts_with("storage_") && *v != "library_unavailable");
        }
        assert_ne!(Reason::PhoneOutdated.category(), codes::NOT_AUTHORIZED);
    }
}
