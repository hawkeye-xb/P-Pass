//! #851：照片 / 视频里「元数据」所在的字节区间——Android 抹拍摄地点（没有 `ACCESS_MEDIA_LOCATION`
//! 时，系统把位置相关字节置 0、长度不变）只发生在这些区间里。桌面据此只向手机要这几段原样字节，
//! 拼回自己手里那份抹过的副本，而不是整张重传。
//!
//! 只认三类：JPEG（文件头到最后一个 APPn 段为止）、ISO-BMFF（HEIF / MP4 / MOV：`moov`、顶层
//! `meta`，以及 `iloc` 指向的 `Exif` / XMP 条目在文件里的区间）。认不出来的格式返回 `None`——
//! 调用方不猜，按「做不了」处理。区间可能重叠，未合并；是否在文件长度内由调用方再夹一次。

use std::io::{Read, Seek, SeekFrom};
use std::ops::Range;

/// JPEG 的 APPn 段都在文件头；读这么多足够覆盖（每段至多 64 KiB）。
const JPEG_HEAD: u64 = 4 * 1024 * 1024;
/// 顶层 `meta` 盒子整块读进来解析（HEIF 的 meta 只有几 KB；超过这个数按损坏处理）。
const META_MAX: u64 = 16 * 1024 * 1024;

/// 返回元数据区间；格式不认识或结构损坏时 `None`。
pub fn metadata_ranges(bytes: &[u8]) -> Option<Vec<Range<u64>>> {
    metadata_ranges_from(&mut std::io::Cursor::new(bytes), bytes.len() as u64)
}

/// 同 [`metadata_ranges`]，但只读需要的部分：JPEG 读文件头，ISO-BMFF 只读各顶层盒子的头和
/// `meta` 盒子本身——几 GB 的视频也不会整个读进内存。
pub fn metadata_ranges_from<R: Read + Seek>(r: &mut R, len: u64) -> Option<Vec<Range<u64>>> {
    let head = read_at(r, 0, len.min(12))?;
    if head.starts_with(&[0xFF, 0xD8]) {
        return jpeg(&read_at(r, 0, len.min(JPEG_HEAD))?);
    }
    if head.len() >= 12 && &head[4..8] == b"ftyp" {
        return isobmff(r, len);
    }
    None
}

fn read_at<R: Read + Seek>(r: &mut R, off: u64, n: u64) -> Option<Vec<u8>> {
    r.seek(SeekFrom::Start(off)).ok()?;
    let mut buf = vec![0u8; usize::try_from(n).ok()?];
    r.read_exact(&mut buf).ok()?;
    Some(buf)
}

