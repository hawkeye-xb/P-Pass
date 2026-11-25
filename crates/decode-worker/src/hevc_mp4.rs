//! 纯内存安全 ISOBMFF（`.mov` / `.mp4`）HEVC（`hvc1` / `hev1`）首帧提取与 `libde265` 软解码。
//!
//! 背景（#2047）：Windows 的 HEVC Media Foundation 解码器属于用户态 Microsoft Store AppX
//! 插件，在 `LocalSystem` 服务（Session 0）+ 零权限 `AppContainer` 沙箱中不可见，且裸 Windows
//! 默认未安装付费扩展。复用随 `libheif` 一并构建并通过供应链校验的 `libde265`，在隔离解码
//! 子进程内直接从内存字节解出首帧 RGBA8。

use std::ffi::{c_char, c_int, c_void, CStr};
use std::ptr;

use crate::decode::{DecodeError, MAX_IMAGE_PIXELS};

/// 视频单边硬上限（与 `platform::video_decode` 对齐：16384）。
const MAX_VIDEO_EDGE: u32 = 16_384;

/// ISOBMFF 盒子树最大递归深度（防止畸形嵌套耗尽栈空间）。
const MAX_BOX_DEPTH: usize = 12;

/// 最多连续送入解码器的开头样本数（兼容首帧前有非同步帧或重排帧的流）。
const MAX_PROBE_SAMPLES: u32 = 8;

/// 单次解码循环上限（防异常流死循环）。
const MAX_DECODE_STEPS: usize = 256;

/// 参数集与单帧 NAL 总数上限（防畸形包构造海量小切片）。
const MAX_NALS_PER_TRACK: usize = 4_096;

// ── libde265 C ABI（单线程调用，兼容 Windows 静态库与 Unix 动态库） ──────────

type De265Context = c_void;
type De265Image = c_void;
type De265Error = c_int;
type De265Chroma = c_int;
type De265Pts = i64;

const DE265_OK: De265Error = 0;
const DE265_ERROR_WAITING_FOR_INPUT_DATA: De265Error = 13;

const DE265_CHROMA_MONO: De265Chroma = 0;
const DE265_CHROMA_420: De265Chroma = 1;
const DE265_CHROMA_422: De265Chroma = 2;
const DE265_CHROMA_444: De265Chroma = 3;

extern "C" {
    fn de265_new_decoder() -> *mut De265Context;
    fn de265_free_decoder(ctx: *mut De265Context) -> De265Error;
    fn de265_push_NAL(
        ctx: *mut De265Context,
        data: *const c_void,
        length: c_int,
        pts: De265Pts,
        user_data: *mut c_void,
    ) -> De265Error;
    fn de265_flush_data(ctx: *mut De265Context) -> De265Error;
    fn de265_decode(ctx: *mut De265Context, more: *mut c_int) -> De265Error;
    fn de265_get_next_picture(ctx: *mut De265Context) -> *const De265Image;
    fn de265_isOK(err: De265Error) -> c_int;
    fn de265_get_error_text(err: De265Error) -> *const c_char;

    fn de265_get_image_width(img: *const De265Image, channel: c_int) -> c_int;
    fn de265_get_image_height(img: *const De265Image, channel: c_int) -> c_int;
    fn de265_get_chroma_format(img: *const De265Image) -> De265Chroma;
    fn de265_get_bits_per_pixel(img: *const De265Image, channel: c_int) -> c_int;
    fn de265_get_image_plane(
        img: *const De265Image,
        channel: c_int,
        out_stride: *mut c_int,
    ) -> *const u8;
    fn de265_get_image_full_range_flag(img: *const De265Image) -> c_int;
    fn de265_get_image_matrix_coefficients(img: *const De265Image) -> c_int;
}

/// RAII 守护：保证任何提前返回路径都调用 `de265_free_decoder`，零内存泄漏。
struct DecoderGuard(*mut De265Context);

impl DecoderGuard {
    fn new() -> Result<Self, DecodeError> {
        // SAFETY: `de265_new_decoder` 无前置条件，失败返回 NULL。
        let ptr = unsafe { de265_new_decoder() };
        if ptr.is_null() {
            return Err(DecodeError::Failed(
                "de265_new_decoder returned null".into(),
            ));
        }
        Ok(Self(ptr))
    }

    fn as_ptr(&self) -> *mut De265Context {
        self.0
    }
}

impl Drop for DecoderGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: 指针由 `de265_new_decoder` 创建且只在 `Drop` 中释放一次。
            unsafe {
                let _ = de265_free_decoder(self.0);
            }
            self.0 = ptr::null_mut();
        }
    }
}

fn de265_err_msg(err: De265Error) -> String {
    // SAFETY: `de265_get_error_text` 返回静态只读 C 字符串或 NULL。
    let ptr = unsafe { de265_get_error_text(err) };
    if ptr.is_null() {
        return format!("libde265 error {err}");
    }
    // SAFETY: 非空时指向以 NUL 结尾的静态错误描述字符串。
    let text = unsafe { CStr::from_ptr(ptr) }.to_string_lossy();
    format!("libde265 error {err}: {text}")
}

fn de265_ok(err: De265Error) -> bool {
    err == DE265_OK || unsafe { de265_isOK(err) } != 0
}

/// 从内存中的 `.mov` / `.mp4`（ISOBMFF）字节提取首个 HEVC 视频轨首帧并软解为摆正方向的 RGBA8。
pub fn decode_hevc_first_frame(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), DecodeError> {
    let track = extract_hevc_track(bytes)?;
    let (w, h, rgba) = decode_hevc_samples(bytes, &track)?;
    let (rw, rh, rrgba) = rotate_rgba(w as usize, h as usize, rgba, track.rotation);
    Ok((rw as u32, rh as u32, rrgba))
}

// ── ISOBMFF 盒子解析（零 unsafe，全 checked 算术） ───────────────────────────

#[derive(Clone, Copy)]
struct Mp4Box<'a> {
    typ: [u8; 4],
    payload: &'a [u8],
}

