//! #544：导出件与落盘日志的统一脱敏（按值的形状，不按字段名）。
//!
//! 硬要求：诊断包即使被整包公开，也不能让任何人借此连上用户设备、拿到照片，
//! 或者定位 / 识别用户。原则是**源头不记、脱敏兜底**——这里是兜底那一层，
//! 同时也装在日志写入器上（`log_guard`），第三方 crate（iroh 等）写出的行
//! 同样过这里再落盘。
//!
//! 规则按顺序（另有规则 0：十进制字节数组，见 [`mask_byte_arrays`]）：
//! 1. **IP 地址**：公网 IPv4 / IPv6 换成 `<ipv4:public>` / `<ipv6:public>`，
//!    端口保留（单独的端口号不定位任何人）。私网、回环、链路本地、CGNAT、
//!    未指定地址原样保留——局域网排障要看它们，它们也定位不到人。分类器
//!    **默认判公网**：只有明确列出的非公网段才放过（文档段 203.0.113.x、
//!    2001:db8:: 因此按公网处理，测试正好用它们）。
//! 2. **URL 主机名**：`http(s)://`、`ws(s)://` 后的主机名不在白名单（n0 relay 所在的
//!    `iroh.link`、`github.com`）就换成 `<host>`——自建 relay 的域名能识别人。
//! 3. **长不透明串**：由 `[A-Za-z0-9_-]` 组成、长度 ≥32、含 ≥2 个数字和
//!    ≥8 个字母的连续串只留前 8 位。覆盖 base32 票据 / NodeId / hash 与
//!    base64url 的地址令牌（里面编着 NodeId 和直连 IP，hex 规则看不见）。
//! 4. **长 hex 串**（≥24 位连续 hex：全长 NodeId、hash、配对令牌）只留前 8 位
//!    ——旧规则，口径与 `devices.json` 的前缀一致。
//!
//! 桌面壳是独立 workspace（ADR-012），`apps/desktop/src-tauri/src/redact.rs`
//! 是同一份代码的第二份拷贝。两份都跑 `assets/privacy/redact-vectors.json`
//! 这组共用向量，靠它锁死不漂移。

use std::net::{Ipv4Addr, Ipv6Addr};

/// 统一入口：字节数组 → IP → URL 主机名 → 长串。幂等（对输出再跑一遍
/// 结果不变）。
pub fn redact(s: &str) -> String {
    mask_tokens(&mask_url_hosts(&mask_ips(&mask_byte_arrays(s))))
}