fn jpeg(b: &[u8]) -> Option<Vec<Range<u64>>> {
    let mut o = 2usize;
    let mut end = 2usize;
    while o + 4 <= b.len() {
        if b[o] != 0xFF {
            return None;
        }
        let marker = b[o + 1];
        if marker == 0xFF {
            o += 1; // 填充字节
            continue;
        }
        // SOS 之后是熵编码数据；SOF 之后不再有 APPn。
        if marker == 0xDA
            || (0xC0..=0xCF).contains(&marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
        {
            break;
        }
        let len = u16::from_be_bytes([b[o + 2], b[o + 3]]) as usize;
        if len < 2 || o + 2 + len > b.len() {
            return None; // 损坏，或 APPn 超出了读进来的文件头
        }
        if (0xE0..=0xEF).contains(&marker) {
            end = o + 2 + len;
        }
        o += 2 + len;
    }
    #[allow(clippy::single_range_in_vec_init)] // 一段区间的列表，不是 0..end 的元素展开
    Some(vec![0..end as u64])
}

struct BoxHdr {
    typ: [u8; 4],
    body: usize,
    end: usize,
}

fn read_box(b: &[u8], o: usize, limit: usize) -> Option<BoxHdr> {
    if o + 8 > limit {
        return None;
    }
    let size32 = u32::from_be_bytes(b[o..o + 4].try_into().ok()?) as u64;
    let typ: [u8; 4] = b[o + 4..o + 8].try_into().ok()?;
    let (size, hdr) = match size32 {
        0 => ((limit - o) as u64, 8),
        1 => (
            u64::from_be_bytes(b.get(o + 8..o + 16)?.try_into().ok()?),
            16,
        ),
        n => (n, 8),
    };
    let end = o.checked_add(usize::try_from(size).ok()?)?;
    if size < hdr as u64 || end > limit {
        return None;
    }
    Some(BoxHdr {
        typ,
        body: o + hdr,
        end,
    })
}

fn children(b: &[u8], start: usize, end: usize) -> Option<Vec<BoxHdr>> {
    let mut out = Vec::new();
    let mut o = start;
    while o < end {
        let h = read_box(b, o, end)?;
        o = h.end;
        out.push(h);
    }
    Some(out)
}

/// 顶层盒子：只读每个盒子的头（8 或 16 字节），遇到 `meta` 才整块读进来。
fn isobmff<R: Read + Seek>(r: &mut R, len: u64) -> Option<Vec<Range<u64>>> {
    let mut out = Vec::new();
    let mut o = 0u64;
    while o < len {
        let hdr = read_at(r, o, (len - o).min(16))?;
        if hdr.len() < 8 {
            return None;
        }
        let size32 = u32::from_be_bytes(hdr[0..4].try_into().ok()?) as u64;
        let (size, hlen) = match size32 {
            0 => (len - o, 8),
            1 => (u64::from_be_bytes(hdr.get(8..16)?.try_into().ok()?), 16),
            n => (n, 8),
        };
        let end = o.checked_add(size)?;
        if size < hlen || end > len {
            return None;
        }
        match &hdr[4..8] {
            b"moov" => out.push(o..end),
            b"meta" => {
                out.push(o..end);
                if size > META_MAX {
                    return None;
                }
                let b = read_at(r, o, size)?;
                // meta 是 FullBox：4 字节 version/flags 之后才是子盒子。偏移都按文件算，所以把盒子
                // 内的相对位置加回 o。
                let kids = children(&b, hlen as usize + 4, b.len())?;
                let wanted = metadata_item_ids(&b, &kids)?;
                if !wanted.is_empty() {
                    out.extend(item_extents(&b, &kids, &wanted, len)?);
                }
            }
            _ => {}
        }
        o = end;
    }
    Some(out)
}

/// `iinf` 里类型为 `Exif` 或 `mime`（XMP）的条目 id。
fn metadata_item_ids(b: &[u8], kids: &[BoxHdr]) -> Option<Vec<u32>> {
    let Some(iinf) = kids.iter().find(|k| &k.typ == b"iinf") else {
        return Some(Vec::new());
    };
    let version = *b.get(iinf.body)?;
    let first = iinf.body + 4 + if version == 0 { 2 } else { 4 };
    let mut ids = Vec::new();
    for infe in children(b, first, iinf.end)? {
        if &infe.typ != b"infe" {
            continue;
        }
        let v = *b.get(infe.body)?;
        if v < 2 {
            continue; // v0/v1 没有 item_type
        }
        let p = infe.body + 4;
        let (id, after) = if v == 2 {
            (
                u16::from_be_bytes(b.get(p..p + 2)?.try_into().ok()?) as u32,
                p + 2,
            )
        } else {
            (u32::from_be_bytes(b.get(p..p + 4)?.try_into().ok()?), p + 4)
        };
        let typ = b.get(after + 2..after + 6)?; // 跳过 item_protection_index
        if typ == b"Exif" || typ == b"mime" {
            ids.push(id);
        }
    }
    Some(ids)
}

/// `iloc` 里这些条目在文件中的区间（construction_method 0 = 文件偏移；1 = idat，已在 meta 里）。
fn item_extents(b: &[u8], kids: &[BoxHdr], ids: &[u32], file_len: u64) -> Option<Vec<Range<u64>>> {
    let iloc = kids.iter().find(|k| &k.typ == b"iloc")?;
    let mut r = Reader {
        b,
        p: iloc.body,
        end: iloc.end,
    };
    let version = r.u8()?;
    r.skip(3)?;
    let sizes = r.u8()?;
    let (off_size, len_size) = ((sizes >> 4) as usize, (sizes & 0xF) as usize);
    let sizes2 = r.u8()?;
    let base_size = (sizes2 >> 4) as usize;
    let index_size = if version == 1 || version == 2 {
        (sizes2 & 0xF) as usize
    } else {
        0
    };
    let count = if version < 2 { r.uint(2)? } else { r.uint(4)? };
    let mut out = Vec::new();
    for _ in 0..count {
        let id = if version < 2 { r.uint(2)? } else { r.uint(4)? } as u32;
        let method = if version == 1 || version == 2 {
            r.uint(2)? & 0xF
        } else {
            0
        };
        r.skip(2)?; // data_reference_index
        let base = r.uint(base_size)?;
        let extents = r.uint(2)?;
        for _ in 0..extents {
            r.uint(index_size)?;
            let off = r.uint(off_size)?;
            let len = r.uint(len_size)?;
            if ids.contains(&id) && method == 0 {
                let start = base.checked_add(off)?;
                let end = if len == 0 {
                    file_len
                } else {
                    start.checked_add(len)?
                };
                out.push(start..end);
            }
        }
    }
    Some(out)
}

struct Reader<'a> {
    b: &'a [u8],
    p: usize,
    end: usize,
}

impl Reader<'_> {
    fn u8(&mut self) -> Option<u8> {
        let v = *self.b.get(self.p).filter(|_| self.p < self.end)?;
        self.p += 1;
        Some(v)
    }
    fn skip(&mut self, n: usize) -> Option<()> {
        (self.p + n <= self.end).then(|| self.p += n)
    }
    fn uint(&mut self, n: usize) -> Option<u64> {
        if n > 8 || self.p + n > self.end {
            return None;
        }
        let v = self.b[self.p..self.p + n]
            .iter()
            .fold(0u64, |acc, x| acc << 8 | *x as u64);
        self.p += n;
        Some(v)
    }
}
