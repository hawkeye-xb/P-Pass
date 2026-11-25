//! 视频首帧解码子进程（`ppf-video-decoder`）的平台无关部分：读请求、解首帧、写应答。
//!
//! 线协议复用 `decode_worker::proto`（`KIND_VIDEO`），优先经
//! [`platform::video_decode::decode_video_frame`]（Windows Media Foundation，H.264 硬/软解）；
//! 若平台返回 `Unsupported` 或 `Failed`（如裸 Windows / Session 0 服务沙盒无 HEVC 解码器），
//! 回退尝试内置 `libde265` ISOBMFF 首帧软解（`decode_worker::hevc_mp4::decode_hevc_first_frame`）。
//! 本模块不写任何 `#[cfg]`——平台分叉只待在 `crates/platform`（B.2）。

use std::io::{Read, Write};

use decode_worker::decode::DecodeError;
use decode_worker::hevc_mp4::decode_hevc_first_frame;
use decode_worker::proto::{self, Response, STATUS_DECODE_FAILED, STATUS_REJECTED};
use platform::video_decode::{decode_video_frame, VideoDecodeError};

fn scale_to_response(
    w: u32,
    h: u32,
    rgba: Vec<u8>,
    max_edge: u32,
) -> Result<Response, proto::ProtoError> {
    let mut img = image::RgbaImage::from_raw(w, h, rgba)
        .ok_or_else(|| proto::ProtoError::Bad("pixel buffer rejected".into()))?;
    if img.width() > max_edge || img.height() > max_edge {
        img = image::DynamicImage::ImageRgba8(img)
            .thumbnail(max_edge, max_edge)
            .to_rgba8();
    }
    Ok(Response::Pixels {
        width: img.width(),
        height: img.height(),
        rgba: img.into_raw(),
    })
}

/// `ppf-video-decoder` 的主流程：读一个视频请求，写一个应答。
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
            scale_to_response(w, h, rgba, req.max_edge)?
        }
        Err(VideoDecodeError::Rejected(msg)) => Response::Failed {
            status: STATUS_REJECTED,
            msg,
        },
        Err(primary @ (VideoDecodeError::Unsupported | VideoDecodeError::Failed(_))) => {
            match decode_hevc_first_frame(&payload) {
                Ok((w, h, rgba)) => {
                    drop(payload);
                    scale_to_response(w, h, rgba, req.max_edge)?
                }
                Err(DecodeError::Rejected(msg)) => Response::Failed {
                    status: STATUS_REJECTED,
                    msg,
                },
                Err(DecodeError::Failed(hevc_msg)) => {
                    let msg = match primary {
                        VideoDecodeError::Unsupported => hevc_msg,
                        VideoDecodeError::Failed(mf_msg) => {
                            format!("{mf_msg}; builtin HEVC fallback: {hevc_msg}")
                        }
                        VideoDecodeError::Rejected(_) => unreachable!(),
                    };
                    Response::Failed {
                        status: STATUS_DECODE_FAILED,
                        msg,
                    }
                }
            }
        }
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
