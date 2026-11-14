//! 视频首帧解码（Media Foundation，仅 Windows）——平台能力。
//!
//! 这里只提供平台能力：`video_decode_available` 判断本平台有没有原生视频解码，
//! `decode_video_frame` 从 H.264 MP4 字节解出首帧 RGBA。平台分叉只在这里（B.2/G5
//! 的家）。请求/应答线协议、`max_edge` 缩放与 `ppf-video-decoder` 子进程入口在
//! `media-codec`（它同时依赖 `decode-worker` 的 proto 与本 crate，天然承载视频 bin）。

/// 视频首帧解码错误。
#[derive(Debug, thiserror::Error)]
pub enum VideoDecodeError {
    /// 本平台没有视频解码能力（非 Windows）。
    #[error("video decode unsupported on this platform")]
    Unsupported,
    /// 内容解不开（损坏 / 容器或编码不支持）。
    #[error("decode failed: {0}")]
    Failed(String),
    /// 超出尺寸等上限，被主动拒绝。
    #[error("rejected: {0}")]
    Rejected(String),
}

#[cfg(windows)]
fn failed(e: impl ToString) -> VideoDecodeError {
    VideoDecodeError::Failed(e.to_string())
}

/// 本平台有没有原生视频解码能力（仅 Windows 的 Media Foundation）。
pub fn video_decode_available() -> bool {
    cfg!(windows)
}

/// 从 H.264 MP4 字节解第一帧，返回 (宽, 高, RGBA8)。
/// 非 Windows 平台返回 [`VideoDecodeError::Unsupported`]。
pub fn decode_video_frame(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), VideoDecodeError> {
    #[cfg(windows)]
    {
        decode_video_frame_windows(bytes)
    }
    #[cfg(not(windows))]
    {
        let _ = bytes;
        Err(VideoDecodeError::Unsupported)
    }
}

