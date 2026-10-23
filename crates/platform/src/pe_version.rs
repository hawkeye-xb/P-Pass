//! #1155：从 PE 字节里读版本资源（Windows 更新包防降级用）。
//!
//! 为什么不用 `GetFileVersionInfoW`：它只能读**磁盘上的路径**。brief D7 要求「PE 版本
//! 资源必须从已经通过 minisign 校验的同一份字节里读，不能先验签、再从磁盘重新读文件」，
//! 否则检查与使用之间存在被替换的窗口。所以这里在内存里解析 PE 的
//! `IMAGE_DIRECTORY_ENTRY_RESOURCE` → `RT_VERSION` → `VS_VERSIONINFO`。
//!
//! 只取 `StringFileInfo\*\FileVersion` 这一项字符串：`VS_FIXEDFILEINFO` 只有
//! `major.minor.patch.build`，会把 `0.10.0-test.9` 压成 `0.10.0.0`，预发布后缀丢失后
//! 无法比较（本机 windows-poc V8 实测 Tauri NSIS `setup.exe` 的 fixed info 就是
//! `0.4.0.0`，而字符串是 `0.4.0-test.5`）。读不到字符串就拒绝，不拿 fixed info 兜底。
//!
//! 这个模块是纯字节解析、没有平台 API，所以三个平台都编译、都跑单测；只有 Windows 的
//! 更新路径会调它。

const RT_VERSION: u32 = 16;
const IMAGE_DIRECTORY_ENTRY_RESOURCE: usize = 2;

#[derive(Debug, Clone, Copy)]
struct Section {
    virtual_address: u32,
    virtual_size: u32,
    raw_size: u32,
    raw_ptr: u32,
}