struct BoxIter<'a> {
    buf: &'a [u8],
    pos: usize,
    corrupt: bool,
}

impl<'a> BoxIter<'a> {
    fn new(buf: &'a [u8], depth: usize) -> Result<Self, DecodeError> {
        if depth > MAX_BOX_DEPTH {
            return Err(DecodeError::Failed(
                "ISOBMFF box nesting exceeds limit".into(),
            ));
        }
        Ok(Self {
            buf,
            pos: 0,
            corrupt: false,
        })
    }
}

impl<'a> Iterator for BoxIter<'a> {
    type Item = Mp4Box<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.corrupt || self.pos >= self.buf.len() {
            return None;
        }
        let rem = self.buf.get(self.pos..)?;
        if rem.len() < 8 {
            self.corrupt = true;
            return None;
        }
        let size32 = u32::from_be_bytes([rem[0], rem[1], rem[2], rem[3]]);
        let typ = [rem[4], rem[5], rem[6], rem[7]];
        let (hdr_len, box_len): (usize, usize) = match size32 {
            0 => (8, rem.len()),
            1 => {
                if rem.len() < 16 {
                    self.corrupt = true;
                    return None;
                }
                let size64 = u64::from_be_bytes([
                    rem[8], rem[9], rem[10], rem[11], rem[12], rem[13], rem[14], rem[15],
                ]);
                let Ok(len) = usize::try_from(size64) else {
                    self.corrupt = true;
                    return None;
                };
                (16, len)
            }
            n => (8, n as usize),
        };
        if box_len < hdr_len || box_len > rem.len() {
            self.corrupt = true;
            return None;
        }
        let payload = rem.get(hdr_len..box_len)?;
        self.pos = match self.pos.checked_add(box_len) {
            Some(next) => next,
            None => {
                self.corrupt = true;
                return None;
            }
        };
        Some(Mp4Box { typ, payload })
    }
}

fn read_u16_be(b: &[u8], off: usize) -> Option<u16> {
    let s = b.get(off..off.checked_add(2)?)?;
    Some(u16::from_be_bytes([s[0], s[1]]))
}

fn read_u32_be(b: &[u8], off: usize) -> Option<u32> {
    let s = b.get(off..off.checked_add(4)?)?;
    Some(u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
}

fn read_i32_be(b: &[u8], off: usize) -> Option<i32> {
    let s = b.get(off..off.checked_add(4)?)?;
    Some(i32::from_be_bytes([s[0], s[1], s[2], s[3]]))
}

fn read_u64_be(b: &[u8], off: usize) -> Option<u64> {
    let s = b.get(off..off.checked_add(8)?)?;
    Some(u64::from_be_bytes([
        s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7],
    ]))
}

#[derive(Debug)]
struct HevcConfig<'a> {
    nal_length_size: usize,
    param_nals: Vec<&'a [u8]>,
}

#[derive(Debug, Clone, Copy)]
struct StscRun {
    first_chunk: u32,
    samples_per_chunk: u32,
}

#[derive(Debug)]
enum SampleSizes<'a> {
    Constant { size: u32, count: u32 },
    Table { count: u32, raw_entries: &'a [u8] },
}

impl<'a> SampleSizes<'a> {
    fn count(&self) -> u32 {
        match *self {
            Self::Constant { count, .. } | Self::Table { count, .. } => count,
        }
    }

    /// 1-based sample 号对应的字节长度。
    fn size_of(&self, sample_number: u32) -> Option<usize> {
        if sample_number == 0 || sample_number > self.count() {
            return None;
        }
        match *self {
            Self::Constant { size, .. } => Some(size as usize),
            Self::Table { raw_entries, .. } => {
                let idx = (sample_number - 1) as usize;
                let off = idx.checked_mul(4)?;
                Some(read_u32_be(raw_entries, off)? as usize)
            }
        }
    }
}

#[derive(Debug)]
enum ChunkOffsets<'a> {
    Stco { count: u32, raw_entries: &'a [u8] },
    Co64 { count: u32, raw_entries: &'a [u8] },
}

impl<'a> ChunkOffsets<'a> {
    /// 1-based chunk 号对应的文件偏移。
    fn offset_of(&self, chunk_number: u32) -> Option<usize> {
        if chunk_number == 0 {
            return None;
        }
        match *self {
            Self::Stco { count, raw_entries } => {
                if chunk_number > count {
                    return None;
                }
                let off = ((chunk_number - 1) as usize).checked_mul(4)?;
                Some(read_u32_be(raw_entries, off)? as usize)
            }
            Self::Co64 { count, raw_entries } => {
                if chunk_number > count {
                    return None;
                }
                let off = ((chunk_number - 1) as usize).checked_mul(8)?;
                usize::try_from(read_u64_be(raw_entries, off)?).ok()
            }
        }
    }
}

struct HevcTrack<'a> {
    rotation: u32,
    nal_length_size: usize,
    param_nals: Vec<&'a [u8]>,
    sample_ranges: Vec<(usize, usize)>,
}

fn extract_hevc_track<'a>(bytes: &'a [u8]) -> Result<HevcTrack<'a>, DecodeError> {
    let mut moov_payload: Option<&'a [u8]> = None;
    for b in BoxIter::new(bytes, 0)? {
        if &b.typ == b"moov" {
            moov_payload = Some(b.payload);
            break;
        }
    }
    let moov =
        moov_payload.ok_or_else(|| DecodeError::Failed("ISOBMFF missing moov box".into()))?;

    let mut last_err: Option<DecodeError> = None;
    for b in BoxIter::new(moov, 1)? {
        if &b.typ != b"trak" {
            continue;
        }
        match parse_trak(bytes.len(), b.payload, 2) {
            Ok(Some(track)) => return Ok(track),
            Ok(None) => {}
            Err(e @ DecodeError::Rejected(_)) => return Err(e),
            Err(e) => last_err = Some(e),
        }
    }
    Err(last_err
        .unwrap_or_else(|| DecodeError::Failed("no HEVC (hvc1/hev1) video track found".into())))
}