/// 规则 0：`[u8; 32]` 这类字段被 `{:?}` 打出来是十进制数组
/// （`[234, 74, 108, …]`），上面哪条形状规则都认不出。≥16 个 0..=255 的
/// 整数组成的方括号列表整体换成 `[<bytes:N>]`。
pub fn mask_byte_arrays(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(open) = rest.find('[') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        let masked = after.find(']').and_then(|close| {
            let body = &after[..close];
            let items: Vec<&str> = body.split(',').map(str::trim).collect();
            let all_bytes = items
                .iter()
                .all(|t| !t.is_empty() && t.len() <= 3 && t.parse::<u16>().is_ok_and(|n| n <= 255));
            (items.len() >= 16 && all_bytes).then_some((close, items.len()))
        });
        match masked {
            Some((close, n)) => {
                out.push_str(&format!("[<bytes:{n}>]"));
                rest = &after[close + 1..];
            }
            None => {
                out.push('[');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

fn v4_is_public(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    let cgnat = o[0] == 100 && (o[1] & 0xc0) == 64;
    !(ip.is_private()
        || ip.is_loopback()
        || ip.is_link_local()
        || ip.is_unspecified()
        || ip.is_broadcast()
        || ip.is_multicast()
        || cgnat)
}

fn v6_is_public(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return v4_is_public(v4);
    }
    let s0 = ip.segments()[0];
    let unique_local = (s0 & 0xfe00) == 0xfc00;
    let link_local = (s0 & 0xffc0) == 0xfe80;
    !(ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() || unique_local || link_local)
}

fn is_ip_char(c: char) -> bool {
    c.is_ascii_hexdigit() || c == ':' || c == '.'
}

fn is_word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// 规则 1：公网 IP 打码。
pub fn mask_ips(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < chars.len() {
        if !is_ip_char(chars[i]) {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        let mut j = i;
        while j < chars.len() && is_ip_char(chars[j]) {
            j += 1;
        }
        let run: String = chars[i..j].iter().collect();
        let prev = i.checked_sub(1).map(|k| chars[k]);
        let next = chars.get(j).copied();
        out.push_str(&mask_ip_run(&run, prev, next));
        i = j;
    }
    out
}

/// 一段 `[0-9A-Fa-f:.]` 连续串：是 IP（可带端口）就按类别处理，否则原样。
fn mask_ip_run(run: &str, prev: Option<char>, next: Option<char>) -> String {
    // 紧贴着字母数字的不是独立的地址（`noq_proto::connection`、`0.58s`、
    // `T01:49:50.5` 这类）。
    if next.is_some_and(is_word) {
        return run.to_string();
    }
    // 先试整段，再试去掉首部冒号 / 尾部标点的核心（`addr:203.0.113.7`、句末的点）。
    let lead = run.len() - run.trim_start_matches(':').len();
    let core_trimmed = run[lead..].trim_end_matches(['.', ':']);
    let trail = run.len() - lead - core_trimmed.len();
    let candidates = [(0usize, run, 0usize), (lead, core_trimmed, trail)];
    for (lead, core, trail) in candidates {
        let effective_prev = if lead > 0 { Some(':') } else { prev };
        if effective_prev.is_some_and(is_word) || core.is_empty() {
            continue;
        }
        if let Some(rep) = classify_ip(core) {
            let mut s = String::with_capacity(run.len());
            s.push_str(&run[..lead]);
            s.push_str(&rep);
            s.push_str(&run[run.len() - trail..]);
            return s;
        }
    }
    run.to_string()
}

/// `core` 是一个 IP（或 `IPv4:端口`）→ 返回替换后的文本；不是 → None。
fn classify_ip(core: &str) -> Option<String> {
    if let Ok(v6) = core.parse::<Ipv6Addr>() {
        return Some(if v6_is_public(v6) {
            "<ipv6:public>".to_string()
        } else {
            core.to_string()
        });
    }
    if let Ok(v4) = core.parse::<Ipv4Addr>() {
        return Some(if v4_is_public(v4) {
            "<ipv4:public>".to_string()
        } else {
            core.to_string()
        });
    }
    let (addr, port) = core.rsplit_once(':')?;
    if port.is_empty() || port.len() > 5 || !port.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let v4 = addr.parse::<Ipv4Addr>().ok()?;
    Some(if v4_is_public(v4) {
        format!("<ipv4:public>:{port}")
    } else {
        core.to_string()
    })
}

/// 白名单：n0 的 relay / 发现服务（`*.iroh.link`，地域码只到大洲级）与
/// GitHub（更新检查）。其余主机名一律打码。
const ALLOWED_HOSTS: &[&str] = &["iroh.link", "github.com", "githubusercontent.com"];

fn host_allowed(host: &str) -> bool {
    let h = host.trim_end_matches('.').to_ascii_lowercase();
    ALLOWED_HOSTS
        .iter()
        .any(|d| h == *d || h.ends_with(&format!(".{d}")))
}

/// 规则 2：URL 主机名打码。
pub fn mask_url_hosts(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    loop {
        let hit = ["https://", "http://", "wss://", "ws://"]
            .iter()
            .filter_map(|scheme| rest.find(scheme).map(|p| (p, scheme.len())))
            .min();
        let Some((pos, len)) = hit else {
            out.push_str(rest);
            return out;
        };
        out.push_str(&rest[..pos + len]);
        let after = &rest[pos + len..];
        let host_len = after
            .find(|c: char| {
                c.is_whitespace()
                    || matches!(
                        c,
                        '/' | ':'
                            | '?'
                            | '#'
                            | '<'
                            | '>'
                            | '"'
                            | '\''
                            | '('
                            | ')'
                            | '['
                            | ']'
                            | '{'
                            | '}'
                            | ','
                            | ';'
                            | '&'
                            | '\\'
                    )
            })
            .unwrap_or(after.len());
        let host = &after[..host_len];
        if host.is_empty() || host_allowed(host) {
            out.push_str(host);
        } else {
            out.push_str("<host>");
        }
        rest = &after[host_len..];
    }
}

fn is_token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '-'
}

fn is_opaque(run: &str) -> bool {
    let digits = run.bytes().filter(u8::is_ascii_digit).count();
    let letters = run.bytes().filter(u8::is_ascii_alphabetic).count();
    run.len() >= 32 && digits >= 2 && letters >= 8
}

const MASK: &str = "…<masked>";

/// 规则 3 + 4：长不透明串与长 hex 串只留前 8 位。
pub fn mask_tokens(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while !rest.is_empty() {
        let Some(start) = rest.find(is_token_char) else {
            break;
        };
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        let len = tail.find(|c| !is_token_char(c)).unwrap_or(tail.len());
        let run = &tail[..len];
        let all_hex = run.bytes().all(|b| b.is_ascii_hexdigit());
        if is_opaque(run) || (all_hex && run.len() >= 24) {
            out.push_str(&run[..8]);
            out.push_str(MASK);
        } else {
            out.push_str(&mask_hex_subruns(run));
        }
        rest = &tail[len..];
    }
    out.push_str(rest);
    out
}

/// 不够"不透明"的串里嵌着的 ≥24 位 hex（`node_<24hex>` 这类）仍然要打码。
fn mask_hex_subruns(run: &str) -> String {
    let mut out = String::with_capacity(run.len());
    let mut rest = run;
    while !rest.is_empty() {
        let Some(start) = rest.find(|c: char| c.is_ascii_hexdigit()) else {
            break;
        };
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        let len = tail
            .find(|c: char| !c.is_ascii_hexdigit())
            .unwrap_or(tail.len());
        if len >= 24 {
            out.push_str(&tail[..8]);
            out.push_str(MASK);
        } else {
            out.push_str(&tail[..len]);
        }
        rest = &tail[len..];
    }
    out.push_str(rest);
    out
}

// ── #544 规则 5：导出件里的路径与文件名（只在导出时用，日志写入器不用）──
//
// 照片文件名、相册文件夹名、外置盘卷名都可能带人名（「张三 婚礼/IMG 1.jpg」）。
// 导出件里一律不留：文件名换成 `<file>.扩展名`，目录层级里不在白名单的名字
// 换成 `<dir>`。白名单只收系统 / 本 App 自己起的名字（`originals`、
// `Application Support`、`P-Pass`…）、纯数字（年 / 月）、占位符与已打码前缀。
// 带空格的名字按"下一个词不是小写英文单词就算同一个名字"黏合——宁可多遮
// 一个日志词，不漏一个人名。

/// 导出件专用：[`redact`] + 路径 / 文件名打码。
pub fn redact_export(s: &str) -> String {
    mask_paths(&redact(s))
}

const MEDIA_EXTS: &[&str] = &[
    "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "avif", "jxl",
    "raw", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw", "pef", "mp4", "mov",
    "m4v", "avi", "mkv", "3gp", "hevc", "webm", "mts", "m2ts", "livp", "aae", "xmp",
];

const SYSTEM_FILE_EXTS: &[&str] = &[
    "log", "err", "toml", "key", "token", "zip", "plist", "db", "json", "txt", "upload", "1",
];

const SAFE_SEGMENTS: &[&str] = &[
    "users",
    "home",
    "volumes",
    "library",
    "logs",
    "application support",
    "launchagents",
    "appdata",
    "local",
    "roaming",
    "programdata",
    "pictures",
    "documents",
    "desktop",
    "downloads",
    "movies",
    "p-pass",
    "originals",
    ".ppf",
    "thumbs",
    "staging",
    "flow-staging",
    "blobs",
    "flow-blobs",
    "inbox",
    "tmp",
    "var",
    "private",
    "opt",
    "etc",
];

const SAFE_FILES: &[&str] = &[
    "daemon.log",
    "daemon.log.1",
    "p-pass-daemon.log",
    "p-pass-daemon.err",
    "config.toml",
    "identity.key",
    "ipc.token",
    "ppf-logs.zip",
    "com.p-pass.daemon.plist",
    "blobs.db",
];

fn is_path_term(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r'
            | '\t'
            | '"'
            | '\''
            | '`'
            | '('
            | ')'
            | '['
            | ']'
            | '{'
            | '}'
            | ','
            | ';'
            | '|'
            | '*'
            | '?'
            | '='
            | ':'
    )
}

fn is_sep(c: char) -> bool {
    c == '/' || c == '\\'
}

/// `\"` 是转义引号（Debug / JSON 文本里的），算终止符而不是 Windows 分隔符。
fn escaped_quote(c: &[char], k: usize) -> bool {
    c[k] == '\\' && c.get(k + 1) == Some(&'"')
}

fn sep_at(c: &[char], k: usize) -> bool {
    is_sep(c[k]) && !escaped_quote(c, k)
}

fn term_at(c: &[char], k: usize) -> bool {
    is_path_term(c[k]) || escaped_quote(c, k)
}

/// `name.ext` → `Some(ext)`（ext 1–6 位 ASCII 字母数字、含字母或是 `1`，名字部分非空）。
fn split_ext(seg: &str) -> Option<(&str, &str)> {
    let (name, ext) = seg.rsplit_once('.')?;
    let ok = !name.is_empty()
        && (1..=6).contains(&ext.len())
        && ext.bytes().all(|b| b.is_ascii_alphanumeric())
        && (ext.bytes().any(|b| b.is_ascii_alphabetic()) || ext == "1");
    ok.then_some((name, ext))
}

fn has_known_ext(word: &str) -> bool {
    split_ext(word).is_some_and(|(_, e)| {
        let e = e.to_ascii_lowercase();
        MEDIA_EXTS.contains(&e.as_str()) || SYSTEM_FILE_EXTS.contains(&e.as_str())
    })
}

fn has_media_ext(seg: &str) -> bool {
    split_ext(seg).is_some_and(|(_, e)| MEDIA_EXTS.contains(&e.to_ascii_lowercase().as_str()))
}

fn safe_segment(seg: &str) -> bool {
    let lower = seg.to_ascii_lowercase();
    seg.is_empty()
        || seg == "."
        || seg == ".."
        || (seg.starts_with('<') && seg.ends_with('>') && !seg[1..seg.len() - 1].contains('<'))
        || seg.ends_with("…<masked>")
        || seg.bytes().all(|b| b.is_ascii_digit())
        || SAFE_SEGMENTS.contains(&lower.as_str())
}

fn mask_segment(seg: &str, last: bool) -> String {
    if safe_segment(seg) {
        return seg.to_string();
    }
    if last {
        if SAFE_FILES.contains(&seg.to_ascii_lowercase().as_str()) {
            return seg.to_string();
        }
        if let Some((name, ext)) = split_ext(seg) {
            if safe_segment(name) && name.starts_with('<') {
                return seg.to_string();
            }
            return format!("<file>.{}", ext.to_ascii_lowercase());
        }
    }
    "<dir>".to_string()
}

/// 从 `i` 起读一个路径段（到分隔符 / 终止符为止），按黏合规则跨空格：
/// 本段已以已知扩展名结尾 → 停；往后同一短语（不跨分隔符 / 终止符）里有词以
/// 已知扩展名结尾 → 一直吞到它（`Li Si birthday 2026.mov` 整段是文件名）；
/// 否则下一个词以非小写字母 / 数字开头（大写、中文、数字）才吞。
fn read_segment(c: &[char], start: usize) -> usize {
    let word_end = |mut k: usize| {
        while k < c.len() && !sep_at(c, k) && !term_at(c, k) && !c[k].is_whitespace() {
            k += 1;
        }
        k
    };
    let mut i = word_end(start);
    loop {
        let so_far: String = c[start..i].iter().collect();
        if i >= c.len() || c[i] != ' ' || has_known_ext(&so_far) {
            return i;
        }
        // 往后看同一短语里有没有以已知扩展名结尾的词。
        let mut k = i;
        while k < c.len() && c[k] == ' ' {
            let w0 = k + 1;
            let w1 = word_end(w0);
            if w1 == w0 {
                break;
            }
            let word: String = c[w0..w1].iter().collect();
            if has_known_ext(&word) {
                return w1;
            }
            k = w1;
        }
        let w0 = i + 1;
        let w1 = word_end(w0);
        let first = c.get(w0).copied().unwrap_or(' ');
        let glue = w1 > w0
            && ((first.is_alphabetic() && !first.is_ascii_lowercase()) || first.is_ascii_digit());
        if !glue {
            return i;
        }
        i = w1;
    }
}

/// 规则 5：路径与文件名。
pub fn mask_paths(s: &str) -> String {
    let c: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < c.len() {
        let boundary = i == 0 || c[i - 1].is_whitespace() || is_path_term(c[i - 1]);
        if !boundary {
            out.push(c[i]);
            i += 1;
            continue;
        }
        // URL（`scheme://…`）整段跳过——主机名已由规则 2 处理。
        let mut k = i;
        while k < c.len() && (c[k].is_ascii_alphanumeric() || matches!(c[k], '+' | '.' | '-')) {
            k += 1;
        }
        if k > i && c[i].is_ascii_alphabetic() && c[k..].starts_with(&[':', '/', '/']) {
            while k < c.len() && !c[k].is_whitespace() && !matches!(c[k], '"' | '\'' | '?') {
                k += 1;
            }
            out.extend(&c[i..k]);
            i = k;
            continue;
        }
        match parse_path(&c, i) {
            Some((end, text)) => {
                out.push_str(&text);
                i = end;
            }
            None => {
                out.push(c[i]);
                i += 1;
            }
        }
    }
    out
}

/// 在 `i` 处尝试读一条路径；是路径就返回 (结束位置, 打码后的文本)。
fn parse_path(c: &[char], i: usize) -> Option<(usize, String)> {
    let mut j = i;
    let mut prefix = String::new();
    let mut absolute = false;
    // 盘符 `C:\`
    if j + 2 < c.len() && c[j].is_ascii_alphabetic() && c[j + 1] == ':' && sep_at(c, j + 2) {
        prefix.push(c[j]);
        prefix.push(':');
        j += 2;
        absolute = true;
    } else if c[j] == '~' && j + 1 < c.len() && sep_at(c, j + 1) {
        prefix.push('~');
        j += 1;
        absolute = true;
    }
    let mut segs: Vec<(String, Option<char>)> = Vec::new(); // (段, 段前的分隔符)
    let mut lead_sep = None;
    if j < c.len() && sep_at(c, j) {
        lead_sep = Some(c[j]);
        absolute = true;
        j += 1;
    }
    let mut sep_before = lead_sep;
    let mut seps = usize::from(lead_sep.is_some());
    loop {
        let end = read_segment(c, j);
        segs.push((c[j..end].iter().collect(), sep_before));
        j = end;
        if j < c.len() && sep_at(c, j) {
            sep_before = Some(c[j]);
            seps += 1;
            j += 1;
            continue;
        }
        break;
    }
    let last = &segs.last()?.0;
    let first = &segs.first()?.0;
    let placeholder_root = first.starts_with('<') && first.ends_with('>');
    let nonempty = segs.iter().any(|(s, _)| !s.is_empty());
    let accept = nonempty
        && if seps == 0 {
            has_media_ext(last)
        } else {
            absolute || placeholder_root || has_media_ext(last)
        };
    if !accept {
        return None;
    }
    let n = segs.len();
    let mut text = prefix;
    for (idx, (seg, sep)) in segs.iter().enumerate() {
        if let Some(sep) = sep {
            text.push(*sep);
        }
        text.push_str(&mask_segment(seg, idx + 1 == n));
    }
    Some((j, text))
}

/// 导出件里的 JSON 文本：逐个字符串值做 [`redact_export`]（字符串本身又是 JSON
/// 的——比如 audit 的 payload——递归处理），键不动。不是 JSON 就按普通文本处理。
/// 这样转义字符（`\"`、`\n`、`\\`）不会干扰按形状的判断。`pre` 是调用方先做的
/// 替换（库目录 / 家目录）。
pub fn redact_export_json_or_text(s: &str, pre: &dyn Fn(&str) -> String) -> String {
    fn walk(v: &mut serde_json::Value, pre: &dyn Fn(&str) -> String) {
        match v {
            serde_json::Value::String(x) => *x = redact_export_json_or_text(x, pre),
            serde_json::Value::Array(a) => a.iter_mut().for_each(|e| walk(e, pre)),
            serde_json::Value::Object(o) => o.values_mut().for_each(|e| walk(e, pre)),
            _ => {}
        }
    }
    let t = s.trim_start();
    if t.starts_with('{') || t.starts_with('[') || t.starts_with('"') {
        if let Ok(mut v) = serde_json::from_str::<serde_json::Value>(s) {
            walk(&mut v, pre);
            let out = if s.contains('\n') {
                serde_json::to_string_pretty(&v)
            } else {
                serde_json::to_string(&v)
            };
            if let Ok(out) = out {
                return out;
            }
        }
    }
    redact_export(&pre(s))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两个 workspace 共用的向量（桌面壳的拷贝跑同一份文件）。
    const VECTORS: &str = include_str!("../../../assets/privacy/redact-vectors.json");

    #[test]
    fn shared_vectors_hold() {
        let v: serde_json::Value = serde_json::from_str(VECTORS).expect("vectors json");
        let mut n = 0;
        for case in v["exact"].as_array().expect("exact[]") {
            let input = case["in"].as_str().unwrap();
            let want = case["out"].as_str().unwrap();
            assert_eq!(redact(input), want, "input: {input}");
            assert_eq!(redact(want), want, "not idempotent: {want}");
            n += 1;
        }
        for keep in v["keep"].as_array().expect("keep[]") {
            let s = keep.as_str().unwrap();
            assert_eq!(redact(s), s, "false positive");
            n += 1;
        }
        for case in v["export"].as_array().expect("export[]") {
            let input = case["in"].as_str().unwrap();
            let want = case["out"].as_str().unwrap();
            assert_eq!(redact_export(input), want, "export input: {input}");
            assert_eq!(redact_export(want), want, "export not idempotent: {want}");
            n += 1;
        }
        for keep in v["keep"].as_array().expect("keep[]") {
            let s = keep.as_str().unwrap();
            assert_eq!(redact_export(s), s, "export false positive");
        }
        assert!(n >= 40, "vector file shrank to {n} cases");
    }
}