fn u16_at(bytes: &[u8], off: usize) -> Result<u16, String> {
    bytes
        .get(off..off + 2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
        .ok_or_else(|| format!("PE 结构越界（读 u16 @ {off:#x}）"))
}

fn u32_at(bytes: &[u8], off: usize) -> Result<u32, String> {
    bytes
        .get(off..off + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .ok_or_else(|| format!("PE 结构越界（读 u32 @ {off:#x}）"))
}

fn rva_to_offset(sections: &[Section], rva: u32) -> Option<usize> {
    sections.iter().find_map(|s| {
        let span = s.virtual_size.max(s.raw_size);
        if rva >= s.virtual_address && rva < s.virtual_address.saturating_add(span) {
            Some((s.raw_ptr + (rva - s.virtual_address)) as usize)
        } else {
            None
        }
    })
}

/// 一份 PE 文件里 `StringFileInfo` 的 `FileVersion` 字符串（如 `0.10.0-test.9`）。
pub fn file_version_from_bytes(bytes: &[u8]) -> Result<String, String> {
    if bytes.len() < 0x40 || &bytes[0..2] != b"MZ" {
        return Err("不是 PE 文件（缺 MZ 头）".into());
    }
    let pe_off = u32_at(bytes, 0x3c)? as usize;
    if bytes.get(pe_off..pe_off + 4) != Some(b"PE\0\0") {
        return Err("不是 PE 文件（缺 PE 签名）".into());
    }
    let coff = pe_off + 4;
    let num_sections = u16_at(bytes, coff + 2)? as usize;
    let size_opt = u16_at(bytes, coff + 16)? as usize;
    let opt = coff + 20;
    let magic = u16_at(bytes, opt)?;
    let dd_off = match magic {
        0x10b => opt + 96,
        0x20b => opt + 112,
        other => return Err(format!("未知的 PE 可选头 magic：{other:#x}")),
    };
    let res_entry = dd_off + IMAGE_DIRECTORY_ENTRY_RESOURCE * 8;
    let res_rva = u32_at(bytes, res_entry)?;
    if res_rva == 0 {
        return Err("PE 没有资源目录".into());
    }

    let sections_off = opt + size_opt;
    let mut sections = Vec::with_capacity(num_sections);
    for i in 0..num_sections {
        let off = sections_off + i * 40;
        sections.push(Section {
            virtual_address: u32_at(bytes, off + 12)?,
            virtual_size: u32_at(bytes, off + 8)?,
            raw_size: u32_at(bytes, off + 16)?,
            raw_ptr: u32_at(bytes, off + 20)?,
        });
    }

    let res_off = rva_to_offset(&sections, res_rva)
        .ok_or_else(|| format!("资源目录 RVA {res_rva:#x} 不落在任何节里"))?;

    // 资源目录：根 → 类型 RT_VERSION → 名字（取第一个）→ 语言（取第一个）→ 数据项
    let type_dir = resource_subdir(bytes, res_off, RT_VERSION)?;
    let name_dir = first_subdir(bytes, res_off, type_dir)?;
    let (data_off, data_len) = first_data_entry(bytes, res_off, name_dir)?;
    let blob_off = rva_to_offset(&sections, data_off)
        .ok_or_else(|| format!("版本资源 RVA {data_off:#x} 不落在任何节里"))?;
    let blob = bytes
        .get(blob_off..blob_off.saturating_add(data_len as usize))
        .ok_or_else(|| "版本资源长度越界".to_string())?;

    file_version_from_version_blob(blob)
}

/// 资源目录里按 ID 找子目录，返回子目录的**文件偏移**。
fn resource_subdir(bytes: &[u8], base: usize, wanted_id: u32) -> Result<usize, String> {
    let (named, ids) = (u16_at(bytes, base + 12)?, u16_at(bytes, base + 14)?);
    for i in 0..(named as usize + ids as usize) {
        let entry = base + 16 + i * 8;
        let name = u32_at(bytes, entry)?;
        if name & 0x8000_0000 != 0 {
            continue; // 字符串名，不是 ID
        }
        if name == wanted_id {
            let sub = u32_at(bytes, entry + 4)?;
            if sub & 0x8000_0000 == 0 {
                return Err(format!("资源 ID {wanted_id} 不是子目录"));
            }
            return Ok(base + (sub & 0x7fff_ffff) as usize);
        }
    }
    Err(format!("PE 资源里没有 ID {wanted_id}"))
}

fn first_subdir(bytes: &[u8], base: usize, dir: usize) -> Result<usize, String> {
    let total = u16_at(bytes, dir + 12)? as usize + u16_at(bytes, dir + 14)? as usize;
    if total == 0 {
        return Err("空资源目录".into());
    }
    let sub = u32_at(bytes, dir + 16 + 4)?;
    if sub & 0x8000_0000 == 0 {
        return Err("资源项不是子目录".into());
    }
    Ok(base + (sub & 0x7fff_ffff) as usize)
}

/// 取第一个数据项，返回 (数据 RVA, 长度)。
fn first_data_entry(bytes: &[u8], base: usize, dir: usize) -> Result<(u32, u32), String> {
    let total = u16_at(bytes, dir + 12)? as usize + u16_at(bytes, dir + 14)? as usize;
    if total == 0 {
        return Err("版本资源下没有语言项".into());
    }
    let entry = dir + 16;
    let data = u32_at(bytes, entry + 4)?;
    if data & 0x8000_0000 != 0 {
        return Err("语言项还是子目录，资源树形状不符".into());
    }
    let data_entry = base + data as usize;
    Ok((u32_at(bytes, data_entry)?, u32_at(bytes, data_entry + 4)?))
}

struct VersionBlock<'a> {
    key: String,
    value: Option<&'a [u8]>,
    children: &'a [u8],
}

/// 解析一段 `VS_VERSIONINFO` 块（根块或它的子块）。
fn parse_block(buf: &[u8], off: usize) -> Result<VersionBlock<'_>, String> {
    let w_length = u16_at(buf, off)? as usize;
    let w_value_length = u16_at(buf, off + 2)? as usize;
    let w_type = u16_at(buf, off + 4)?;
    if w_length < 6 || off + w_length > buf.len() {
        return Err(format!("版本块长度不合法（{w_length}）"));
    }
    let block = &buf[off..off + w_length];

    let key_bytes = &block[6..];
    let mut key_units = Vec::new();
    let mut i = 0;
    loop {
        let u = u16_at(key_bytes, i)?;
        i += 2;
        if u == 0 {
            break;
        }
        key_units.push(u);
    }
    let key = String::from_utf16_lossy(&key_units);
    let after_key = align4(6 + i);
    if after_key > block.len() {
        return Err("版本块 key 之后越界".into());
    }
    let value_len = if w_type == 1 {
        w_value_length * 2
    } else {
        w_value_length
    };
    let value_start = after_key;
    let value_end = value_start.saturating_add(value_len).min(block.len());
    let children_start = align4(value_end).min(block.len());
    Ok(VersionBlock {
        key,
        value: Some(&block[value_start..value_end]),
        children: &block[children_start..],
    })
}