fn parse_trak<'a>(
    file_len: usize,
    trak_payload: &'a [u8],
    depth: usize,
) -> Result<Option<HevcTrack<'a>>, DecodeError> {
    let mut rotation = 0u32;
    let mut mdia_payload: Option<&'a [u8]> = None;

    for b in BoxIter::new(trak_payload, depth)? {
        match &b.typ {
            b"tkhd" => {
                if let Some(rot) = parse_tkhd_rotation(b.payload) {
                    rotation = rot;
                }
            }
            b"mdia" => mdia_payload = Some(b.payload),
            _ => {}
        }
    }
    let Some(mdia) = mdia_payload else {
        return Ok(None);
    };

    let mut is_video = false;
    let mut minf_payload: Option<&'a [u8]> = None;
    for b in BoxIter::new(mdia, depth + 1)? {
        match &b.typ {
            b"hdlr" => {
                // FullBox(4) + pre_defined(4) + handler_type(4)
                if b.payload.get(8..12) == Some(b"vide".as_slice()) {
                    is_video = true;
                }
            }
            b"minf" => minf_payload = Some(b.payload),
            _ => {}
        }
    }
    if !is_video {
        return Ok(None);
    }
    let Some(minf) = minf_payload else {
        return Ok(None);
    };

    let mut stbl_payload: Option<&'a [u8]> = None;
    for b in BoxIter::new(minf, depth + 2)? {
        if &b.typ == b"stbl" {
            stbl_payload = Some(b.payload);
            break;
        }
    }
    let Some(stbl) = stbl_payload else {
        return Ok(None);
    };

    let mut stsd_box: Option<&'a [u8]> = None;
    let mut stss_box: Option<&'a [u8]> = None;
    let mut stsc_box: Option<&'a [u8]> = None;
    let mut stsz_box: Option<&'a [u8]> = None;
    let mut stco_box: Option<&'a [u8]> = None;
    let mut co64_box: Option<&'a [u8]> = None;

    for b in BoxIter::new(stbl, depth + 3)? {
        match &b.typ {
            b"stsd" => stsd_box = Some(b.payload),
            b"stss" => stss_box = Some(b.payload),
            b"stsc" => stsc_box = Some(b.payload),
            b"stsz" => stsz_box = Some(b.payload),
            b"stco" => stco_box = Some(b.payload),
            b"co64" => co64_box = Some(b.payload),
            _ => {}
        }
    }

    let Some(stsd) = stsd_box else {
        return Ok(None);
    };
    let Some(cfg) = parse_stsd_hevc(stsd, depth + 4)? else {
        return Ok(None);
    };

    let stsc =
        parse_stsc(stsc_box.ok_or_else(|| DecodeError::Failed("HEVC track missing stsc".into()))?)?;
    let stsz =
        parse_stsz(stsz_box.ok_or_else(|| DecodeError::Failed("HEVC track missing stsz".into()))?)?;
    let chunks = if let Some(co64) = co64_box {
        parse_co64(co64)?
    } else if let Some(stco) = stco_box {
        parse_stco(stco)?
    } else {
        return Err(DecodeError::Failed("HEVC track missing stco/co64".into()));
    };

    let total_samples = stsz.count();
    if total_samples == 0 {
        return Err(DecodeError::Failed("HEVC track has zero samples".into()));
    }

    let start_sample = stss_box
        .and_then(parse_first_sync_sample)
        .filter(|&s| s >= 1 && s <= total_samples)
        .unwrap_or(1);
    let end_sample = start_sample
        .saturating_add(MAX_PROBE_SAMPLES - 1)
        .min(total_samples);

    let mut sample_ranges = Vec::with_capacity((end_sample - start_sample + 1) as usize);
    for s in start_sample..=end_sample {
        let range = locate_sample(s, &stsc, &stsz, &chunks, file_len)
            .ok_or_else(|| DecodeError::Failed(format!("sample {s} out of bounds")))?;
        sample_ranges.push(range);
    }

    Ok(Some(HevcTrack {
        rotation,
        nal_length_size: cfg.nal_length_size,
        param_nals: cfg.param_nals,
        sample_ranges,
    }))
}

/// 解析 `tkhd` 的 3x3 16.16 定点变换矩阵，换算为顺时针旋转角（0 / 90 / 180 / 270）。
pub(crate) fn parse_tkhd_rotation(payload: &[u8]) -> Option<u32> {
    let version = *payload.first()?;
    // FullBox(4) + creation/modification/track_id/reserved/duration + reserved(8) + layer(2)
    // + alternate_group(2) + volume(2) + reserved(2) = version 0 偏移 40，version 1 偏移 52。
    let matrix_off = match version {
        0 => 40usize,
        1 => 52usize,
        _ => return None,
    };
    let a = read_i32_be(payload, matrix_off)?;
    let b = read_i32_be(payload, matrix_off + 4)?;
    let c = read_i32_be(payload, matrix_off + 12)?;
    let d = read_i32_be(payload, matrix_off + 16)?;

    // 允许轻微定点舍入误差（±0x1000 约 ±0.0625），标准 1.0 为 0x0001_0000。
    let near = |v: i32, target: i32| (i64::from(v) - i64::from(target)).abs() <= 0x1000;
    const ONE: i32 = 0x0001_0000;

    if near(a, 0) && near(b, ONE) && near(c, -ONE) && near(d, 0) {
        Some(90)
    } else if near(a, -ONE) && near(b, 0) && near(c, 0) && near(d, -ONE) {
        Some(180)
    } else if near(a, 0) && near(b, -ONE) && near(c, ONE) && near(d, 0) {
        Some(270)
    } else {
        Some(0)
    }
}

