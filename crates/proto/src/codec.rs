//! P-Pass protocol — length-prefixed JSON codec.
//!
//! Wire format: u32 LE byte count followed by UTF-8 JSON payload.
//!
//! ```text
//! ┌──────────────┬──────────────────────────────────┐
//! │ len (4B LE)  │  JSON payload (len bytes)        │
//! └──────────────┴──────────────────────────────────┘
//! ```

use serde::de::DeserializeOwned;
use serde::Serialize;

/// Maximum payload size to protect against memory exhaustion (16 MiB).
const MAX_PAYLOAD: u32 = 16 * 1024 * 1024;

/// Error variants for encoding/decoding failures.
#[derive(Debug, thiserror::Error)]
pub enum CodecError {
    #[error("payload too large: {0} bytes (max {MAX_PAYLOAD})")]
    PayloadTooLarge(u32),

    #[error("incomplete frame: expected {expected} bytes, got {got}")]
    IncompleteFrame { expected: usize, got: usize },

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

/// Encode a value as a length-prefixed JSON frame.
///
/// Returns a byte buffer starting with a 4-byte little-endian length.
pub fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, CodecError> {
    let payload = serde_json::to_vec(value)?;
    let len = payload.len() as u32;

    if len > MAX_PAYLOAD {
        return Err(CodecError::PayloadTooLarge(len));
    }

    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&len.to_le_bytes());
    frame.extend_from_slice(&payload);
    Ok(frame)
}

/// Decode a value from a length-prefixed JSON frame.
///
/// This takes the full buffer (including the 4-byte header). If the buffer
/// is shorter than the declared payload, returns [`CodecError::IncompleteFrame`].
pub fn decode<T: DeserializeOwned>(frame: &[u8]) -> Result<T, CodecError> {
    if frame.len() < 4 {
        return Err(CodecError::IncompleteFrame {
            expected: 4,
            got: frame.len(),
        });
    }

    let payload_len = u32::from_le_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;

    if payload_len > MAX_PAYLOAD as usize {
        return Err(CodecError::PayloadTooLarge(payload_len as u32));
    }

    if frame.len() < 4 + payload_len {
        return Err(CodecError::IncompleteFrame {
            expected: 4 + payload_len,
            got: frame.len(),
        });
    }

    let payload = &frame[4..4 + payload_len];
    let value = serde_json::from_slice(payload)?;
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::msgs::Hello;

    #[test]
    fn encode_decode_roundtrip() {
        let hello = Hello {
            proto_ver: 1,
            capabilities: vec!["thumbnail.v1".into()],
            device_name: "test-device".into(),
        };

        let frame = encode(&hello).unwrap();
        let back: Hello = decode(&frame).unwrap();

        assert_eq!(hello, back);
    }

    #[test]
    fn length_prefix_is_le() {
        let frame = encode(&"hello").unwrap();
        let declared_len = u32::from_le_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
        assert_eq!(declared_len, frame.len() - 4);
    }

    #[test]
    fn decode_empty_frame() {
        let err = decode::<Hello>(&[]).unwrap_err();
        match err {
            CodecError::IncompleteFrame { expected, got } => {
                assert_eq!(expected, 4);
                assert_eq!(got, 0);
            }
            _ => panic!("expected IncompleteFrame, got {:?}", err),
        }
    }

    #[test]
    fn decode_truncated() {
        // Declare 100 bytes but only give 5+4
        let mut buf = vec![0u8; 4];
        buf[0] = 100;
        buf.extend(b"short");

        let err = decode::<Hello>(&buf).unwrap_err();
        match err {
            CodecError::IncompleteFrame { .. } => {}
            _ => panic!("expected IncompleteFrame, got {:?}", err),
        }
    }

    #[test]
    fn decode_bad_json() {
        let payload = b"not json";
        let len = payload.len() as u32;
        let mut buf = Vec::new();
        buf.extend_from_slice(&len.to_le_bytes());
        buf.extend_from_slice(payload);

        let err = decode::<Hello>(&buf).unwrap_err();
        match err {
            CodecError::Json(_) => {}
            _ => panic!("expected Json error, got {:?}", err),
        }
    }
}