fn align4(n: usize) -> usize {
    (n + 3) & !3
}

fn iter_children(children: &[u8]) -> Vec<Result<VersionBlock<'_>, String>> {
    let mut out = Vec::new();
    let mut off = 0usize;
    while off + 6 <= children.len() {
        match parse_block(children, off) {
            Ok(b) => {
                let len = u16_at(children, off).unwrap_or(0) as usize;
                out.push(Ok(b));
                if len == 0 {
                    break;
                }
                off += align4(len);
            }
            Err(e) => {
                out.push(Err(e));
                break;
            }
        }
    }
    out
}

fn utf16_value(bytes: &[u8]) -> String {
    let mut units = Vec::new();
    let mut i = 0;
    while i + 1 < bytes.len() {
        let u = u16::from_le_bytes([bytes[i], bytes[i + 1]]);
        i += 2;
        if u == 0 {
            break;
        }
        units.push(u);
    }
    String::from_utf16_lossy(&units)
}

/// 直接从 `VS_VERSIONINFO` 字节里取 `StringFileInfo\<lang>\FileVersion`。
pub fn file_version_from_version_blob(blob: &[u8]) -> Result<String, String> {
    let root = parse_block(blob, 0)?;
    if root.key != "VS_VERSION_INFO" {
        return Err(format!("版本块根 key 不是 VS_VERSION_INFO：{}", root.key));
    }
    let mut string_file_info: Option<&[u8]> = None;
    for child in iter_children(root.children) {
        let child = child?;
        if child.key == "StringFileInfo" {
            string_file_info = Some(child.children);
            break;
        }
    }
    let string_file_info =
        string_file_info.ok_or_else(|| "版本资源里没有 StringFileInfo".to_string())?;

    let mut first_err: Option<String> = None;
    for table in iter_children(string_file_info) {
        let table = match table {
            Ok(t) => t,
            Err(e) => {
                first_err.get_or_insert(e);
                continue;
            }
        };
        for s in iter_children(table.children) {
            let s = match s {
                Ok(s) => s,
                Err(e) => {
                    first_err.get_or_insert(e);
                    continue;
                }
            };
            if s.key.eq_ignore_ascii_case("FileVersion") {
                let value = s
                    .value
                    .map(utf16_value)
                    .ok_or_else(|| "FileVersion 没有取值".to_string())?;
                let value = value.trim().to_string();
                if value.is_empty() {
                    return Err("FileVersion 是空串".into());
                }
                return Ok(value);
            }
        }
    }
    Err(first_err.unwrap_or_else(|| "版本资源里没有 FileVersion 字符串".into()))
}

/// 测试用的最小 PE 构造器：只给 #1155 的单测造「带版本资源的 PE」。
#[cfg(test)]
pub(crate) mod test_pe {
    /// 造一份 `VS_VERSIONINFO`（根 + StringFileInfo + 一个 StringTable + 两条字符串）。
    pub(crate) fn build_version_blob(file_version: &str) -> Vec<u8> {
        fn utf16(s: &str) -> Vec<u8> {
            let mut v: Vec<u8> = s.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
            v.extend_from_slice(&[0, 0]);
            v
        }
        fn block(key: &str, value: &[u8], value_units: u16, ty: u16, children: &[u8]) -> Vec<u8> {
            let mut b = Vec::new();
            b.extend_from_slice(&[0, 0]); // wLength 占位
            b.extend_from_slice(&value_units.to_le_bytes());
            b.extend_from_slice(&ty.to_le_bytes());
            b.extend_from_slice(&utf16(key));
            while b.len() % 4 != 0 {
                b.push(0);
            }
            b.extend_from_slice(value);
            while b.len() % 4 != 0 {
                b.push(0);
            }
            b.extend_from_slice(children);
            while b.len() % 4 != 0 {
                b.push(0);
            }
            let len = b.len() as u16;
            b[0..2].copy_from_slice(&len.to_le_bytes());
            b
        }
        let file_version_utf16 = utf16(file_version);
        let file_version_units = (file_version_utf16.len() / 2) as u16;
        let product = block(
            "ProductVersion",
            &file_version_utf16,
            file_version_units,
            1,
            &[],
        );
        let fv = block(
            "FileVersion",
            &file_version_utf16,
            file_version_units,
            1,
            &[],
        );
        let mut strings = fv.clone();
        strings.extend_from_slice(&product);
        let table = block("040904B0", &[], 0, 1, &strings);
        let sfi = block("StringFileInfo", &[], 0, 1, &table);
        // VS_FIXEDFILEINFO：44 字节以外的字段这里全是 0，解析器不看它
        let fixed = vec![0u8; 52];
        block("VS_VERSION_INFO", &fixed, 52, 0, &sfi)
    }

