//! #548：Rust → logcat 出口（`android_logcat`）的统一脱敏（按值的形状，不按字段名）。
//!
//! iroh 的 tracing 事件会带对端 / 本机公网地址（`remote_addr=Ip(…)`、`network_path=…`）、
//! 自建 relay 域名、NodeId 等。`android_logcat` 把每一行写进 logcat 之前都过 [`logcat_line`]
//! （先 [`redact`] 再截断——反过来截断可能切坏一个 IP / hex 串，让它逃过识别）。
//!
//! **这是第三份拷贝**：正本在 `crates/daemon/src/redact.rs`（daemon 的日志写入器 `log_guard`
//! 落盘前用它）。transport 不能依赖 daemon（依赖方向是 daemon → transport），所以复制日志
//! 写入器用到的 `redact()`（规则 0–4）；导出件专用的路径 / 文件名规则（`redact_export`）不属于
//! 日志口径，没有复制。四份实现（daemon、桌面壳、本文件、Android Kotlin 的
//! `apps/android/.../log/Redact.kt`）都跑 `assets/privacy/redact-vectors.json`，靠它锁死不漂移。
//! 改一处就改全部。
//!
//! 规则按顺序（与正本同文）：
//! 0. **十进制字节数组**：≥16 个 0..=255 的整数组成的方括号列表换成 `[<bytes:N>]`。
//! 1. **IP 地址**：公网 IPv4 / IPv6 换成 `<ipv4:public>` / `<ipv6:public>`，端口保留；私网、回环、
//!    链路本地、CGNAT、未指定地址原样保留。分类器**默认判公网**。
//! 2. **URL 主机名**：不在白名单（`iroh.link`、`github.com`）就换成 `<host>`。
//! 3. **长不透明串**：`[A-Za-z0-9_-]`、长度 ≥32、含 ≥2 个数字和 ≥8 个字母的连续串只留前 8 位。
//! 4. **长 hex 串**（≥24 位连续 hex）只留前 8 位。

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

/// logcat 出口的一行：`target:fields`，先脱敏、再按字节上限截断（落在字符边界上）。
pub fn logcat_line(target: &str, fields: &str, max_bytes: usize) -> String {
    let mut line = redact(&format!("{target}:{fields}"));
    if line.len() > max_bytes {
        let mut end = max_bytes;
        while !line.is_char_boundary(end) {
            end -= 1;
        }
        line.truncate(end);
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 与 daemon / 桌面壳 / Android 共用的向量。日志口径只跑 exact + keep。
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
        assert!(n >= 40, "vector file shrank to {n} log cases");
    }

    /// 反证：把 [`logcat_line`] 里的 `redact` 撤掉，本测试红。
    #[test]
    fn logcat_line_is_redacted_before_it_is_written() {
        let fields = " connecting remote_addr=Ip(203.0.113.7:4433) \
            network_path=Ip(10.0.0.5->[2001:db8::1]:54560) \
            relay=https://relay.family-example.org./ \
            peer=ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c";
        let line = logcat_line("iroh::socket", fields, 3500);
        for raw in [
            "203.0.113.7",
            "2001:db8::1",
            "relay.family-example.org",
            "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c",
        ] {
            assert!(!line.contains(raw), "`{raw}` leaked: {line}");
        }
        assert_eq!(
            line,
            "iroh::socket: connecting remote_addr=Ip(<ipv4:public>:4433) \
             network_path=Ip(10.0.0.5->[<ipv6:public>]:54560) \
             relay=https://<host>/ peer=ea4a6c63…<masked>"
        );
    }

    #[test]
    fn logcat_line_truncates_after_redaction_on_a_char_boundary() {
        // 截断点落在公网 IP 中间：先截断会留下 `203.0.11` 这种不再被识别的残片。
        let fields = format!(" {} 203.0.113.7 tail", "x".repeat(10));
        let line = logcat_line("t", &fields, 21);
        assert!(!line.contains("203.0"), "{line}");
        let cjk = logcat_line("t", " 张三", 4);
        assert!(cjk.len() <= 4, "{cjk}");
        assert_eq!(cjk, "t: ");
    }
}
