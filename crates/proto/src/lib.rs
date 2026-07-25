//! P-Pass wire protocol: message types, codec, and version.
//!
//! # Usage
//!
//! ```rust
//! use proto::{Req, Resp, Hello, codec};
//!
//! let req = Req {
//!     id: "uuid-1".into(),
//!     method: "hello".into(),
//!     params: serde_json::json!({"proto_ver": 1}),
//!     min_ver: 1,
//! };
//! let frame = codec::encode(&req).unwrap();
//! let back: Req = codec::decode(&frame).unwrap();
//! assert_eq!(req, back);
//! ```

pub mod codec;
pub mod error;
pub mod msgs;
pub mod version;

pub use error::{codes, RespError};
pub use msgs::*;
pub use version::PROTO_VER;
