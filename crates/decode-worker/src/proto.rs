//! daemon ↔ 解码子进程的线格式（v1），两个平台共用。
//!
//! 请求（daemon → 子进程 stdin，一次性）：
//! `"PPDQ" | ver u8 | kind u8 | max_edge u32 | ext_len u8 | ext | payload_len u64 | payload`
//!
//! 应答（子进程 stdout → daemon，一次性）：
//! `"PPDR" | ver u8 | status u8` 之后
//! - `STATUS_OK`：`w u32 | h u32 | len u64 | RGBA8`，`len == w*h*4`，`max(w,h) <= max_edge`
//! - 其他：`msg_len u16 | utf8`
//!
//! 整数一律小端。读方对每个字段都做上限校验，不信对端。

use std::io::{self, Read, Write};

pub const REQ_MAGIC: &[u8; 4] = b"PPDQ";
pub const RESP_MAGIC: &[u8; 4] = b"PPDR";
pub const VERSION: u8 = 1;

/// 静态图片。
pub const KIND_STILL: u8 = 1;

pub const STATUS_OK: u8 = 0;
/// 内容解不开（损坏 / 格式不支持）。
pub const STATUS_DECODE_FAILED: u8 = 1;
/// 超出尺寸等上限，被主动拒绝。
pub const STATUS_REJECTED: u8 = 2;

/// 输入上限：超过的文件不送子进程（占位图）。
pub const MAX_PAYLOAD: u64 = 256 * 1024 * 1024;
pub const MAX_EXT_LEN: usize = 16;
pub const MAX_MSG_LEN: usize = 512;
/// 回传边长上界（与大档缩略图对齐）。
pub const MAX_EDGE_LIMIT: u32 = 4096;

