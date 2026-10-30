//! 静态图解码：daemon 侧的客户端。图片字节经管道送进独立的解码子进程
//! （`ppf-decoder`），只取回像素；本进程不解析任何图片容器格式。
//!
//! 每张图一个新子进程，用完即弃。线协议见 `decode_worker::proto`，
//! 隔离拉起见 `platform::isolated`。
//!
//! 失败分两类，调用方处理不同：
//! - [`CodecError::SandboxUnavailable`]：找不到 / 拉不起解码子进程 —— 本机系统性问题。
//! - [`CodecError::Decode`]：这个文件的问题（解不开、超限、超时、子进程崩溃、回包不合法）。
//!
//! **任何一类都不回退成进程内解码。**

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

use decode_worker::proto::{self, Response, MAX_PAYLOAD};
use image::{DynamicImage, RgbaImage};

use crate::{CodecError, Result};

/// 回传像素的最长边：与最大一档缩略图对齐，更大的原图由子进程先缩小。
pub const DECODE_MAX_EDGE: u32 = 1024;

/// 单张图的整体时限：到点强杀子进程。
const DEADLINE: Duration = Duration::from_secs(30);

/// 子进程内存上限：120 MP 的 RGBA（480 MB）加解码中间缓冲放得下。
const WORKER_MEMORY: u64 = 2 * 1024 * 1024 * 1024;

/// 解码一张静态图，返回方向已摆正、最长边不超过 [`DECODE_MAX_EDGE`] 的像素。
pub fn decode_image(path: &Path) -> Result<DynamicImage> {
    decode_with(path, DEADLINE)
}

/// 同 [`decode_image`]，时限可调（生命周期测试用）。
#[doc(hidden)]
pub fn decode_image_within(path: &Path, deadline: Duration) -> Result<DynamicImage> {
    decode_with(path, deadline)
}

fn decode_with(path: &Path, deadline: Duration) -> Result<DynamicImage> {
    let decode_err = |msg: String| CodecError::Decode {
        path: path.to_path_buf(),
        msg,
    };
    let mut file = File::open(path).map_err(|source| CodecError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let len = file
        .metadata()
        .map_err(|source| CodecError::Io {
            path: path.to_path_buf(),
            source,
        })?
        .len();
    if len > MAX_PAYLOAD {
        return Err(decode_err(format!(
            "{len} bytes exceeds the {MAX_PAYLOAD}-byte decode input limit"
        )));
    }
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .filter(|e| e.len() <= proto::MAX_EXT_LEN)
        .unwrap_or_default();

    let worker = platform::isolated::decoder_worker_path()
        .ok_or_else(|| CodecError::SandboxUnavailable("ppf-decoder not found".into()))?;
    let mut child = platform::isolated::spawn_isolated(
        &worker,
        &platform::isolated::Limits {
            memory_bytes: WORKER_MEMORY,
        },
    )
    .map_err(|e| CodecError::SandboxUnavailable(format!("spawn {}: {e}", worker.display())))?;
    let (Some(mut stdin), Some(mut stdout)) = (child.stdin.take(), child.stdout.take()) else {
        return Err(CodecError::SandboxUnavailable(
            "worker pipes missing".into(),
        ));
    };

    // 看门狗：到点强杀，被杀的子进程管道关闭，下面阻塞中的读写随之返回。
    let killer = child.killer();
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let (timed_out_tx, timed_out_rx) = mpsc::channel::<()>();
    let watchdog = std::thread::spawn(move || {
        if let Err(mpsc::RecvTimeoutError::Timeout) = stop_rx.recv_timeout(deadline) {
            let _ = timed_out_tx.send(());
            killer.kill();
        }
    });

    // 写请求：写失败（子进程已死）不在这里报，读应答时自然得到「没有应答」。
    let sent = (|| -> io::Result<()> {
        proto::write_request_header(&mut stdin, DECODE_MAX_EDGE, &ext, len)
            .map_err(|e| io::Error::other(e.to_string()))?;
        io::copy(&mut (&mut file).take(len), &mut stdin)?;
        Ok(())
    })();
    drop(stdin);
    let resp = proto::read_response(&mut stdout, DECODE_MAX_EDGE);
    let _ = child.wait();
    let _ = stop_tx.send(());
    let _ = watchdog.join();

    if timed_out_rx.try_recv().is_ok() {
        return Err(decode_err(format!("decode timed out after {deadline:?}")));
    }
    match resp {
        Ok(Response::Pixels {
            width,
            height,
            rgba,
        }) => RgbaImage::from_raw(width, height, rgba)
            .map(DynamicImage::ImageRgba8)
            .ok_or_else(|| decode_err("pixel buffer rejected".into())),
        Ok(Response::Failed { msg, .. }) => Err(decode_err(msg)),
        Err(e) => Err(decode_err(match sent {
            Err(se) => format!("decoder exited early ({se}); {e}"),
            Ok(()) => format!("decoder gave no valid answer: {e}"),
        })),
    }
}
