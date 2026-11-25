//! 视频首帧解码子进程（`ppf-video-decoder`，Windows Media Foundation）的契约：
//! 真 worker 能解、畸形输入归类 Decode、缺失归类 SandboxUnavailable。
//!
//! 只在 Windows 上有真实 worker；非 Windows 端这些测试跳过（worker 是桩）。

#![allow(clippy::disallowed_methods)]

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use media_codec::{decode_video, make_thumbs, CodecError, ThumbOutcome};

/// 串行化对 `PPF_VIDEO_DECODE_WORKER` 的读写：cargo test 默认并行跑，
/// 一个测试改环境变量会污染另一个测试的 worker 解析（与 sandbox.rs 同款）。
static ENV: Mutex<()> = Mutex::new(());

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// 本平台没有视频解码能力时跳过（不写 `#[cfg]`，问 platform 的能力接口，B.2）。
fn skip_if_no_video_decode() -> bool {
    if platform::video_decode::video_decode_available() {
        return false;
    }
    eprintln!("本平台无视频解码能力（非 Windows），跳过");
    true
}

/// 断言像素不是纯色占位块（真实画面至少有不同颜色）。
fn assert_non_flat(img: &image::DynamicImage) {
    let rgba = img.to_rgba8();
    let first = rgba.get_pixel(0, 0);
    let distinct = rgba.pixels().any(|p| p != first);
    assert!(distinct, "解码出的帧必须是真实画面，不是纯色块");
}

#[test]
fn video_decoder_decodes_first_frame() {
    if skip_if_no_video_decode() {
        return;
    }
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let img = decode_video(&fixture("tiny.mp4")).expect("视频 decoder 应能解 H.264 MP4 首帧");
    assert_eq!((img.width(), img.height()), (64, 48), "fixture 是 64x48");
    assert_non_flat(&img);
}

#[test]
fn video_decoder_malformed_input_is_a_file_level_failure() {
    if skip_if_no_video_decode() {
        return;
    }
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("bad.mp4");
    std::fs::write(&p, b"this is not an mp4 at all").unwrap();
    let err = decode_video(&p).unwrap_err();
    assert!(matches!(err, CodecError::Decode { .. }), "{err:?}");
}

#[test]
fn video_decoder_missing_worker_is_unavailable() {
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("clip.mp4");
    std::fs::write(&p, b"whatever").unwrap();
    // debug 构建认环境变量，指向一个不存在的 worker → 拉起失败 = 系统性问题。
    std::env::set_var("PPF_VIDEO_DECODE_WORKER", dir.path().join("nope"));
    let err = decode_video(&p).unwrap_err();
    std::env::remove_var("PPF_VIDEO_DECODE_WORKER");
    assert!(matches!(err, CodecError::SandboxUnavailable(_)), "{err:?}");
}

fn run_video_request(payload: &[u8], ext: &str, max_edge: u32) -> decode_worker::proto::Response {
    let mut req_bytes = Vec::new();
    decode_worker::proto::write_request_header(
        &mut req_bytes,
        decode_worker::proto::KIND_VIDEO,
        max_edge,
        ext,
        payload.len() as u64,
    )
    .unwrap();
    req_bytes.extend_from_slice(payload);
    let mut out = Vec::new();
    media_codec::video::run_video(&mut &req_bytes[..], &mut out).unwrap();
    decode_worker::proto::read_response(&mut &out[..], max_edge).unwrap()
}