#[derive(Debug, thiserror::Error)]
pub enum ProtoError {
    #[error("io: {0}")]
    Io(#[from] io::Error),
    #[error("protocol: {0}")]
    Bad(String),
}

fn bad<T>(msg: impl Into<String>) -> Result<T, ProtoError> {
    Err(ProtoError::Bad(msg.into()))
}

#[derive(Debug, PartialEq, Eq)]
pub struct Request {
    pub max_edge: u32,
    pub ext: String,
    pub payload_len: u64,
}

/// 只写请求头；调用方随后把 `payload_len` 个字节流式写到同一个 writer。
pub fn write_request_header(
    w: &mut impl Write,
    max_edge: u32,
    ext: &str,
    payload_len: u64,
) -> Result<(), ProtoError> {
    if ext.len() > MAX_EXT_LEN {
        return bad("extension too long");
    }
    if payload_len > MAX_PAYLOAD {
        return bad("payload too large");
    }
    w.write_all(REQ_MAGIC)?;
    w.write_all(&[VERSION, KIND_STILL])?;
    w.write_all(&max_edge.to_le_bytes())?;
    w.write_all(&[ext.len() as u8])?;
    w.write_all(ext.as_bytes())?;
    w.write_all(&payload_len.to_le_bytes())?;
    Ok(())
}

fn read_arr<const N: usize>(r: &mut impl Read) -> Result<[u8; N], ProtoError> {
    let mut b = [0u8; N];
    r.read_exact(&mut b)?;
    Ok(b)
}

/// 读请求头（不读 payload）。
pub fn read_request_header(r: &mut impl Read) -> Result<Request, ProtoError> {
    if &read_arr::<4>(r)? != REQ_MAGIC {
        return bad("bad request magic");
    }
    let [ver, kind] = read_arr::<2>(r)?;
    if ver != VERSION || kind != KIND_STILL {
        return bad(format!("unsupported request v{ver} kind {kind}"));
    }
    let max_edge = u32::from_le_bytes(read_arr(r)?);
    if max_edge == 0 || max_edge > MAX_EDGE_LIMIT {
        return bad("max_edge out of range");
    }
    let [ext_len] = read_arr::<1>(r)?;
    if ext_len as usize > MAX_EXT_LEN {
        return bad("extension too long");
    }
    let mut ext = vec![0u8; ext_len as usize];
    r.read_exact(&mut ext)?;
    let ext = String::from_utf8(ext).map_err(|_| ProtoError::Bad("extension not utf8".into()))?;
    let payload_len = u64::from_le_bytes(read_arr(r)?);
    if payload_len > MAX_PAYLOAD {
        return bad("payload too large");
    }
    Ok(Request {
        max_edge,
        ext,
        payload_len,
    })
}

#[derive(Debug, PartialEq, Eq)]
pub enum Response {
    Pixels {
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    },
    Failed {
        status: u8,
        msg: String,
    },
}

pub fn write_response(w: &mut impl Write, resp: &Response) -> Result<(), ProtoError> {
    w.write_all(RESP_MAGIC)?;
    match resp {
        Response::Pixels {
            width,
            height,
            rgba,
        } => {
            w.write_all(&[VERSION, STATUS_OK])?;
            w.write_all(&width.to_le_bytes())?;
            w.write_all(&height.to_le_bytes())?;
            w.write_all(&(rgba.len() as u64).to_le_bytes())?;
            w.write_all(rgba)?;
        }
        Response::Failed { status, msg } => {
            let mut end = msg.len().min(MAX_MSG_LEN);
            while !msg.is_char_boundary(end) {
                end -= 1;
            }
            w.write_all(&[VERSION, *status])?;
            w.write_all(&(end as u16).to_le_bytes())?;
            w.write_all(&msg.as_bytes()[..end])?;
        }
    }
    w.flush()?;
    Ok(())
}

/// 读并校验应答。`max_edge` 是请求里给的上界；任何不符都是 `Err`，
/// 且读完后流上不许再有多余字节。
pub fn read_response(r: &mut impl Read, max_edge: u32) -> Result<Response, ProtoError> {
    if &read_arr::<4>(r)? != RESP_MAGIC {
        return bad("bad response magic");
    }
    let [ver, status] = read_arr::<2>(r)?;
    if ver != VERSION {
        return bad(format!("unsupported response v{ver}"));
    }
    let resp = if status == STATUS_OK {
        let width = u32::from_le_bytes(read_arr(r)?);
        let height = u32::from_le_bytes(read_arr(r)?);
        let len = u64::from_le_bytes(read_arr(r)?);
        if width == 0 || height == 0 || width > max_edge || height > max_edge {
            return bad(format!("pixel size {width}x{height} out of range"));
        }
        if len != u64::from(width) * u64::from(height) * 4 {
            return bad("pixel length does not match size");
        }
        let mut rgba = vec![0u8; len as usize];
        r.read_exact(&mut rgba)?;
        Response::Pixels {
            width,
            height,
            rgba,
        }
    } else if status == STATUS_DECODE_FAILED || status == STATUS_REJECTED {
        let n = u16::from_le_bytes(read_arr(r)?) as usize;
        if n > MAX_MSG_LEN {
            return bad("message too long");
        }
        let mut b = vec![0u8; n];
        r.read_exact(&mut b)?;
        // 去掉控制字符：这段文字会进日志。
        let msg: String = String::from_utf8_lossy(&b)
            .chars()
            .filter(|c| !c.is_control())
            .collect();
        Response::Failed { status, msg }
    } else {
        return bad(format!("unknown status {status}"));
    };
    let mut extra = [0u8; 1];
    if r.read(&mut extra)? != 0 {
        return bad("trailing bytes after response");
    }
    Ok(resp)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_header_roundtrip() {
        let mut b = Vec::new();
        write_request_header(&mut b, 1024, "heic", 77).unwrap();
        let req = read_request_header(&mut &b[..]).unwrap();
        assert_eq!(
            req,
            Request {
                max_edge: 1024,
                ext: "heic".into(),
                payload_len: 77
            }
        );
    }

    #[test]
    fn request_limits_are_enforced() {
        let mut b = Vec::new();
        write_request_header(&mut b, 1024, "jpg", 1).unwrap();
        // payload_len 改成超限
        let n = b.len();
        b[n - 8..].copy_from_slice(&(MAX_PAYLOAD + 1).to_le_bytes());
        assert!(read_request_header(&mut &b[..]).is_err());
        let mut b = Vec::new();
        write_request_header(&mut b, 0, "jpg", 1).unwrap();
        assert!(read_request_header(&mut &b[..]).is_err(), "max_edge 0");
        assert!(write_request_header(&mut Vec::new(), 8, &"x".repeat(17), 1).is_err());
        assert!(read_request_header(&mut &b"XXXX"[..]).is_err());
    }

    #[test]
    fn pixels_roundtrip_and_validation() {
        let ok = Response::Pixels {
            width: 2,
            height: 1,
            rgba: vec![1, 2, 3, 4, 5, 6, 7, 8],
        };
        let mut b = Vec::new();
        write_response(&mut b, &ok).unwrap();
        assert_eq!(read_response(&mut &b[..], 16).unwrap(), ok);
        // 超过请求的边长上界
        assert!(read_response(&mut &b[..], 1).is_err());
        // 长度与尺寸不符
        let mut bad_len = b.clone();
        bad_len[14..22].copy_from_slice(&7u64.to_le_bytes());
        assert!(read_response(&mut &bad_len[..], 16).is_err());
        // 多余字节
        let mut extra = b.clone();
        extra.push(0);
        assert!(read_response(&mut &extra[..], 16).is_err());
        // 截断
        assert!(read_response(&mut &b[..b.len() - 1], 16).is_err());
    }

    #[test]
    fn failure_message_is_capped_and_sanitized() {
        let long = Response::Failed {
            status: STATUS_DECODE_FAILED,
            msg: format!("é{}", "x".repeat(2000)),
        };
        let mut b = Vec::new();
        write_response(&mut b, &long).unwrap();
        let Response::Failed { msg, .. } = read_response(&mut &b[..], 16).unwrap() else {
            panic!()
        };
        assert!(msg.len() <= MAX_MSG_LEN);
        let mut b = Vec::new();
        write_response(
            &mut b,
            &Response::Failed {
                status: STATUS_REJECTED,
                msg: "a\u{1b}[31mb\n".into(),
            },
        )
        .unwrap();
        let Response::Failed { msg, .. } = read_response(&mut &b[..], 16).unwrap() else {
            panic!()
        };
        assert_eq!(msg, "a[31mb");
        assert!(read_response(&mut &[b'P', b'P', b'D', b'R', 1, 9][..], 16).is_err());
    }
}
