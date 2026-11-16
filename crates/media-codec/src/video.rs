//! 视频首帧解码子进程（`ppf-video-decoder`）的平台无关部分：读请求、解首帧、写应答。
//!
//! 线协议复用 `decode_worker::proto`（`KIND_VIDEO`），解码经
//! [`platform::video_decode::decode_video_frame`]（Media Foundation，仅 Windows）。
//! 本模块不写任何 `#[cfg]`——平台分叉只待在 `crates/platform`（B.2）。

use std::io::{Read, Write};

use decode_worker::proto::{self, Response, STATUS_DECODE_FAILED, STATUS_REJECTED};
use platform::video_decode::{decode_video_frame, VideoDecodeError};

/// `ppf-video-decoder` 的主流程：读一个视频请求，写一个应答。
/// 与 `decode_worker::run` 的差别只在「解码」这一步换成 Media Foundation。
pub fn run_video(input: &mut impl Read, output: &mut impl Write) -> Result<(), proto::ProtoError> {
    let req = proto::read_request_header(input)?;
    let mut payload = Vec::new();
    let got = input.take(req.payload_len).read_to_end(&mut payload)?;
    if got as u64 != req.payload_len {
        return Err(proto::ProtoError::Bad(
            "payload shorter than declared".into(),
        ));
    }
    let resp = match decode_video_frame(&payload) {
        Ok((w, h, rgba)) => {
            drop(payload);
            let mut img = image::RgbaImage::from_raw(w, h, rgba)
                .ok_or_else(|| proto::ProtoError::Bad("pixel buffer rejected".into()))?;
            if img.width() > req.max_edge || img.height() > req.max_edge {
                let scaled = image::DynamicImage::ImageRgba8(img)
                    .thumbnail(req.max_edge, req.max_edge)
                    .to_rgba8();
                img = scaled;
            }
            Response::Pixels {
                width: img.width(),
                height: img.height(),
                rgba: img.into_raw(),
            }
        }
        Err(VideoDecodeError::Unsupported) => Response::Failed {
            status: STATUS_DECODE_FAILED,
            msg: "video decode unsupported on this platform".into(),
        },
        Err(VideoDecodeError::Failed(msg)) => Response::Failed {
            status: STATUS_DECODE_FAILED,
            msg,
        },
        Err(VideoDecodeError::Rejected(msg)) => Response::Failed {
            status: STATUS_REJECTED,
            msg,
        },
    };
    proto::write_response(output, &resp)
}

/// `ppf-video-decoder` 的入口：stdin/stdout 即协议管道。
pub fn main_stdio() -> i32 {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    match run_video(&mut stdin.lock(), &mut stdout.lock()) {
        Ok(()) => 0,
        Err(_) => 2,
    }
}