/// #2047 回归：Windows 服务沙盒或裸机无系统 HEVC MFT（以及非 Windows 无原生 video_decode）时，
/// `run_video` 必须回退到内置 `libde265` ISOBMFF 首帧软解，对 `.mov` 与 `.mp4` 均解出真彩首帧。
#[test]
fn run_video_decodes_hevc_mov_and_mp4_via_builtin_fallback() {
    for (file, ext) in [("tiny_hevc.mov", "mov"), ("tiny_hevc.mp4", "mp4")] {
        let bytes = std::fs::read(fixture(file)).unwrap();
        let resp = run_video_request(&bytes, ext, 1024);
        let decode_worker::proto::Response::Pixels {
            width,
            height,
            rgba,
        } = resp
        else {
            panic!("{file} 应由内置 libde265 解出首帧像素，实际返回: {resp:?}");
        };
        assert_eq!((width, height), (64, 48), "{file} 首帧尺寸应为 64x48");
        let img = image::DynamicImage::ImageRgba8(
            image::RgbaImage::from_raw(width, height, rgba).unwrap(),
        );
        assert_non_flat(&img);
    }

    // max_edge 缩小契约：最长边受请求约束。
    let bytes = std::fs::read(fixture("tiny_hevc.mov")).unwrap();
    let decode_worker::proto::Response::Pixels { width, height, .. } =
        run_video_request(&bytes, "mov", 32)
    else {
        panic!("缩放请求也应解出像素");
    };
    assert!(width <= 32 && height <= 32 && width > 0 && height > 0);

    // 畸形输入安全返回 STATUS_DECODE_FAILED，绝不 panic。
    let bad = run_video_request(b"not-an-isobmff-video-at-all", "mov", 1024);
    assert!(
        matches!(
            bad,
            decode_worker::proto::Response::Failed {
                status: decode_worker::proto::STATUS_DECODE_FAILED,
                ..
            }
        ),
        "畸形输入应返回 DecodeFailed: {bad:?}"
    );
}

/// 根因入口（卡「修复 E3」/ ADR 决定 6 的可判红判据）：无 ffmpeg 的 Windows 上，
/// `make_thumbs` 经 `thumb.rs::first_frame` 必须走新 video decoder 出真图。
/// 反证：把 `first_frame` 的 video 分支改回 `Err(FfmpegMissing)` → 本测试红。
#[test]
fn make_thumbs_without_ffmpeg_uses_video_decoder() {
    if skip_if_no_video_decode() {
        return;
    }
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    // 把 ffmpeg 摘出 PATH（并清 PPF_FFMPEG），让 ffmpeg_path() 返回 None；只留
    // System32（不含 ffmpeg）。video decoder 由绝对路径拉起，不依赖 PATH。
    let saved_path = std::env::var("PATH").unwrap_or_default();
    std::env::remove_var("PPF_FFMPEG");
    std::env::set_var("PATH", r"C:\Windows\System32");
    let dir = tempfile::tempdir().unwrap();
    let r = make_thumbs(&[0x46; 32], &fixture("tiny.mp4"), &dir.path().join("t"));
    let r_hevc = make_thumbs(
        &[0x47; 32],
        &fixture("tiny_hevc.mov"),
        &dir.path().join("t_hevc"),
    );
    std::env::set_var("PATH", saved_path);
    assert_eq!(
        r.outcome,
        ThumbOutcome::Generated,
        "无 ffmpeg 的 Windows 上 mp4 必须经 first_frame 的 video decoder 分支出真图，而不是占位图"
    );
    assert_non_flat(&image::open(&r.paths.t256).unwrap());
    assert_eq!(
        r_hevc.outcome,
        ThumbOutcome::Generated,
        "无 ffmpeg 的 Windows 上 HEVC .mov 必须经 ppf-video-decoder 内置 libde265 出真图"
    );
    assert_non_flat(&image::open(&r_hevc.paths.t256).unwrap());
}

