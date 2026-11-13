//! 解码子进程（`ppf-decoder`）的全部逻辑与 daemon 共用的线协议。

pub mod decode;
pub mod proto;

use std::io::{self, Read, Write};

use proto::{Response, STATUS_DECODE_FAILED, STATUS_REJECTED};

/// 子进程主流程：读一个请求，写一个应答。进程随后退出。
/// 返回 `Err` 表示协议层出错（调用方以非零状态退出）。
pub fn run(input: &mut impl Read, output: &mut impl Write) -> Result<(), proto::ProtoError> {
    let req = proto::read_request_header(input)?;
    let mut payload = Vec::new();
    let got = input.take(req.payload_len).read_to_end(&mut payload)?;
    if got as u64 != req.payload_len {
        return Err(proto::ProtoError::Bad(
            "payload shorter than declared".into(),
        ));
    }
    let resp = match decode::decode_bytes(&payload, &req.ext) {
        Ok(mut img) => {
            drop(payload);
            if img.width() > req.max_edge || img.height() > req.max_edge {
                img = img.thumbnail(req.max_edge, req.max_edge);
            }
            let rgba = img.to_rgba8();
            Response::Pixels {
                width: rgba.width(),
                height: rgba.height(),
                rgba: rgba.into_raw(),
            }
        }
        Err(decode::DecodeError::Failed(msg)) => Response::Failed {
            status: STATUS_DECODE_FAILED,
            msg,
        },
        Err(decode::DecodeError::Rejected(msg)) => Response::Failed {
            status: STATUS_REJECTED,
            msg,
        },
    };
    proto::write_response(output, &resp)
}

/// `ppf-decoder` 的入口：stdin/stdout 即协议管道。
pub fn main_stdio() -> i32 {
    let stdin = io::stdin();
    let stdout = io::stdout();
    match run(&mut stdin.lock(), &mut stdout.lock()) {
        Ok(()) => 0,
        Err(_) => 2,
    }
}
