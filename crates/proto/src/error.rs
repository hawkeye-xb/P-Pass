//! P-Pass protocol — error types.

use serde::{Deserialize, Serialize};

/// Error payload for unsuccessful responses.
///
/// `code` is a machine-readable snake_case identifier (e.g. `NOT_AUTHORIZED`).
/// `msg_key` is a localisation key for the client to render human-readable text.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RespError {
    pub code: String,
    pub msg_key: String,
}

impl RespError {
    pub fn new(code: impl Into<String>, msg_key: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            msg_key: msg_key.into(),
        }
    }
}

/// Well-known error codes.
pub mod codes {
    pub const NOT_AUTHORIZED: &str = "NOT_AUTHORIZED";
    pub const INVALID_REQUEST: &str = "INVALID_REQUEST";
    pub const NOT_FOUND: &str = "NOT_FOUND";
    pub const STORAGE_FULL: &str = "STORAGE_FULL";
    pub const VERSION_MISMATCH: &str = "VERSION_MISMATCH";
    pub const INTERNAL: &str = "INTERNAL";
}
