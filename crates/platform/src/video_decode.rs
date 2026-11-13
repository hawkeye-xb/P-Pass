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
    use windows::Win32::Media::MediaFoundation::{
        IMFMediaBuffer, IMFMediaType, IMFSourceReader, MFCreateMFByteStreamOnStream,
        MFCreateMediaType, MFCreateSourceReaderFromByteStream, MFMediaType_Video, MFStartup,
        MFVideoFormat_NV12, MFVideoInterlace_Progressive, MFSTARTUP_NOSOCKET, MF_MT_DEFAULT_STRIDE,
        MF_MT_FRAME_SIZE, MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE, MF_MT_SUBTYPE,
        MF_SOURCE_READERF_ENDOFSTREAM, MF_SOURCE_READER_FIRST_VIDEO_STREAM, MF_VERSION,
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

    // 协商后的解码帧尺寸 / 步长。
    let cur: IMFMediaType = unsafe { reader.GetCurrentMediaType(FIRST_VIDEO) }
        .map_err(|e| failed(format!("GetCurrentMediaType: {}", e.message())))?;
    let fs = unsafe { cur.GetUINT64(&MF_MT_FRAME_SIZE) }.unwrap_or(0);
    let w = (fs >> 32) as u32;
    let h = (fs & 0xffff_ffff) as u32;
    if w == 0 || h == 0 || w > 16_384 || h > 16_384 {
        return Err(VideoDecodeError::Rejected(format!(
            "bad frame size {w}x{h}"
        )));
    }
    let stride = unsafe { cur.GetUINT32(&MF_MT_DEFAULT_STRIDE) }.unwrap_or(w) as usize;
    let stride = stride.max(w as usize);

    let mut actual = 0u32;
    let mut flags = 0u32;
    let mut ts = 0i64;
    let mut sample: Option<windows::Win32::Media::MediaFoundation::IMFSample> = None;
    unsafe {
        reader
            .ReadSample(
                FIRST_VIDEO,
                0,
                Some(&mut actual),
                Some(&mut flags),
                Some(&mut ts),
                Some(&mut sample),
            )
            .map_err(|e| failed(format!("ReadSample: {}", e.message())))?;
    }
    let sample = sample.ok_or_else(|| failed("no sample from source reader"))?;
    if flags & (MF_SOURCE_READERF_ENDOFSTREAM.0 as u32) != 0 {
        return Err(failed("end of stream before first frame"));
    }

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
    let (w, h) = (w as usize, h as usize);
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
    Ok((w as u32, h as u32, rgba))
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