/// 解析 PE（PE32 / PE32+）的 Import Directory，返回所有静态导入的 DLL 名（小写）。
/// 纯字节解析、不调平台 API，任何宿主都能跑解析器自测。
fn pe_imported_dlls(pe: &[u8]) -> Result<Vec<String>, String> {
    let u16_at = |off: usize| -> Result<u16, String> {
        let s = pe
            .get(off..off.checked_add(2).ok_or("u16 offset overflow")?)
            .ok_or_else(|| format!("PE truncated at {off:#x} (need 2 bytes)"))?;
        Ok(u16::from_le_bytes([s[0], s[1]]))
    };
    let u32_at = |off: usize| -> Result<u32, String> {
        let s = pe
            .get(off..off.checked_add(4).ok_or("u32 offset overflow")?)
            .ok_or_else(|| format!("PE truncated at {off:#x} (need 4 bytes)"))?;
        Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    };

    if pe.get(0..2) != Some(b"MZ".as_slice()) {
        return Err("missing MZ signature".into());
    }
    let e_lfanew = u32_at(0x3c)? as usize;
    if pe.get(e_lfanew..e_lfanew.saturating_add(4)) != Some(b"PE\0\0".as_slice()) {
        return Err("missing PE\\0\\0 signature".into());
    }
    let num_sections = u16_at(e_lfanew + 6)? as usize;
    let opt_hdr_size = u16_at(e_lfanew + 20)? as usize;
    let opt_off = e_lfanew + 24;
    if pe
        .get(opt_off..opt_off.saturating_add(opt_hdr_size))
        .is_none()
    {
        return Err("optional header truncated".into());
    }
    let magic = u16_at(opt_off)?;
    // DataDirectory[1] = Import Table (RVA + Size)：PE32+ 在 OptionalHeader+120，PE32 在 +104。
    let import_dd_rel = match magic {
        0x020b => 120usize,
        0x010b => 104usize,
        other => return Err(format!("unsupported PE optional header magic {other:#06x}")),
    };
    if opt_hdr_size < import_dd_rel + 8 {
        return Ok(Vec::new());
    }
    let import_rva = u32_at(opt_off + import_dd_rel)?;
    let import_size = u32_at(opt_off + import_dd_rel + 4)?;
    if import_rva == 0 || import_size == 0 {
        return Ok(Vec::new());
    }

    let sec_table_off = opt_off + opt_hdr_size;
    let mut sections = Vec::with_capacity(num_sections);
    for i in 0..num_sections {
        let sh = sec_table_off
            .checked_add(i * 40)
            .ok_or("section offset overflow")?;
        let virtual_size = u32_at(sh + 8)?;
        let virtual_addr = u32_at(sh + 12)?;
        let raw_size = u32_at(sh + 16)?;
        let raw_ptr = u32_at(sh + 20)?;
        sections.push((virtual_addr, virtual_size.max(raw_size), raw_size, raw_ptr));
    }

    let rva_to_off = |rva: u32| -> Result<usize, String> {
        for &(va, span, raw_size, raw_ptr) in &sections {
            if rva >= va && rva - va < span {
                let delta = rva - va;
                if delta >= raw_size {
                    return Err(format!("RVA {rva:#x} falls in uninitialized section tail"));
                }
                return (raw_ptr as usize)
                    .checked_add(delta as usize)
                    .ok_or_else(|| "file offset overflow".into());
            }
        }
        Err(format!("RVA {rva:#x} not mapped by any section"))
    };

    let mut desc_off = rva_to_off(import_rva)?;
    let mut dlls = Vec::new();
    loop {
        let orig_first_thunk = u32_at(desc_off)?;
        let name_rva = u32_at(desc_off + 12)?;
        let first_thunk = u32_at(desc_off + 16)?;
        if orig_first_thunk == 0 && name_rva == 0 && first_thunk == 0 {
            break;
        }
        if name_rva == 0 {
            return Err("import descriptor has zero Name RVA".into());
        }
        let name_off = rva_to_off(name_rva)?;
        let tail = pe
            .get(name_off..)
            .ok_or_else(|| format!("DLL name offset {name_off:#x} out of bounds"))?;
        let nul = tail
            .iter()
            .position(|&b| b == 0)
            .ok_or("unterminated DLL name in import table")?;
        let name = std::str::from_utf8(&tail[..nul])
            .map_err(|e| format!("non-utf8 DLL name: {e}"))?
            .to_ascii_lowercase();
        dlls.push(name);
        desc_off = desc_off
            .checked_add(20)
            .ok_or("descriptor offset overflow")?;
    }
    Ok(dlls)
}