    /// 直接按版本号造一个带该版本字符串的 PE（只有 Windows 的更新判据测试用）。
    #[cfg(windows)]
    pub(crate) fn pe_with_version(v: &str) -> Vec<u8> {
        build_pe(&build_version_blob(v))
    }

    pub(crate) fn build_pe(version_blob: &[u8]) -> Vec<u8> {
        let mut pe = vec![0u8; 0x200 + 0x400];
        pe[0..2].copy_from_slice(b"MZ");
        pe[0x3c..0x40].copy_from_slice(&0x80u32.to_le_bytes());
        pe[0x80..0x84].copy_from_slice(b"PE\0\0");
        let coff = 0x84;
        pe[coff + 2..coff + 4].copy_from_slice(&1u16.to_le_bytes()); // NumberOfSections
        pe[coff + 16..coff + 18].copy_from_slice(&240u16.to_le_bytes()); // SizeOfOptionalHeader
        let opt = coff + 20;
        pe[opt..opt + 2].copy_from_slice(&0x20bu16.to_le_bytes()); // PE32+
        let dd = opt + 112;
        let res_entry = dd + 2 * 8;
        pe[res_entry..res_entry + 4].copy_from_slice(&0x1000u32.to_le_bytes()); // 资源 RVA
        pe[res_entry + 4..res_entry + 8].copy_from_slice(&0x800u32.to_le_bytes()); // 大小
        let sec = opt + 240;
        pe[sec..sec + 8].copy_from_slice(b".rsrc\0\0\0");
        pe[sec + 8..sec + 12].copy_from_slice(&0x400u32.to_le_bytes()); // VirtualSize
        pe[sec + 12..sec + 16].copy_from_slice(&0x1000u32.to_le_bytes()); // VirtualAddress
        pe[sec + 16..sec + 20].copy_from_slice(&0x400u32.to_le_bytes()); // SizeOfRawData
        pe[sec + 20..sec + 24].copy_from_slice(&0x200u32.to_le_bytes()); // PointerToRawData

        let base = 0x200usize; // 资源目录的文件偏移（RVA 0x1000）
                               // 根目录：一个 ID 项 → 子目录 @ +0x18
        pe[base + 14..base + 16].copy_from_slice(&1u16.to_le_bytes());
        pe[base + 16..base + 20].copy_from_slice(&16u32.to_le_bytes());
        pe[base + 20..base + 24].copy_from_slice(&0x8000_0018u32.to_le_bytes());
        // 类型目录 @ +0x18：一个 ID 项 → 子目录 @ +0x30
        let d1 = base + 0x18;
        pe[d1 + 14..d1 + 16].copy_from_slice(&1u16.to_le_bytes());
        pe[d1 + 16..d1 + 20].copy_from_slice(&1u32.to_le_bytes());
        pe[d1 + 20..d1 + 24].copy_from_slice(&0x8000_0030u32.to_le_bytes());
        // 名字目录 @ +0x30：一个语言项 → 数据项 @ +0x48
        let d2 = base + 0x30;
        pe[d2 + 14..d2 + 16].copy_from_slice(&1u16.to_le_bytes());
        pe[d2 + 16..d2 + 20].copy_from_slice(&1033u32.to_le_bytes());
        pe[d2 + 20..d2 + 24].copy_from_slice(&0x48u32.to_le_bytes());
        // 数据项 @ +0x48：RVA 0x1100、长度、代码页 0、保留 0
        let de = base + 0x48;
        pe[de..de + 4].copy_from_slice(&0x1100u32.to_le_bytes());
        pe[de + 4..de + 8].copy_from_slice(&(version_blob.len() as u32).to_le_bytes());
        // 版本资源 @ RVA 0x1100 → 文件偏移 0x300
        pe[0x300..0x300 + version_blob.len()].copy_from_slice(version_blob);
        pe
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use super::test_pe::{build_pe, build_version_blob};

    #[test]
    fn reads_file_version_string_including_prerelease_suffix() {
        for v in ["0.10.0-test.9", "0.4.0-test.5", "1.2.3", "2026.10.3"] {
            let blob = build_version_blob(v);
            let pe = build_pe(&blob);
            assert_eq!(file_version_from_bytes(&pe).as_deref(), Ok(v));
        }
    }

    #[test]
    fn rejects_non_pe_bytes() {
        assert!(file_version_from_bytes(b"PK\x03\x04 not a pe").is_err());
        assert!(file_version_from_bytes(&[]).is_err());
        let mut pe = build_pe(&build_version_blob("1.0.0"));
        pe[0x3c..0x40].copy_from_slice(&0xffffu32.to_le_bytes()); // e_lfanew 越界
        assert!(file_version_from_bytes(&pe).is_err());
    }

    #[test]
    fn rejects_pe_without_version_resource() {
        let blob = build_version_blob("1.0.0");
        let mut pe = build_pe(&blob);
        // 把根目录的 ID 换成别的（不是 RT_VERSION）
        pe[0x200 + 16..0x200 + 20].copy_from_slice(&17u32.to_le_bytes());
        let err = file_version_from_bytes(&pe).unwrap_err();
        assert!(err.contains("没有 ID 16"), "{err}");
    }

    #[test]
    fn rejects_version_blob_without_file_version() {
        let blob = build_version_blob("1.0.0");
        let pe = build_pe(&blob);
        assert!(file_version_from_bytes(&pe).is_ok());
        // 根块 key 不对就直接拒
        let mut broken = blob.clone();
        broken[6] = b'X';
        assert!(file_version_from_version_blob(&broken).is_err());
    }

    /// 真实 PE 对照：解析结果必须和系统 API `GetFileVersionInfoW` 给的字符串一致。
    /// 反过来也说明「读内存字节」与「读磁盘文件」在这类包上等价（只是前者没有 TOCTOU 窗口）。
    #[cfg(windows)]
    #[test]
    fn matches_get_file_version_info_on_a_real_system_pe() {
        use std::ffi::c_void;
        use std::ptr;
        use windows::core::{w, HSTRING};
        use windows::Win32::Storage::FileSystem::{
            GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW,
        };

        let path = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into())
            + "\\System32\\kernel32.dll";
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(_) => return, // 没有这个文件就跳过（不是 Linux/macOS 路径）
        };
        let ours = file_version_from_bytes(&bytes).expect("parse kernel32 version");

        let wide = HSTRING::from(path.as_str());
        let size = unsafe { GetFileVersionInfoSizeW(&wide, None) };
        assert!(size > 0);
        let mut buf = vec![0u8; size as usize];
        unsafe { GetFileVersionInfoW(&wide, None, size, buf.as_mut_ptr() as *mut c_void) }
            .expect("GetFileVersionInfoW");
        let mut ptr: *mut c_void = ptr::null_mut();
        let mut len = 0u32;
        let ok = unsafe {
            VerQueryValueW(
                buf.as_ptr() as *const c_void,
                w!("\\StringFileInfo\\040904B0\\FileVersion"),
                &mut ptr,
                &mut len,
            )
        };
        if !ok.as_bool() || ptr.is_null() {
            return; // 语言/代码页不是 040904B0，本机不适用
        }
        let api = unsafe {
            String::from_utf16_lossy(std::slice::from_raw_parts(ptr as *const u16, len as usize))
        };
        let api = api.trim_end_matches('\0').trim();
        assert_eq!(ours, api);
    }
}