/// 解析 `stsd`：寻找首个 `hvc1` 或 `hev1` VisualSampleEntry 并读取其 `hvcC` 子 box。
fn parse_stsd_hevc<'a>(
    stsd_payload: &'a [u8],
    depth: usize,
) -> Result<Option<HevcConfig<'a>>, DecodeError> {
    // FullBox(4) + entry_count(4)
    let Some(entry_count) = read_u32_be(stsd_payload, 4) else {
        return Err(DecodeError::Failed("truncated stsd box".into()));
    };
    let entries_buf = stsd_payload
        .get(8..)
        .ok_or_else(|| DecodeError::Failed("truncated stsd entries".into()))?;

    // VisualSampleEntry 固定前缀（不含外层 8/16 字节 box 头）共 78 字节：
    // reserved(6) + data_ref_index(2) + pre_defined/reserved(16) + width(2) + height(2)
    // + horizresolution(4) + vertresolution(4) + reserved(4) + frame_count(2)
    // + compressorname(32) + depth(2) + pre_defined(2) = 78。
    const VISUAL_SAMPLE_ENTRY_HEADER: usize = 78;

    for entry in BoxIter::new(entries_buf, depth)?.take(entry_count as usize) {
        if &entry.typ != b"hvc1" && &entry.typ != b"hev1" {
            continue;
        }
        let width = read_u16_be(entry.payload, 24).unwrap_or(0) as u32;
        let height = read_u16_be(entry.payload, 26).unwrap_or(0) as u32;
        if width > MAX_VIDEO_EDGE || height > MAX_VIDEO_EDGE {
            return Err(DecodeError::Rejected(format!(
                "video header dimensions {width}x{height} exceed {MAX_VIDEO_EDGE}"
            )));
        }
        if u64::from(width) * u64::from(height) > MAX_IMAGE_PIXELS {
            return Err(DecodeError::Rejected(format!(
                "video header pixels {width}x{h} exceed {MAX_IMAGE_PIXELS}",
                h = height
            )));
        }
        let children = entry
            .payload
            .get(VISUAL_SAMPLE_ENTRY_HEADER..)
            .ok_or_else(|| DecodeError::Failed("VisualSampleEntry shorter than 78 bytes".into()))?;
        for sub in BoxIter::new(children, depth + 1)? {
            if &sub.typ == b"hvcC" {
                return parse_hvcc(sub.payload).map(Some);
            }
        }
        return Err(DecodeError::Failed(
            "hvc1/hev1 sample entry missing hvcC box".into(),
        ));
    }
    Ok(None)
}

/// 解析 `HEVCDecoderConfigurationRecord`（ISO/IEC 14496-15 §8.3.3.1.2）。
fn parse_hvcc(hvcc: &[u8]) -> Result<HevcConfig<'_>, DecodeError> {
    if hvcc.len() < 23 {
        return Err(DecodeError::Failed("hvcC shorter than 23 bytes".into()));
    }
    let nal_length_size = ((hvcc[21] & 0x03) as usize) + 1;
    if !matches!(nal_length_size, 1 | 2 | 4) {
        return Err(DecodeError::Failed(format!(
            "unsupported hvcC lengthSizeMinusOne -> {nal_length_size}"
        )));
    }
    let num_arrays = hvcc[22] as usize;
    let mut pos = 23usize;
    let mut param_nals = Vec::new();

    for _ in 0..num_arrays {
        // array_completeness/NAL_unit_type (1) + numNalus (2)
        let num_nalus = read_u16_be(
            hvcc,
            pos.checked_add(1)
                .ok_or_else(|| DecodeError::Failed("hvcC offset overflow".into()))?,
        )
        .ok_or_else(|| DecodeError::Failed("truncated hvcC array header".into()))?
            as usize;
        pos = pos
            .checked_add(3)
            .ok_or_else(|| DecodeError::Failed("hvcC offset overflow".into()))?;

        for _ in 0..num_nalus {
            if param_nals.len() >= MAX_NALS_PER_TRACK {
                return Err(DecodeError::Failed(
                    "too many parameter NALs in hvcC".into(),
                ));
            }
            let nal_len = read_u16_be(hvcc, pos)
                .ok_or_else(|| DecodeError::Failed("truncated hvcC nalUnitLength".into()))?
                as usize;
            pos = pos
                .checked_add(2)
                .ok_or_else(|| DecodeError::Failed("hvcC offset overflow".into()))?;
            let end = pos
                .checked_add(nal_len)
                .ok_or_else(|| DecodeError::Failed("hvcC NAL length overflow".into()))?;
            let nal = hvcc
                .get(pos..end)
                .ok_or_else(|| DecodeError::Failed("truncated hvcC NAL payload".into()))?;
            if !nal.is_empty() {
                param_nals.push(nal);
            }
            pos = end;
        }
    }

    Ok(HevcConfig {
        nal_length_size,
        param_nals,
    })
}

fn parse_first_sync_sample(stss: &[u8]) -> Option<u32> {
    let count = read_u32_be(stss, 4)? as usize;
    let entries = stss.get(8..)?;
    for i in 0..count {
        let off = i.checked_mul(4)?;
        let s = read_u32_be(entries, off)?;
        if s > 0 {
            return Some(s);
        }
    }
    None
}

fn parse_stsc(stsc: &[u8]) -> Result<Vec<StscRun>, DecodeError> {
    let count = read_u32_be(stsc, 4)
        .ok_or_else(|| DecodeError::Failed("truncated stsc header".into()))?
        as usize;
    let need = count
        .checked_mul(12)
        .and_then(|n| n.checked_add(8))
        .ok_or_else(|| DecodeError::Failed("stsc table overflow".into()))?;
    let entries = stsc
        .get(8..need)
        .ok_or_else(|| DecodeError::Failed("truncated stsc entries".into()))?;
    if count == 0 {
        return Err(DecodeError::Failed("empty stsc table".into()));
    }
    let mut runs = Vec::with_capacity(count);
    for i in 0..count {
        let off = i * 12;
        let first_chunk = read_u32_be(entries, off)
            .ok_or_else(|| DecodeError::Failed("truncated stsc run".into()))?;
        let samples_per_chunk = read_u32_be(entries, off + 4)
            .ok_or_else(|| DecodeError::Failed("truncated stsc run".into()))?;
        if first_chunk == 0 {
            return Err(DecodeError::Failed("stsc first_chunk is 0".into()));
        }
        runs.push(StscRun {
            first_chunk,
            samples_per_chunk,
        });
    }
    Ok(runs)
}