#[test]
fn pe_import_parser_extracts_dll_names_and_rejects_truncation() {
    // 构造最小 PE32+ 镜像：1 个 .rdata 节（VA=0x1000, RawPtr=0x200），含两条导入描述符与结尾全 0 描述符。
    let mut pe = vec![0u8; 0x300];
    pe[0..2].copy_from_slice(b"MZ");
    pe[0x3c..0x40].copy_from_slice(&0x40u32.to_le_bytes()); // e_lfanew = 0x40
    pe[0x40..0x44].copy_from_slice(b"PE\0\0");
    pe[0x46..0x48].copy_from_slice(&1u16.to_le_bytes()); // NumberOfSections = 1
    pe[0x54..0x56].copy_from_slice(&0xf0u16.to_le_bytes()); // SizeOfOptionalHeader = 240 (PE32+)
    let opt = 0x58usize;
    pe[opt..opt + 2].copy_from_slice(&0x020bu16.to_le_bytes()); // PE32+ magic
    pe[opt + 120..opt + 124].copy_from_slice(&0x1000u32.to_le_bytes()); // Import RVA
    pe[opt + 124..opt + 128].copy_from_slice(&60u32.to_le_bytes()); // Import Size (3 descriptors)
    let sh = opt + 0xf0; // 0x148
    pe[sh..sh + 6].copy_from_slice(b".rdata");
    pe[sh + 8..sh + 12].copy_from_slice(&0x100u32.to_le_bytes()); // VirtualSize
    pe[sh + 12..sh + 16].copy_from_slice(&0x1000u32.to_le_bytes()); // VirtualAddress
    pe[sh + 16..sh + 20].copy_from_slice(&0x100u32.to_le_bytes()); // SizeOfRawData
    pe[sh + 20..sh + 24].copy_from_slice(&0x200u32.to_le_bytes()); // PointerToRawData
                                                                   // Descriptor 0 @ file 0x200 (RVA 0x1000) -> Name RVA 0x1040 (file 0x240)
    pe[0x200 + 12..0x200 + 16].copy_from_slice(&0x1040u32.to_le_bytes());
    pe[0x200 + 16..0x200 + 20].copy_from_slice(&0x1080u32.to_le_bytes());
    // Descriptor 1 @ file 0x214 (RVA 0x1014) -> Name RVA 0x1050 (file 0x250)
    pe[0x214 + 12..0x214 + 16].copy_from_slice(&0x1050u32.to_le_bytes());
    pe[0x214 + 16..0x214 + 20].copy_from_slice(&0x1088u32.to_le_bytes());
    // Descriptor 2 @ file 0x228 全 0 终止。
    pe[0x240..0x240 + 10].copy_from_slice(b"OLE32.dll\0");
    pe[0x250..0x250 + 12].copy_from_slice(b"combase.dll\0");

    assert_eq!(
        pe_imported_dlls(&pe).unwrap(),
        vec!["ole32.dll".to_string(), "combase.dll".to_string()]
    );
    assert!(pe_imported_dlls(&pe[..0x80]).is_err(), "截断镜像必须报错");
}

/// #1934 根因契约：Windows 服务形态（`LocalSystem` Session 0 + `AppContainer`）下，
/// 服务窗口站 `Service-0x0-3e7$` 的 DACL 不授予 `ALL APPLICATION PACKAGES` 访问权；
/// 一旦 `ppf-video-decoder.exe` 静态导入 `ole32.dll`（其静态依赖 `gdi32.dll` / `user32.dll`）
/// 或直接导入 `user32.dll` / `gdi32.dll` / `gdi32full.dll`，加载器在 `main()` 之前连接窗口站
/// 就会失败并以 `0xC0000142` (`STATUS_DLL_INIT_FAILED`) 秒退。
///
/// 反证：将 `video_decode.rs` 的 `CoInitializeEx` / `CreateStreamOnHGlobal` 改回 `windows` crate
/// 默认的 `ole32.dll` 绑定 → 本测试在任何会话（含交互桌面 CI）下均稳定判红。
#[test]
fn video_decoder_binary_avoids_win32k_and_ole32_imports() {
    if skip_if_no_video_decode() {
        return;
    }
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    std::env::remove_var("PPF_VIDEO_DECODE_WORKER");
    let worker = platform::isolated::video_decoder_worker_path()
        .expect("Windows 测试前应已编译出 ppf-video-decoder.exe");
    let bytes =
        std::fs::read(&worker).unwrap_or_else(|e| panic!("读取 {} 失败: {e}", worker.display()));
    let dlls = pe_imported_dlls(&bytes)
        .unwrap_or_else(|e| panic!("解析 {} 的 PE 导入表失败: {e}", worker.display()));

    for expected in ["mfplat.dll", "mfreadwrite.dll"] {
        assert!(
            dlls.iter().any(|d| d == expected),
            "{} 的 PE 导入表应包含 {expected}，实际导入: {dlls:?}",
            worker.display()
        );
    }
    for forbidden in ["ole32.dll", "user32.dll", "gdi32.dll", "gdi32full.dll"] {
        assert!(
            !dlls.iter().any(|d| d == forbidden),
            "{} 静态导入了 {forbidden}（Session 0 服务 + AppContainer 下会在 main() 前以 0xC0000142 秒退），实际导入: {dlls:?}",
            worker.display()
        );
    }
}