/// Windows 实现：Media Foundation 从内存字节解 H.264 MP4 首帧。
///
/// 为什么用 NV12 而不是直接要 RGB32：本机 MF 对 `SetCurrentMediaType(RGB32)`
/// 返回 `0xC00D36B4 MF_E_INVALIDMEDIATYPE`（见 #1730 探针 results.md），所以
/// 请求解码器原生输出的 NV12，再在这里转 RGBA。
#[cfg(windows)]
fn decode_video_frame_windows(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), VideoDecodeError> {
    use std::time::Duration;

    use windows::Win32::Media::MediaFoundation::{
        IMFMediaBuffer, IMFMediaType, IMFSourceReader, MFCreateMFByteStreamOnStream,
        MFCreateMediaType, MFCreateSourceReaderFromByteStream, MFMediaType_Video, MFStartup,
        MFVideoFormat_NV12, MFVideoInterlace_Progressive, MFSTARTUP_NOSOCKET, MF_MT_DEFAULT_STRIDE,
        MF_MT_FRAME_SIZE, MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE, MF_MT_SUBTYPE,
        MF_MT_VIDEO_ROTATION, MF_SOURCE_READERF_ENDOFSTREAM, MF_SOURCE_READER_FIRST_VIDEO_STREAM,
        MF_VERSION,
    };
    use windows::Win32::System::Com::StructuredStorage::CreateStreamOnHGlobal;
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};
    use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};

    const FIRST_VIDEO: u32 = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;

    // COM（MTA）+ MF 初始化。进程用完即弃，不做对称的 CoUninitialize / MFShutdown。
    let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    unsafe { MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET) }
        .map_err(|e| failed(format!("MFStartup: {}", e.message())))?;

    // 内存字节 → HGLOBAL → IStream → IMFByteStream（不落盘、不按路径读文件）。
    let hglobal = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes.len()) }
        .map_err(|e| failed(format!("GlobalAlloc: {}", e.message())))?;
    if !bytes.is_empty() {
        let ptr = unsafe { GlobalLock(hglobal) };
        // SAFETY: `bytes` 有效，`ptr` 是可写的 `bytes.len()` 字节。
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr.cast::<u8>(), bytes.len()) };
        let _ = unsafe { GlobalUnlock(hglobal) };
    }
    let stream = unsafe { CreateStreamOnHGlobal(hglobal, true) }
        .map_err(|e| failed(format!("CreateStreamOnHGlobal: {}", e.message())))?;
    let byte_stream: windows::Win32::Media::MediaFoundation::IMFByteStream =
        unsafe { MFCreateMFByteStreamOnStream(&stream) }
            .map_err(|e| failed(format!("MFCreateMFByteStreamOnStream: {}", e.message())))?;
    let reader: IMFSourceReader = unsafe { MFCreateSourceReaderFromByteStream(&byte_stream, None) }
        .map_err(|e| {
            failed(format!(
                "MFCreateSourceReaderFromByteStream: {}",
                e.message()
            ))
        })?;

    // 原生类型是压缩态（H.264）；帧尺寸打包高位=宽、低位=高。
    let native: IMFMediaType = unsafe { reader.GetNativeMediaType(FIRST_VIDEO, 0) }
        .map_err(|e| failed(format!("GetNativeMediaType: {}", e.message())))?;
    let fs_coded = unsafe { native.GetUINT64(&MF_MT_FRAME_SIZE) }.unwrap_or(0);

    // 请求解码输出 NV12（H.264 解码器原生格式；RGB32 被本机 MF 拒）。
    let mt: IMFMediaType = unsafe { MFCreateMediaType() }
        .map_err(|e| failed(format!("MFCreateMediaType: {}", e.message())))?;
    unsafe {
        mt.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
            .map_err(|e| failed(format!("SetGUID(MAJOR): {}", e.message())))?;
        mt.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)
            .map_err(|e| failed(format!("SetGUID(SUBTYPE=NV12): {}", e.message())))?;
        mt.SetUINT64(&MF_MT_FRAME_SIZE, fs_coded)
            .map_err(|e| failed(format!("SetUINT64(FRAME_SIZE): {}", e.message())))?;
        mt.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)
            .map_err(|e| failed(format!("SetUINT32(INTERLACE): {}", e.message())))?;
        reader
            .SetCurrentMediaType(FIRST_VIDEO, None, &mt)
            .map_err(|e| failed(format!("SetCurrentMediaType(NV12): {}", e.message())))?;
    }

    // 有界读取：源读取器可能先回「暂无样本」事件，跳过后重试，最多 N 次；超过仍
    // 无帧才失败（daemon 侧还有整体 watchdog 兜底，不会死循环）。
    const MAX_READ_ATTEMPTS: usize = 16;
    let mut sample: Option<windows::Win32::Media::MediaFoundation::IMFSample> = None;
    for _ in 0..MAX_READ_ATTEMPTS {
        let mut actual = 0u32;
        let mut flags = 0u32;
        let mut ts = 0i64;
        let mut s: Option<windows::Win32::Media::MediaFoundation::IMFSample> = None;
        unsafe {
            reader
                .ReadSample(
                    FIRST_VIDEO,
                    0,
                    Some(&mut actual),
                    Some(&mut flags),
                    Some(&mut ts),
                    Some(&mut s),
                )
                .map_err(|e| failed(format!("ReadSample: {}", e.message())))?;
        }
        if flags & (MF_SOURCE_READERF_ENDOFSTREAM.0 as u32) != 0 {
            return Err(failed("end of stream before first frame"));
        }
        if s.is_some() {
            sample = s;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let sample =
        sample.ok_or_else(|| failed(format!("no sample after {MAX_READ_ATTEMPTS} attempts")))?;

    // 首帧实际格式：ReadSample 之后 MF 可能改输出格式（尺寸/stride/旋转），所以这里
    // **在拿到样本后**再读一次当前媒体类型，后续 need 校验、NV12 布局与旋转都用这一份
    // 新鲜值，不沿用 SetCurrentMediaType 之前那次协商的旧值。
    let cur: IMFMediaType = unsafe { reader.GetCurrentMediaType(FIRST_VIDEO) }.map_err(|e| {
        failed(format!(
            "GetCurrentMediaType(after sample): {}",
            e.message()
        ))
    })?;
    let fs = unsafe { cur.GetUINT64(&MF_MT_FRAME_SIZE) }.unwrap_or(0);
    let stride_raw = unsafe { cur.GetUINT32(&MF_MT_DEFAULT_STRIDE) }.unwrap_or(0);
    // 手机拍的 MP4 常把旋转存在容器元数据里（MF_MT_VIDEO_ROTATION，0/90/180/270）。
    let rotation = unsafe { cur.GetUINT32(&MF_MT_VIDEO_ROTATION) }.unwrap_or(0);
    let (w, h, stride, rotation) = frame_geometry(fs, stride_raw, rotation)
        .ok_or_else(|| VideoDecodeError::Rejected(format!("bad frame size {fs:#018x}")))?;

    let buffer: IMFMediaBuffer = unsafe { sample.GetBufferByIndex(0) }
        .map_err(|e| failed(format!("GetBufferByIndex: {}", e.message())))?;
    let mut pb: *mut u8 = std::ptr::null_mut();
    let mut _maxlen = 0u32;
    let mut curlen = 0u32;
    unsafe {
        buffer
            .Lock(&mut pb, Some(&mut _maxlen), Some(&mut curlen))
            .map_err(|e| failed(format!("Lock: {}", e.message())))?;
    }
    // NV12 布局：Y 平面在前（stride × h），UV 交错平面在后（同 stride，半高）。
    let need = stride * h + stride * (h / 2);
    if (curlen as usize) < need {
        let _ = unsafe { buffer.Unlock() };
        return Err(VideoDecodeError::Rejected(format!(
            "NV12 buffer too short: got {curlen}, need {need}"
        )));
    }
    // SAFETY: 上面已按 `need` 校验 `curlen`，读到的范围都在缓冲内。
    let y = unsafe { std::slice::from_raw_parts(pb, stride * h) };
    let uv = unsafe { std::slice::from_raw_parts(pb.add(stride * h), stride * (h / 2)) };
    let rgba = nv12_to_rgba(y, uv, stride, w, h);
    let _ = unsafe { buffer.Unlock() };
    drop(buffer);
    drop(sample);
    let (w, h, rgba) = rotate_rgba(w, h, rgba, rotation);
    Ok((w as u32, h as u32, rgba))
}

/// 从媒体类型的原始值解析解码帧几何：返回 (宽, 高, stride, 旋转)。
/// `MF_MT_FRAME_SIZE` 高位=宽、低位=高；stride 不足宽时按宽兜底；尺寸非法返回 None。
#[cfg(windows)]
fn frame_geometry(fs: u64, stride_raw: u32, rotation: u32) -> Option<(usize, usize, usize, u32)> {
    let w = (fs >> 32) as u32;
    let h = (fs & 0xffff_ffff) as u32;
    if w == 0 || h == 0 || w > 16_384 || h > 16_384 {
        return None;
    }
    let stride = (stride_raw as usize).max(w as usize);
    Some((w as usize, h as usize, stride, rotation))
}

/// 按容器旋转元数据（0/90/180/270，顺时针）旋转 RGBA。90/270 会交换宽高。
#[cfg(windows)]
fn rotate_rgba(w: usize, h: usize, rgba: Vec<u8>, rotation: u32) -> (usize, usize, Vec<u8>) {
    match rotation {
        90 => {
            let (nw, nh) = (h, w);
            let mut out = vec![0u8; nw * nh * 4];
            for i in 0..nh {
                for j in 0..nw {
                    let src = ((h - 1 - j) * w + i) * 4;
                    let dst = (i * nw + j) * 4;
                    out[dst..dst + 4].copy_from_slice(&rgba[src..src + 4]);
                }
            }
            (nw, nh, out)
        }
        180 => {
            let mut out = vec![0u8; w * h * 4];
            for i in 0..h {
                for j in 0..w {
                    let src = ((h - 1 - i) * w + (w - 1 - j)) * 4;
                    let dst = (i * w + j) * 4;
                    out[dst..dst + 4].copy_from_slice(&rgba[src..src + 4]);
                }
            }
            (w, h, out)
        }
        270 => {
            let (nw, nh) = (h, w);
            let mut out = vec![0u8; nw * nh * 4];
            for i in 0..nh {
                for j in 0..nw {
                    let src = (j * w + (w - 1 - i)) * 4;
                    let dst = (i * nw + j) * 4;
                    out[dst..dst + 4].copy_from_slice(&rgba[src..src + 4]);
                }
            }
            (nw, nh, out)
        }
        _ => (w, h, rgba),
    }
}

/// NV12 → RGBA（BT.601 有限范围，固定点整数近似）。缩略图用途，精度足够。
#[cfg(windows)]
fn nv12_to_rgba(y: &[u8], uv: &[u8], stride: usize, w: usize, h: usize) -> Vec<u8> {
    let mut out = vec![0u8; w * h * 4];
    for r in 0..h {
        for c in 0..w {
            let yv = y[r * stride + c] as i32;
            let cb = uv[(r / 2) * stride + (c / 2) * 2] as i32;
            let cr = uv[(r / 2) * stride + (c / 2) * 2 + 1] as i32;
            let rv = (1192 * (yv - 16) + 1634 * (cr - 128)) >> 10;
            let gv = (1192 * (yv - 16) - 833 * (cr - 128) - 400 * (cb - 128)) >> 10;
            let bv = (1192 * (yv - 16) + 2066 * (cb - 128)) >> 10;
            let d = (r * w + c) * 4;
            out[d] = rv.clamp(0, 255) as u8;
            out[d + 1] = gv.clamp(0, 255) as u8;
            out[d + 2] = bv.clamp(0, 255) as u8;
            out[d + 3] = 255;
        }
    }
    out
}

#[cfg(all(test, windows))]
mod tests {
    use super::{frame_geometry, rotate_rgba};

    /// 首帧实际几何：从媒体类型原始值解析尺寸/stride/旋转，非法尺寸拒。
    #[test]
    fn frame_geometry_parses_size_stride_rotation() {
        // MF_MT_FRAME_SIZE 高位=宽、低位=高（64×48 → 0x0040_0030）。
        let fs = (64u64 << 32) | 48;
        let (w, h, stride, rot) = frame_geometry(fs, 64, 90).unwrap();
        assert_eq!((w, h, stride, rot), (64, 48, 64, 90));

        // stride 不足宽 → 按宽兜底。
        let (w, h, stride, rot) = frame_geometry(fs, 0, 0).unwrap();
        assert_eq!((w, h, stride, rot), (64, 48, 64, 0));

        // 尺寸为 0 或超上限 → None。
        assert!(frame_geometry(0, 0, 0).is_none());
        assert!(frame_geometry((16_385u64 << 32) | 1, 0, 0).is_none());
        assert!(frame_geometry(64u64 << 32, 0, 0).is_none()); // h=0
    }

    /// 像素 = [R,G,B,A]，用两个明显不同的像素验证旋转方向。
    #[test]
    fn rotate_rgba_maps_pixels_and_swaps_dims() {
        let a = [255, 0, 0, 255]; // 红
        let b = [0, 0, 255, 255]; // 蓝
        let in_2x1 = [a, b].concat(); // 2×1：左红右蓝

        // 0：原样。
        let (w, h, out) = rotate_rgba(2, 1, in_2x1.clone(), 0);
        assert_eq!((w, h), (2, 1));
        assert_eq!(out, in_2x1);

        // 90° 顺时针：1×2，红在上、蓝在下。
        let (w, h, out) = rotate_rgba(2, 1, in_2x1.clone(), 90);
        assert_eq!((w, h), (1, 2));
        assert_eq!(&out[0..4], &a);
        assert_eq!(&out[4..8], &b);

        // 180°：2×1 左右对调。
        let (w, h, out) = rotate_rgba(2, 1, in_2x1.clone(), 180);
        assert_eq!((w, h), (2, 1));
        assert_eq!(&out[0..4], &b);
        assert_eq!(&out[4..8], &a);

        // 270°（= 逆时针 90°）：1×2，蓝在上、红在下。
        let (w, h, out) = rotate_rgba(2, 1, in_2x1.clone(), 270);
        assert_eq!((w, h), (1, 2));
        assert_eq!(&out[0..4], &b);
        assert_eq!(&out[4..8], &a);
    }

    /// 90° 连续四次应回到原图（方向一致性）。
    #[test]
    fn rotate_rgba_four_times_is_identity() {
        let a = [10, 20, 30, 255];
        let b = [40, 50, 60, 255];
        let c = [70, 80, 90, 255];
        let d = [100, 110, 120, 255];
        let img = [a, b, c, d].concat(); // 2×2
        let (mut w, mut h, mut out) = rotate_rgba(2, 2, img.clone(), 90);
        for _ in 0..3 {
            let r = rotate_rgba(w, h, out, 90);
            w = r.0;
            h = r.1;
            out = r.2;
        }
        assert_eq!((w, h), (2, 2));
        assert_eq!(out, img);
    }
}