fn parse_stsz(stsz: &[u8]) -> Result<SampleSizes<'_>, DecodeError> {
    // FullBox(4) + sample_size(4) + sample_count(4)
    let sample_size =
        read_u32_be(stsz, 4).ok_or_else(|| DecodeError::Failed("truncated stsz".into()))?;
    let sample_count =
        read_u32_be(stsz, 8).ok_or_else(|| DecodeError::Failed("truncated stsz".into()))?;
    if sample_size != 0 {
        return Ok(SampleSizes::Constant {
            size: sample_size,
            count: sample_count,
        });
    }
    let need = (sample_count as usize)
        .checked_mul(4)
        .and_then(|n| n.checked_add(12))
        .ok_or_else(|| DecodeError::Failed("stsz table size overflow".into()))?;
    let raw_entries = stsz
        .get(12..need)
        .ok_or_else(|| DecodeError::Failed("truncated stsz table".into()))?;
    Ok(SampleSizes::Table {
        count: sample_count,
        raw_entries,
    })
}

fn parse_stco(stco: &[u8]) -> Result<ChunkOffsets<'_>, DecodeError> {
    let count = read_u32_be(stco, 4).ok_or_else(|| DecodeError::Failed("truncated stco".into()))?;
    let need = (count as usize)
        .checked_mul(4)
        .and_then(|n| n.checked_add(8))
        .ok_or_else(|| DecodeError::Failed("stco table size overflow".into()))?;
    let raw_entries = stco
        .get(8..need)
        .ok_or_else(|| DecodeError::Failed("truncated stco table".into()))?;
    Ok(ChunkOffsets::Stco { count, raw_entries })
}

fn parse_co64(co64: &[u8]) -> Result<ChunkOffsets<'_>, DecodeError> {
    let count = read_u32_be(co64, 4).ok_or_else(|| DecodeError::Failed("truncated co64".into()))?;
    let need = (count as usize)
        .checked_mul(8)
        .and_then(|n| n.checked_add(8))
        .ok_or_else(|| DecodeError::Failed("co64 table size overflow".into()))?;
    let raw_entries = co64
        .get(8..need)
        .ok_or_else(|| DecodeError::Failed("truncated co64 table".into()))?;
    Ok(ChunkOffsets::Co64 { count, raw_entries })
}

/// 计算 1-based `target_sample` 在文件字节缓冲中的 `(offset, size)`。
fn locate_sample(
    target_sample: u32,
    stsc: &[StscRun],
    stsz: &SampleSizes<'_>,
    chunks: &ChunkOffsets<'_>,
    file_len: usize,
) -> Option<(usize, usize)> {
    let target_size = stsz.size_of(target_sample)?;
    let mut cur_sample = 1u32;

    for (i, run) in stsc.iter().enumerate() {
        if run.samples_per_chunk == 0 {
            continue;
        }
        let next_first_chunk = stsc.get(i + 1).map(|r| r.first_chunk);
        if let Some(nfc) = next_first_chunk {
            if nfc <= run.first_chunk {
                continue;
            }
            let chunk_span = u64::from(nfc - run.first_chunk);
            let samples_in_run = chunk_span.checked_mul(u64::from(run.samples_per_chunk))?;
            let run_end_sample = u64::from(cur_sample).checked_add(samples_in_run)?;
            if u64::from(target_sample) >= run_end_sample {
                cur_sample = u32::try_from(run_end_sample).ok()?;
                continue;
            }
        }

        let rel = target_sample.checked_sub(cur_sample)?;
        let chunk_delta = rel / run.samples_per_chunk;
        let idx_in_chunk = rel % run.samples_per_chunk;
        let chunk_number = run.first_chunk.checked_add(chunk_delta)?;
        let chunk_first_sample =
            cur_sample.checked_add(chunk_delta.checked_mul(run.samples_per_chunk)?)?;

        let mut offset = chunks.offset_of(chunk_number)?;
        for k in 0..idx_in_chunk {
            let s_num = chunk_first_sample.checked_add(k)?;
            offset = offset.checked_add(stsz.size_of(s_num)?)?;
        }
        let end = offset.checked_add(target_size)?;
        if end > file_len {
            return None;
        }
        return Some((offset, target_size));
    }
    None
}

/// 将单个长度前缀（AVCC/HVCC 风格）的 sample 拆分为裸 NAL 切片。
fn split_length_prefixed_nals(
    sample: &[u8],
    nal_length_size: usize,
) -> Result<Vec<&[u8]>, DecodeError> {
    let mut pos = 0usize;
    let mut nals = Vec::new();
    while pos < sample.len() {
        if nals.len() >= MAX_NALS_PER_TRACK {
            return Err(DecodeError::Failed("too many NAL units in sample".into()));
        }
        let len_bytes = sample
            .get(
                pos..pos
                    .checked_add(nal_length_size)
                    .ok_or_else(|| DecodeError::Failed("NAL length offset overflow".into()))?,
            )
            .ok_or_else(|| DecodeError::Failed("truncated NAL length prefix".into()))?;
        let nal_len = match nal_length_size {
            1 => len_bytes[0] as usize,
            2 => u16::from_be_bytes([len_bytes[0], len_bytes[1]]) as usize,
            4 => u32::from_be_bytes([len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3]])
                as usize,
            _ => return Err(DecodeError::Failed("invalid NAL length size".into())),
        };
        pos += nal_length_size;
        let end = pos
            .checked_add(nal_len)
            .ok_or_else(|| DecodeError::Failed("NAL unit length overflow".into()))?;
        let nal = sample
            .get(pos..end)
            .ok_or_else(|| DecodeError::Failed("NAL unit exceeds sample boundary".into()))?;
        if !nal.is_empty() {
            nals.push(nal);
        }
        pos = end;
    }
    Ok(nals)
}

// ── libde265 解码与平面色彩转换 ─────────────────────────────────────────────

fn push_nal(ctx: *mut De265Context, nal: &[u8], pts: De265Pts) -> Result<(), DecodeError> {
    if nal.is_empty() {
        return Ok(());
    }
    let len = c_int::try_from(nal.len())
        .map_err(|_| DecodeError::Rejected("NAL unit exceeds c_int::MAX".into()))?;
    // SAFETY: `ctx` 有效，`nal.as_ptr()` 对 `len` 字节有效可读，调用期间同步拷入内部缓冲。
    let err = unsafe {
        de265_push_NAL(
            ctx,
            nal.as_ptr().cast::<c_void>(),
            len,
            pts,
            ptr::null_mut(),
        )
    };
    if !de265_ok(err) {
        return Err(DecodeError::Failed(de265_err_msg(err)));
    }
    Ok(())
}

fn drain_until_first_picture(
    ctx: *mut De265Context,
) -> Result<Option<*const De265Image>, DecodeError> {
    for _ in 0..MAX_DECODE_STEPS {
        // SAFETY: `ctx` 有效；若已有解码完的帧则立即取出（必须在下一次 `de265_*` 调用前消费）。
        let pic = unsafe { de265_get_next_picture(ctx) };
        if !pic.is_null() {
            return Ok(Some(pic));
        }
        let mut more: c_int = 0;
        // SAFETY: `ctx` 与 `&mut more` 均有效。
        let err = unsafe { de265_decode(ctx, &mut more) };
        let pic_after = unsafe { de265_get_next_picture(ctx) };
        if !pic_after.is_null() {
            return Ok(Some(pic_after));
        }
        if err == DE265_ERROR_WAITING_FOR_INPUT_DATA || more == 0 {
            break;
        }
        if !de265_ok(err) {
            return Err(DecodeError::Failed(de265_err_msg(err)));
        }
    }
    Ok(None)
}

fn decode_hevc_samples(
    file_bytes: &[u8],
    track: &HevcTrack<'_>,
) -> Result<(u32, u32, Vec<u8>), DecodeError> {
    let dec = DecoderGuard::new()?;
    let ctx = dec.as_ptr();

    for nal in &track.param_nals {
        push_nal(ctx, nal, 0)?;
    }

    let mut pushed_any_sample = false;
    for (idx, &(off, size)) in track.sample_ranges.iter().enumerate() {
        let sample = file_bytes
            .get(off..off + size)
            .ok_or_else(|| DecodeError::Failed("sample slice out of bounds".into()))?;
        let nals = split_length_prefixed_nals(sample, track.nal_length_size)?;
        if nals.is_empty() {
            continue;
        }
        for nal in nals {
            push_nal(ctx, nal, idx as De265Pts)?;
            pushed_any_sample = true;
        }
        if let Some(pic) = drain_until_first_picture(ctx)? {
            return convert_de265_image_to_rgba(pic);
        }
    }

    if !pushed_any_sample {
        return Err(DecodeError::Failed(
            "HEVC sample contained no NAL units".into(),
        ));
    }

    // SAFETY: 标记流结束，把 DPB 里排队的重排首帧刷出来。
    let flush_err = unsafe { de265_flush_data(ctx) };
    if !de265_ok(flush_err) {
        return Err(DecodeError::Failed(de265_err_msg(flush_err)));
    }
    if let Some(pic) = drain_until_first_picture(ctx)? {
        return convert_de265_image_to_rgba(pic);
    }

    Err(DecodeError::Failed(
        "libde265 produced no picture from initial HEVC samples".into(),
    ))
}

struct PlaneSlice<'a> {
    data: &'a [u8],
    stride: usize,
    width: usize,
    height: usize,
    bpp: u32,
}

impl<'a> PlaneSlice<'a> {
    #[inline]
    fn sample_u8(&self, x: usize, y: usize) -> u8 {
        let cx = x.min(self.width.saturating_sub(1));
        let cy = y.min(self.height.saturating_sub(1));
        let row_start = cy * self.stride;
        if self.bpp <= 8 {
            self.data[row_start + cx]
        } else {
            let off = row_start + cx * 2;
            let v = u16::from_le_bytes([self.data[off], self.data[off + 1]]);
            let shift = (self.bpp - 8).min(8);
            let max_val = (1u32 << self.bpp) - 1;
            let clamped = u32::from(v).min(max_val);
            (clamped >> shift) as u8
        }
    }
}

fn read_plane<'a>(img: *const De265Image, channel: c_int) -> Result<PlaneSlice<'a>, DecodeError> {
    // SAFETY: `img` 在下一次 `de265_*` mutating 调用前只读有效。
    let w_raw = unsafe { de265_get_image_width(img, channel) };
    let h_raw = unsafe { de265_get_image_height(img, channel) };
    let bpp_raw = unsafe { de265_get_bits_per_pixel(img, channel) };
    if w_raw <= 0 || h_raw <= 0 {
        return Err(DecodeError::Failed(format!(
            "invalid plane[{channel}] dimensions {w_raw}x{h_raw}"
        )));
    }
    if !(8..=16).contains(&bpp_raw) {
        return Err(DecodeError::Failed(format!(
            "unsupported plane[{channel}] bits_per_pixel {bpp_raw}"
        )));
    }
    let width = w_raw as usize;
    let height = h_raw as usize;
    let bpp = bpp_raw as u32;
    let bytes_per_sample = if bpp <= 8 { 1usize } else { 2usize };
    let min_row_bytes = width
        .checked_mul(bytes_per_sample)
        .ok_or_else(|| DecodeError::Rejected("plane row byte size overflow".into()))?;

    let mut stride_raw: c_int = 0;
    let ptr = unsafe { de265_get_image_plane(img, channel, &mut stride_raw) };
    if ptr.is_null() || stride_raw <= 0 {
        return Err(DecodeError::Failed(format!(
            "null or invalid stride ({stride_raw}) for plane[{channel}]"
        )));
    }
    let stride = stride_raw as usize;
    if stride < min_row_bytes {
        return Err(DecodeError::Failed(format!(
            "plane[{channel}] stride {stride} smaller than row bytes {min_row_bytes}"
        )));
    }
    // 最后一行只需要 `min_row_bytes` 可读，避免尾行无 stride padding 时越界。
    let total_bytes = height
        .saturating_sub(1)
        .checked_mul(stride)
        .and_then(|n| n.checked_add(min_row_bytes))
        .ok_or_else(|| DecodeError::Rejected("plane buffer size overflow".into()))?;
    // SAFETY: `ptr` 指向 libde265 分配的解码平面，至少包含 `(height - 1) * stride + min_row_bytes` 字节。
    let data = unsafe { std::slice::from_raw_parts(ptr, total_bytes) };

    Ok(PlaneSlice {
        data,
        stride,
        width,
        height,
        bpp,
    })
}

fn convert_de265_image_to_rgba(img: *const De265Image) -> Result<(u32, u32, Vec<u8>), DecodeError> {
    let y_plane = read_plane(img, 0)?;
    let w = y_plane.width as u32;
    let h = y_plane.height as u32;
    if w == 0 || h == 0 || w > MAX_VIDEO_EDGE || h > MAX_VIDEO_EDGE {
        return Err(DecodeError::Rejected(format!(
            "decoded frame {w}x{h} exceeds {MAX_VIDEO_EDGE} edge limit"
        )));
    }
    let pixels = u64::from(w) * u64::from(h);
    if pixels > MAX_IMAGE_PIXELS {
        return Err(DecodeError::Rejected(format!(
            "decoded frame {w}x{h} = {pixels} pixels exceeds {MAX_IMAGE_PIXELS}"
        )));
    }

    // SAFETY: 只读查询当前解码图像属性。
    let chroma = unsafe { de265_get_chroma_format(img) };
    let full_range = unsafe { de265_get_image_full_range_flag(img) } != 0;
    let matrix_coeff = unsafe { de265_get_image_matrix_coefficients(img) };

    let rgba_len = (y_plane.width)
        .checked_mul(y_plane.height)
        .and_then(|n| n.checked_mul(4))
        .ok_or_else(|| DecodeError::Rejected("RGBA buffer size overflow".into()))?;
    let mut out = vec![0u8; rgba_len];

    if chroma == DE265_CHROMA_MONO {
        for r in 0..y_plane.height {
            for c in 0..y_plane.width {
                let yv = y_plane.sample_u8(c, r);
                let luma = if full_range {
                    yv
                } else {
                    (((i32::from(yv) - 16) * 1192) >> 10).clamp(0, 255) as u8
                };
                let d = (r * y_plane.width + c) * 4;
                out[d] = luma;
                out[d + 1] = luma;
                out[d + 2] = luma;
                out[d + 3] = 255;
            }
        }
        return Ok((w, h, out));
    }

    let (sub_x, sub_y) = match chroma {
        DE265_CHROMA_420 => (1usize, 1usize),
        DE265_CHROMA_422 => (1usize, 0usize),
        DE265_CHROMA_444 => (0usize, 0usize),
        other => {
            return Err(DecodeError::Failed(format!(
                "unsupported libde265 chroma format {other}"
            )));
        }
    };

    let cb_plane = read_plane(img, 1)?;
    let cr_plane = read_plane(img, 2)?;
    // ITU-T H.273 matrix_coefficients：1 = BT.709，9/10 = BT.2020；未指定（2）时高清默认 BT.709。
    let use_bt709 = match matrix_coeff {
        1 | 9 | 10 => true,
        5 | 6 => false, // BT.601
        _ => w >= 1280 || h >= 720,
    };

    for r in 0..y_plane.height {
        let cr_y = r >> sub_y;
        for c in 0..y_plane.width {
            let cr_x = c >> sub_x;
            let yv = i32::from(y_plane.sample_u8(c, r));
            let cb = i32::from(cb_plane.sample_u8(cr_x, cr_y)) - 128;
            let cr = i32::from(cr_plane.sample_u8(cr_x, cr_y)) - 128;

            let (rv, gv, bv) = yuv_to_rgb(yv, cb, cr, full_range, use_bt709);
            let d = (r * y_plane.width + c) * 4;
            out[d] = rv;
            out[d + 1] = gv;
            out[d + 2] = bv;
            out[d + 3] = 255;
        }
    }

    Ok((w, h, out))
}

#[inline]
fn yuv_to_rgb(y: i32, cb: i32, cr: i32, full_range: bool, bt709: bool) -> (u8, u8, u8) {
    let (r, g, b) = if full_range {
        let y10 = y << 10;
        if bt709 {
            (
                (y10 + 1613 * cr + 512) >> 10,
                (y10 - 192 * cb - 479 * cr + 512) >> 10,
                (y10 + 1900 * cb + 512) >> 10,
            )
        } else {
            (
                (y10 + 1436 * cr + 512) >> 10,
                (y10 - 352 * cb - 731 * cr + 512) >> 10,
                (y10 + 1815 * cb + 512) >> 10,
            )
        }
    } else {
        let y_lim = 1192 * (y - 16);
        if bt709 {
            (
                (y_lim + 1836 * cr + 512) >> 10,
                (y_lim - 218 * cb - 546 * cr + 512) >> 10,
                (y_lim + 2163 * cb + 512) >> 10,
            )
        } else {
            (
                (y_lim + 1634 * cr + 512) >> 10,
                (y_lim - 400 * cb - 833 * cr + 512) >> 10,
                (y_lim + 2066 * cb + 512) >> 10,
            )
        }
    };
    (
        r.clamp(0, 255) as u8,
        g.clamp(0, 255) as u8,
        b.clamp(0, 255) as u8,
    )
}

/// 按 `tkhd` 提取的顺时针旋转角（0 / 90 / 180 / 270）摆正 RGBA8。
pub(crate) fn rotate_rgba(
    w: usize,
    h: usize,
    rgba: Vec<u8>,
    rotation: u32,
) -> (usize, usize, Vec<u8>) {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn make_tkhd_v0(a: i32, b: i32, c: i32, d: i32) -> Vec<u8> {
        let mut p = vec![0u8; 84];
        p[0] = 0; // version 0 -> matrix at offset 40
        p[40..44].copy_from_slice(&a.to_be_bytes());
        p[44..48].copy_from_slice(&b.to_be_bytes());
        p[52..56].copy_from_slice(&c.to_be_bytes());
        p[56..60].copy_from_slice(&d.to_be_bytes());
        p
    }

    #[test]
    fn tkhd_matrix_rotation_angles_and_v1_offset() {
        const ONE: i32 = 0x0001_0000;
        assert_eq!(parse_tkhd_rotation(&make_tkhd_v0(ONE, 0, 0, ONE)), Some(0));
        assert_eq!(
            parse_tkhd_rotation(&make_tkhd_v0(0, ONE, -ONE, 0)),
            Some(90)
        );
        assert_eq!(
            parse_tkhd_rotation(&make_tkhd_v0(-ONE, 0, 0, -ONE)),
            Some(180)
        );
        assert_eq!(
            parse_tkhd_rotation(&make_tkhd_v0(0, -ONE, ONE, 0)),
            Some(270)
        );

        // version 1：矩阵偏移在 52
        let mut v1 = vec![0u8; 96];
        v1[0] = 1;
        v1[52..56].copy_from_slice(&0i32.to_be_bytes());
        v1[56..60].copy_from_slice(&ONE.to_be_bytes());
        v1[64..68].copy_from_slice(&(-ONE).to_be_bytes());
        v1[68..72].copy_from_slice(&0i32.to_be_bytes());
        assert_eq!(parse_tkhd_rotation(&v1), Some(90));
    }

    #[test]
    fn plane_10bit_sample_downshifts_cleanly() {
        // 2x1 10-bit 平面：样本 0 = 0，样本 1 = 1020（>> 2 == 255）
        let mut raw = Vec::new();
        raw.extend_from_slice(&0u16.to_le_bytes());
        raw.extend_from_slice(&1020u16.to_le_bytes());
        let p = PlaneSlice {
            data: &raw,
            stride: 4,
            width: 2,
            height: 1,
            bpp: 10,
        };
        assert_eq!(p.sample_u8(0, 0), 0);
        assert_eq!(p.sample_u8(1, 0), 255);
    }

    #[test]
    fn malformed_and_overflow_boxes_never_panic() {
        for bad in [
            &b""[..],
            &b"ftyp"[..],
            // largesize == u64::MAX
            &[
                0, 0, 0, 1, b'm', b'o', b'o', b'v', 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            ][..],
            // box size < header size (size = 4)
            &[0, 0, 0, 4, b'm', b'o', b'o', b'v'][..],
            // moov 内部含截断 trak
            &[
                0, 0, 0, 16, b'm', b'o', b'o', b'v', 0, 0, 0, 200, b't', b'r', b'a', b'k',
            ][..],
        ] {
            let res = decode_hevc_first_frame(bad);
            assert!(res.is_err(), "malformed input must return Err");
        }
    }

    #[test]
    fn excessive_box_nesting_is_rejected() {
        // 构造 16 层嵌套 box，验证超过 MAX_BOX_DEPTH (12) 时干净报错。
        let mut buf = vec![0u8; 8];
        buf[0..4].copy_from_slice(&8u32.to_be_bytes());
        buf[4..8].copy_from_slice(b"free");
        for _ in 0..16 {
            let total = (buf.len() + 8) as u32;
            let mut outer = Vec::with_capacity(total as usize);
            outer.extend_from_slice(&total.to_be_bytes());
            outer.extend_from_slice(b"trak");
            outer.extend_from_slice(&buf);
            buf = outer;
        }
        assert!(BoxIter::new(&buf, 13).is_err());
    }

    #[test]
    fn co64_and_rotated_mov_decode_end_to_end() {
        let mov = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../media-codec/tests/fixtures/tiny_hevc.mov"
        ))
        .unwrap();
        let (w, h, rgba) = decode_hevc_first_frame(&mov).expect("tiny_hevc.mov 应解出首帧");
        assert_eq!((w, h), (64, 48));
        assert_eq!(rgba.len(), 64 * 48 * 4);

        // 将 tkhd 旋转矩阵改为顺时针 90°，验证解码输出尺寸变为 48x64。
        let mut rotated = mov.clone();
        let tkhd_pos = rotated.windows(4).position(|w| w == b"tkhd").unwrap();
        // tkhd box 起点在 tkhd_pos - 4，payload 在 tkhd_pos + 4，v0 矩阵在 payload + 40。
        let mat = tkhd_pos + 4 + 40;
        rotated[mat..mat + 4].copy_from_slice(&0i32.to_be_bytes());
        rotated[mat + 4..mat + 8].copy_from_slice(&0x0001_0000i32.to_be_bytes());
        rotated[mat + 12..mat + 16].copy_from_slice(&(-0x0001_0000i32).to_be_bytes());
        rotated[mat + 16..mat + 20].copy_from_slice(&0i32.to_be_bytes());
        let (rw, rh, _) = decode_hevc_first_frame(&rotated).expect("旋转 90° 后仍可解");
        assert_eq!((rw, rh), (48, 64));

        // 单元测试 co64 64-bit chunk offset 解析定位。
        let mut co64_payload = Vec::new();
        co64_payload.extend_from_slice(&0u32.to_be_bytes()); // version + flags
        co64_payload.extend_from_slice(&1u32.to_be_bytes()); // count = 1
        co64_payload.extend_from_slice(&28u64.to_be_bytes()); // offset = 28
        let chunks = parse_co64(&co64_payload).unwrap();
        let stsc = vec![StscRun {
            first_chunk: 1,
            samples_per_chunk: 2,
        }];
        let stsz = SampleSizes::Constant { size: 10, count: 2 };
        assert_eq!(locate_sample(1, &stsc, &stsz, &chunks, 100), Some((28, 10)));
        assert_eq!(locate_sample(2, &stsc, &stsz, &chunks, 100), Some((38, 10)));
        assert_eq!(locate_sample(2, &stsc, &stsz, &chunks, 40), None);
    }
}
