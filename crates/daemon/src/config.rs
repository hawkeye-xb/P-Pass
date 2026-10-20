//! Daemon configuration (T-004).
//!
//! Three-layer precedence, lowest to highest:
//! 1. compiled-in defaults (official endpoints from `config/endpoints.default.toml`)
//! 2. user `config.toml`
//! 3. `PPF_*` environment variables
//!
//! 隔离方案 §2: official endpoints are public constants baked into the
//! binary; every one of them can be overridden by self-hosters.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::Context;
use serde::Deserialize;

/// Official endpoint defaults, embedded at compile time.
const ENDPOINTS_DEFAULT: &str = include_str!("../../../config/endpoints.default.toml");

/// Fully resolved daemon configuration.
#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// Library root. `None` = let the platform adapter pick the
    /// OS-conventional data dir (T-040).
    pub data_dir: Option<PathBuf>,
    /// UDP bind address, e.g. `0.0.0.0:41145`. `None` = OS-assigned port.
    /// Cloud/dogfood deployments pin this to the firewall-allowed port.
    pub bind_addr: Option<std::net::SocketAddr>,
    pub relay_urls: Vec<String>,
}

/// Partial overlay as read from `config.toml` — every field optional.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Overlay {
    data_dir: Option<PathBuf>,
    bind_addr: Option<std::net::SocketAddr>,
    relay_urls: Option<Vec<String>>,
    /// #1041 兼容字段：`rendezvous_url` 没有任何读者（配对短码会合服务从未接线），
    /// 旧版示例配置与自建文档却教用户写过它；`log_level` 同理（日志级别一直只认
    /// `RUST_LOG`）。`deny_unknown_fields` 会把它们当未知字段拒掉、daemon 起不来，
    /// 所以**接收并忽略**（`IgnoredAny`：任何形状都吃下、不读取）。
    /// 对应的环境变量 `PPF_RENDEZVOUS_URL` / `PPF_LOG_LEVEL` 不再被读取（同样是静默忽略）。
    /// 下一个破坏性版本再删。反证：去掉这两个字段，`retired_config_fields_are_accepted_and_ignored` 必红。
    #[serde(rename = "rendezvous_url")]
    _retired_rendezvous_url: Option<serde::de::IgnoredAny>,
    #[serde(rename = "log_level")]
    _retired_log_level: Option<serde::de::IgnoredAny>,
    /// #949 兼容字段：遥测上报已下线，但已装桌面用户的 config.toml 里都有
    /// 首启写入的 `[telemetry]` 段（`enabled = false`，个别还带 `url`）。
    /// `deny_unknown_fields` 会把它当未知字段拒掉、daemon 起不来，所以这里
    /// **接收并忽略**整段内容（`IgnoredAny`：任何形状都吃下、不读取）。
    /// 不要删——删了旧用户升级后 config 加载失败。
    #[serde(rename = "telemetry")]
    _legacy_telemetry: Option<serde::de::IgnoredAny>,
}

impl Config {
    /// Compiled-in defaults (layer 1).
    pub fn default_config() -> anyhow::Result<Config> {
        let overlay: Overlay = toml::from_str(ENDPOINTS_DEFAULT)
            .context("built-in endpoints.default.toml is invalid")?;
        Ok(Config {
            data_dir: None,
            bind_addr: None,
            relay_urls: overlay.relay_urls.unwrap_or_default(),
        })
    }

    /// Load with full precedence from an optional config file and the
    /// process environment.
    pub fn load(config_path: Option<&Path>) -> anyhow::Result<Config> {
        let file_toml = match config_path {
            Some(p) if p.exists() => Some(
                std::fs::read_to_string(p).with_context(|| format!("reading {}", p.display()))?,
            ),
            _ => None,
        };
        let env: HashMap<String, String> = std::env::vars().collect();
        Self::resolve(file_toml.as_deref(), &env)
    }

    /// Pure resolution — testable without touching process env or disk.
    pub fn resolve(
        config_toml: Option<&str>,
        env: &HashMap<String, String>,
    ) -> anyhow::Result<Config> {
        // Layer 1: defaults.
        let mut cfg = Self::default_config()?;

        // Layer 2: config.toml overlay.
        if let Some(raw) = config_toml {
            let overlay: Overlay = toml::from_str(raw).context("parsing config.toml")?;
            if let Some(v) = overlay.data_dir {
                cfg.data_dir = Some(v);
            }
            if let Some(v) = overlay.bind_addr {
                cfg.bind_addr = Some(v);
            }
            if let Some(v) = overlay.relay_urls {
                cfg.relay_urls = v;
            }
        }

        // Layer 3: PPF_* environment variables (highest precedence).
        if let Some(v) = env.get("PPF_DATA_DIR") {
            cfg.data_dir = Some(PathBuf::from(v));
        }
        if let Some(v) = env.get("PPF_BIND_ADDR") {
            cfg.bind_addr =
                Some(v.parse().map_err(|e| {
                    anyhow::anyhow!("PPF_BIND_ADDR 不是合法的 IP:端口（{v}）：{e}")
                })?);
        }
        if let Some(v) = env.get("PPF_RELAY_URLS") {
            cfg.relay_urls = v
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }

        Ok(cfg)
    }
}

// ══ #1042：config 的唯一写者（首启模板 + 换库）══════════════════════
//
// 原先长在桌面壳 `apps/desktop/src-tauri/src/lib.rs`（render_config /
// write_first_run_config / set_library_dir / merge_library_dir …），daemon
// 只读。S3 拍板：core 是 config 的唯一写者，经 CLI 子命令
// （`config init --library` / `config set-library`）对外提供，壳改调由 #1045
// 完成。下面逐行平移壳的现行实现——**行为与壳逐字节一致**是验收标准 5，
// 由 `tests/config_cli.rs` 拿壳代码跑出的 golden 钉住；已知怪癖（例如合并
// 时按 `starts_with("data_dir")` 过滤行、空文档合并多一个换行）一并保留，
// 改它们属于行为变更，不在本卡。

/// 桌面首启模板写进 config.toml 的固定监听地址。
///
/// 为什么不是 [`Config::default_config`] 的默认值：运行时默认仍是 `None`
/// （系统分配端口）——场景脚本、自建 / 无 config 的部署都依赖它；改成固定
/// 端口是用户可见变化，#1042 没写。两者的分工是：**运行时**缺省 = 不固定；
/// **桌面首启**写入 = 固定 41145（手机存的回连地址跨服务重启依然有效，
/// 真机教训）。这个值从此只在这里有一份。
pub const DESKTOP_BIND_ADDR: &str = "0.0.0.0:41145";

/// 平台 config 文件名（`<平台数据目录>/config.toml`）。
pub const CONFIG_FILE_NAME: &str = "config.toml";

/// 会回到桌面前端展示的错误：`{"key":"ui.err_…","params":{…}}`，与壳
/// `ipc::ui_err` 同一线上格式（I18N-03 #492），#1045 可以原样转交前端的
/// `errText` 渲染。参数值一律字符串化、不翻译。
fn ui_err(key: &str, params: &[(&str, &dyn std::fmt::Display)]) -> String {
    let params: serde_json::Map<String, serde_json::Value> = params
        .iter()
        .map(|(k, v)| ((*k).to_string(), serde_json::Value::String(v.to_string())))
        .collect();
    serde_json::json!({ "key": key, "params": params }).to_string()
}

/// DESK-26 (#209)：TOML basic string 的反转义（只认 `\\ \" \n \r \t`，
/// 不认识的转义原样吐回）。与 [`read_config_data_dir`] 配对。
fn unescape_toml_basic(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('\\') => out.push('\\'),
            Some('"') => out.push('"'),
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// 读 `<platform_dir>/config.toml` 里的 `data_dir`（逐行，第一条以
/// `data_dir` 开头的行定胜负）。
///
/// 刻意**不**走 [`Config::load`]：后者带 `deny_unknown_fields`，config 里
/// 有一个不认识的键就整份失败——而换库只需要知道「当前库在哪」，壳的
/// 现行行为是照样能换。双引号值反转义（DESK-26 #209），单引号 / 裸值原样。
pub fn read_config_data_dir(platform_dir: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(platform_dir.join(CONFIG_FILE_NAME)).ok()?;
    for line in raw.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("data_dir") {
            let rest = rest.trim_start();
            if let Some(val) = rest.strip_prefix('=') {
                let val = val.trim();
                let val = match val.strip_prefix('"').and_then(|v| v.strip_suffix('"')) {
                    Some(inner) => unescape_toml_basic(inner),
                    None => val.trim_matches('\'').to_string(),
                };
                let val = val.trim();
                if !val.is_empty() {
                    return Some(val.to_string());
                }
            }
            break;
        }
    }
    None
}

/// DESK-27 (#219)：已配置的库目录，读回后先归一（存量翻倍过的路径
/// 立刻显示成对的）。向导预填与换库的「当前库」都走这一条。
pub fn configured_library_dir(platform_dir: &Path) -> Option<String> {
    read_config_data_dir(platform_dir).map(|v| normalize_separators(&v))
}

/// DESK-27 (#219)：重复反斜杠折回单个，**但保住前导的那一对**（UNC
/// `\\server\share` / verbatim `\\?\C:\x` 的前导两个分隔符是语义）。
/// 不用 `Path::components()`：它会把翻倍过的 UNC 折成单前导，指向别处。
/// 无反斜杠的路径（macOS / Linux）是恒等变换。
pub fn normalize_separators(p: &str) -> String {
    const SEP: char = '\\';
    let leading = p.chars().take_while(|&c| c == SEP).count();
    let mut out = String::with_capacity(p.len());
    match leading {
        0 => {}
        1 => out.push(SEP),
        _ => {
            out.push(SEP);
            out.push(SEP);
        }
    }
    let mut prev_sep = false;
    for ch in p[leading..].chars() {
        if ch == SEP {
            if !prev_sep {
                out.push(ch);
            }
            prev_sep = true;
        } else {
            out.push(ch);
            prev_sep = false;
        }
    }
    out
}

/// 路径值的 TOML 表示：先归一，再按 TOML 规则序列化——不拿 `{:?}` 冒充
/// （DESK-27）。
fn toml_path_value(library_dir: &str) -> String {
    toml_string_repr(&normalize_separators(library_dir))
}

/// TOML 字符串的**冻结**写法：逐行平移自桌面壳现行依赖 `toml_edit 0.20.2`
/// 的 `encode::infer_style` + `to_string_repr`（壳经 `toml 0.8.2` 的
/// `Value::to_string()` 走的就是它）。
///
/// 为什么不直接调 `toml::Value::to_string()`：daemon workspace 锁的是
/// `toml 0.8.23`（`toml_edit 0.22`），同时含 `'` 与 `"` 的路径会被写成
/// `"""…"""` 多行串（golden 测试实测抓到）。那既不逐字节等于壳，也会被
/// 逐行读取方（[`read_config_data_dir`]，只认单行的 basic / literal 串）
/// 读错。config 是长期留在用户磁盘上的文件格式，写法不能随依赖升级漂移，
/// 所以冻结在这里，由 `tests/config_cli.rs` 的 golden 钉住。
///
/// 规则：含反斜杠、且能用 literal 表示（无控制字符、无连续三个单引号、
/// 不以单引号结尾）⇒ literal（无单引号用单引号括起，有单引号用三单引号，
/// 含换行时三单引号后先换行）；否则 ⇒ basic 双引号串（含换行用三双引号），
/// 转义 b / t / f / r / 双引号 / 反斜杠，其余控制字符写成 `\uXXXX`。
fn toml_string_repr(value: &str) -> String {
    #[derive(PartialEq)]
    enum Style {
        NewlineTriple,
        OnelineTriple,
        OnelineSingle,
    }
    // ── infer_style ──
    let mut ty = Style::OnelineSingle;
    let mut max_found_singles = 0;
    let mut found_singles = 0;
    let mut prefer_literal = false;
    let mut can_be_pretty = true;
    for ch in value.chars() {
        if can_be_pretty {
            if ch == '\'' {
                found_singles += 1;
                if found_singles >= 3 {
                    can_be_pretty = false;
                }
            } else {
                if found_singles > max_found_singles {
                    max_found_singles = found_singles;
                }
                found_singles = 0
            }
            match ch {
                '\t' => {}
                '\\' => prefer_literal = true,
                '\n' => ty = Style::NewlineTriple,
                c if c <= '\u{1f}' || c == '\u{7f}' => can_be_pretty = false,
                _ => {}
            }
        } else if ch == '\n' {
            ty = Style::NewlineTriple;
        }
    }
    if found_singles > 0 && value.ends_with('\'') {
        can_be_pretty = false;
    }
    if !prefer_literal {
        can_be_pretty = false;
    }
    let literal = if can_be_pretty {
        if found_singles > max_found_singles {
            max_found_singles = found_singles;
        }
        if ty == Style::OnelineSingle && max_found_singles >= 1 {
            ty = Style::OnelineTriple;
        }
        true
    } else {
        false
    };
    // ── to_string_repr ──
    let mut out = String::with_capacity(value.len() * 2);
    if literal {
        let (start, end) = match ty {
            Style::NewlineTriple => ("'''\n", "'''"),
            Style::OnelineTriple => ("'''", "'''"),
            Style::OnelineSingle => ("'", "'"),
        };
        out.push_str(start);
        out.push_str(value);
        out.push_str(end);
    } else {
        let (start, end) = match ty {
            Style::NewlineTriple => ("\"\"\"\n", "\"\"\""),
            Style::OnelineTriple | Style::OnelineSingle => ("\"", "\""),
        };
        out.push_str(start);
        for ch in value.chars() {
            match ch {
                '\u{8}' => out.push_str("\\b"),
                '\u{9}' => out.push_str("\\t"),
                // basic 串只会在 NewlineTriple 下遇到换行（OnelineTriple
                // 只出现在 literal 分支），原样写入。
                '\u{a}' => out.push('\n'),
                '\u{c}' => out.push_str("\\f"),
                '\u{d}' => out.push_str("\\r"),
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                c if c <= '\u{1f}' || c == '\u{7f}' => {
                    out.push_str(&format!("\\u{:04X}", c as u32));
                }
                c => out.push(c),
            }
        }
        out.push_str(end);
    }
    out
}

/// DESK-27 (#219)：首启向导写入的整份 config.toml。
pub fn render_first_run_config(library_dir: &str) -> String {
    let data_dir_value = toml_path_value(library_dir);
    format!(
        "data_dir = {data_dir_value}

# 固定端口：手机存的回连地址跨服务重启依然有效（真机教训）。
bind_addr = \"{DESKTOP_BIND_ADDR}\"

# H-07 部署前必须为空（内置官方 relay 域名尚未上线）
relay_urls = []
"
    )
}

/// DESK-46 (#638)：把 data_dir 换进既有 config 文本——**只改 data_dir 一行，
/// 其余逐字节保留**。新键插在文首（顶层键必须落在第一个 `[section]` 之前，
/// 2026-07-31 crash-loop 教训）。
pub fn merge_library_dir(doc: &str, library_dir: &str) -> String {
    let data_dir_value = toml_path_value(library_dir);
    let body: String = doc
        .lines()
        .filter(|l| !l.trim_start().starts_with("data_dir"))
        .collect::<Vec<_>>()
        .join("\n");
    format!("data_dir = {data_dir_value}\n{body}\n")
}

/// DESK-46 (#638)：两个路径是否相同或一方包含另一方（纯字符串判据）。
/// 分隔符两种都认、结尾分隔符先剥、大小写不敏感；前缀必须断在分隔符
/// 边界上（`/old/lib2` 不是 `/old/lib` 的子目录）。
pub fn paths_overlap(a: &str, b: &str) -> bool {
    let norm = |p: &str| {
        p.trim_end_matches(['/', '\\'])
            .replace('\\', "/")
            .to_lowercase()
    };
    let (a, b) = (norm(a), norm(b));
    if a == b {
        return true;
    }
    let contains = |outer: &str, inner: &str| {
        outer.len() > inner.len()
            && outer.starts_with(inner)
            && outer.as_bytes()[inner.len()] == b'/'
    };
    contains(&a, &b) || contains(&b, &a)
}

/// DESK-46 (#638)：换库目标的三条校验（存在、可写、不嵌套）。纯函数——
/// 文件系统事实由调用点探测后传入。错误是 keyed ui_err。
pub fn library_target_verdict(
    target: &str,
    current: Option<&str>,
    target_is_dir: bool,
    target_writable: bool,
) -> Result<(), String> {
    if target.trim().is_empty() || !target_is_dir {
        return Err(ui_err("ui.err_library_target_missing", &[("dir", &target)]));
    }
    if !target_writable {
        return Err(ui_err(
            "ui.err_library_target_readonly",
            &[("dir", &target)],
        ));
    }
    if let Some(cur) = current {
        if paths_overlap(cur, target) {
            return Err(ui_err("ui.err_library_nested", &[]));
        }
    }
    Ok(())
}

/// DESK-46 (#638)：可写探测——真建一个临时文件再删掉（ACL、只读挂载、
/// 沙箱限制都不体现在权限位里）。
fn dir_writable(p: &Path) -> bool {
    if !p.is_dir() {
        return false;
    }
    let probe = p.join(format!(".ppf-write-probe-{}", std::process::id()));
    match std::fs::File::create(&probe) {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// DESK-57 (#871)：首启写配置。库目录在这里建，建不出来就如实报错、
/// **不写配置**（daemon 对「显式配置却不存在」的库拒绝启动，DESK-46）。
/// 顺序：库目录 → 平台目录 → 写文件。错误串与壳现行一致：建库失败是
/// `"<库目录>: <io 错误>"`，其余是 io 错误原文。
pub fn init_config(platform_dir: &Path, library_dir: &str) -> Result<PathBuf, String> {
    std::fs::create_dir_all(library_dir).map_err(|e| format!("{library_dir}: {e}"))?;
    std::fs::create_dir_all(platform_dir).map_err(|e| e.to_string())?;
    let cfg_path = platform_dir.join(CONFIG_FILE_NAME);
    std::fs::write(&cfg_path, render_first_run_config(library_dir)).map_err(|e| e.to_string())?;
    Ok(cfg_path)
}

/// DESK-46 (#638)：更改照片库位置——平台 config.toml 的 read-modify-write。
/// 顺序：先校验（不碰盘），再写入，最后清理旧库里的孤儿 config.toml。
/// 生效时机不变：daemon 只在启动时读一次 config，重启后台服务后生效。
pub fn set_library(platform_dir: &Path, library_dir: &str) -> Result<PathBuf, String> {
    let cfg_path = platform_dir.join(CONFIG_FILE_NAME);
    let current = configured_library_dir(platform_dir);
    let target = Path::new(library_dir);
    library_target_verdict(
        library_dir,
        current.as_deref(),
        target.is_dir(),
        dir_writable(target),
    )?;
    rewrite_library_dir(&cfg_path, library_dir)?;
    // 孤儿清理：folder.set 时代留在旧库目录里的 config.toml 没有任何读者。
    // 与平台 config 是同一个文件（库 == 平台目录）则跳过——canonicalize
    // 两边都落到磁盘真实路径再比。
    if let Some(old) = current {
        let orphan = Path::new(&old).join(CONFIG_FILE_NAME);
        let same_file = match (orphan.canonicalize(), cfg_path.canonicalize()) {
            (Ok(a), Ok(b)) => a == b,
            _ => false,
        };
        if !same_file && orphan.is_file() {
            let _ = std::fs::remove_file(&orphan);
        }
    }
    Ok(cfg_path)
}

/// DESK-49 (#710)：读失败分两档——不存在 ⇒ 当空配置；其它读错误
/// （权限 / 非 UTF-8 / IO）⇒ 如实报错、**不写文件**。
fn rewrite_library_dir(cfg_path: &Path, library_dir: &str) -> Result<(), String> {
    let doc = match std::fs::read_to_string(cfg_path) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(ui_err("ui.err_set_library", &[("err", &e)])),
    };
    let merged = merge_library_dir(&doc, library_dir);
    std::fs::write(cfg_path, merged).map_err(|e| ui_err("ui.err_set_library", &[("err", &e)]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn layer1_defaults_have_official_endpoints() {
        let cfg = Config::resolve(None, &env(&[])).unwrap();
        // relay_urls 默认空（2026-07-31 用户裁决）：H-07 部署前官方 relay 域名
        // 不存在，会毒害路径协商（dogfood 实证）；H-07 上线后恢复三区域列表
        // （见 config/endpoints.default.toml 注释）。
        assert!(cfg.relay_urls.is_empty());
        assert_eq!(cfg.data_dir, None);
    }

    #[test]
    fn layer2_file_overrides_defaults_partially() {
        let file = r#"
            data_dir = "/tmp/lib"
            relay_urls = ["https://relay.self-host.example"]
        "#;
        let cfg = Config::resolve(Some(file), &env(&[])).unwrap();
        assert_eq!(cfg.data_dir, Some(PathBuf::from("/tmp/lib")));
        assert_eq!(cfg.relay_urls, vec!["https://relay.self-host.example"]);
    }

    #[test]
    fn layer3_env_overrides_file_and_defaults() {
        let file = r#"
            relay_urls = ["https://from-file.example"]
        "#;
        let e = env(&[
            ("PPF_BIND_ADDR", "0.0.0.0:41145"),
            ("PPF_RELAY_URLS", "https://a.example, https://b.example"),
            ("PPF_DATA_DIR", "/env/dir"),
        ]);
        let cfg = Config::resolve(Some(file), &e).unwrap();
        assert_eq!(
            cfg.relay_urls,
            vec!["https://a.example", "https://b.example"]
        );
        assert_eq!(cfg.data_dir, Some(PathBuf::from("/env/dir")));
        assert_eq!(
            cfg.bind_addr,
            Some("0.0.0.0:41145".parse().unwrap()),
            "PPF_BIND_ADDR 必须生效"
        );
    }

    /// #949 E2：遥测已下线，但旧版 config.toml 里的 `[telemetry]` 段（桌面
    /// 首启写入的 `enabled = false`，或手工改过的 `enabled = true` + `url`）
    /// 必须照常加载、不报 unknown field，且不影响其它字段。
    /// 反证：从 `Overlay` 删掉 `_legacy_telemetry`，本测试必须红。
    #[test]
    fn legacy_telemetry_section_is_accepted_and_ignored() {
        for legacy in [
            "[telemetry]\nenabled = false\n",
            "[telemetry]\nenabled = true\nurl = \"https://telemetry.example.com/ingest\"\n",
            "[telemetry]\nenabled = false\nurl = \"https://telemetry.example.com\"\n",
        ] {
            let file = format!(
                "data_dir = \"/old/library\"\nbind_addr = \"0.0.0.0:41145\"\nrelay_urls = []\n\n{legacy}"
            );
            let cfg = Config::resolve(Some(&file), &env(&[]))
                .unwrap_or_else(|e| panic!("旧 config 必须能加载：{e:#}\n{file}"));
            assert_eq!(cfg.data_dir, Some(PathBuf::from("/old/library")));
            assert_eq!(cfg.bind_addr, Some("0.0.0.0:41145".parse().unwrap()));
            assert!(cfg.relay_urls.is_empty());
        }
    }

    /// #1041 E2：`rendezvous_url` / `log_level` 已退役（没有读者），但旧版
    /// config.toml（示例配置、自建文档都教过写）里带着它们必须照常启动，且
    /// 不影响其它字段；对应 `PPF_*` 环境变量同样被忽略。
    /// 反证：从 `Overlay` 删掉 `_retired_*` 两个字段，本测试必须红。
    #[test]
    fn retired_config_fields_are_accepted_and_ignored() {
        let file = r#"
            data_dir = "/old/library"
            bind_addr = "0.0.0.0:41145"
            relay_urls = ["https://relay.old.example"]
            rendezvous_url = "https://rendezvous.example.com"
            log_level = "debug"
        "#;
        let e = env(&[
            ("PPF_LOG_LEVEL", "trace"),
            ("PPF_RENDEZVOUS_URL", "https://env.example"),
        ]);
        let cfg = Config::resolve(Some(file), &e)
            .unwrap_or_else(|e| panic!("旧 config 必须能加载：{e:#}"));
        assert_eq!(cfg.data_dir, Some(PathBuf::from("/old/library")));
        assert_eq!(cfg.bind_addr, Some("0.0.0.0:41145".parse().unwrap()));
        assert_eq!(cfg.relay_urls, vec!["https://relay.old.example"]);
        // 与不带这两个字段的 config 解析结果逐字段相同 = 「不生效」。
        let without = r#"
            data_dir = "/old/library"
            bind_addr = "0.0.0.0:41145"
            relay_urls = ["https://relay.old.example"]
        "#;
        assert_eq!(cfg, Config::resolve(Some(without), &env(&[])).unwrap());
    }

    /// 内置默认值不再带 `[telemetry]` 段（#949）。
    #[test]
    fn builtin_defaults_carry_no_telemetry_section() {
        let raw: toml::Value = toml::from_str(ENDPOINTS_DEFAULT).unwrap();
        assert!(raw.get("telemetry").is_none(), "{ENDPOINTS_DEFAULT}");
    }

    #[test]
    fn unknown_file_field_is_rejected() {
        let err = Config::resolve(Some("no_such_field = 1"), &env(&[])).unwrap_err();
        assert!(err.to_string().contains("parsing config.toml"));
    }

    // ══ #1042：从桌面壳平移的 DESK-27 / 46 / 49 / 57 用例（语义不变）══

    #[test]
    fn desk27_a_healthy_path_is_untouched() {
        for p in [
            "C:\\Users\\ethan\\Pictures",
            "C:\\",
            "relative\\sub",
            "/unix/style",
        ] {
            assert_eq!(normalize_separators(p), p, "健康路径被改动了: {p}");
        }
    }

    #[test]
    fn desk27_any_number_of_doublings_converges() {
        let want = "C:\\Users\\ethan\\Pictures";
        for p in [
            "C:\\\\Users\\\\ethan\\\\Pictures",
            "C:\\\\\\\\Users\\\\\\\\ethan\\\\\\\\Pictures",
            "C:\\\\\\\\\\\\\\\\Users\\\\\\\\\\\\\\\\ethan\\\\\\\\\\\\\\\\Pictures",
        ] {
            assert_eq!(normalize_separators(p), want, "没收敛: {p}");
        }
    }

    #[test]
    fn desk27_unc_and_verbatim_prefixes_keep_their_leading_pair() {
        assert_eq!(
            normalize_separators("\\\\server\\share\\dir"),
            "\\\\server\\share\\dir"
        );
        assert_eq!(
            normalize_separators("\\\\?\\C:\\Users\\x"),
            "\\\\?\\C:\\Users\\x"
        );
        assert_eq!(
            normalize_separators("\\\\\\\\server\\\\share\\\\dir"),
            "\\\\server\\share\\dir"
        );
        assert_eq!(
            normalize_separators("\\\\\\\\?\\\\C:\\\\Users\\\\x"),
            "\\\\?\\C:\\Users\\x"
        );
        assert_eq!(normalize_separators("\\Users\\x"), "\\Users\\x");
    }

    #[test]
    fn desk27_normalization_is_idempotent() {
        for p in [
            "C:\\Users\\x",
            "C:\\\\Users\\\\x",
            "C:\\\\\\\\Users\\\\\\\\x",
            "\\\\server\\share",
            "\\\\\\\\server\\\\share",
            "\\\\?\\C:\\x",
            "\\Users\\x",
            "no-separators-at-all",
            "",
        ] {
            let once = normalize_separators(p);
            let twice = normalize_separators(&once);
            assert_eq!(once, twice, "不幂等: {p} -> {once} -> {twice}");
        }
    }

    #[test]
    fn desk27_paths_without_backslashes_are_identity() {
        for p in [
            "/home/ethan/Pictures/P-Pass",
            "/Users/ethan/Pictures/P-Pass 家庭照片库",
            "relative/path",
        ] {
            assert_eq!(normalize_separators(p), p);
        }
    }

    /// DESK-57 (#871)：库目录不存在 ⇒ 写配置时建出来。
    /// 反证：去掉 `init_config` 里建库目录那一行，本测试变红。
    #[test]
    fn desk57_first_run_creates_missing_library_then_writes_config() {
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("platform");
        let library = tmp.path().join("Pictures").join("P-Pass 家庭照片库");
        assert!(!library.exists());

        init_config(&platform_dir, library.to_str().unwrap()).unwrap();

        assert!(library.is_dir(), "库目录应在写配置时被建出来");
        let cfg = std::fs::read_to_string(platform_dir.join("config.toml")).unwrap();
        assert_eq!(
            configured_library_dir(&platform_dir).as_deref(),
            library.to_str(),
            "{cfg}"
        );
    }

    /// DESK-57 (#871)：库目录建不出来 ⇒ 报错（点名目录），且不写配置。
    #[test]
    fn desk57_uncreatable_library_errors_without_writing_config() {
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("platform");
        let blocker = tmp.path().join("not-a-dir");
        std::fs::write(&blocker, b"file").unwrap();
        let library = blocker.join("P-Pass 家庭照片库");

        let err = init_config(&platform_dir, library.to_str().unwrap()).unwrap_err();

        assert!(
            err.contains("P-Pass 家庭照片库"),
            "错误要点名是哪个目录：{err}"
        );
        assert!(
            !platform_dir.join("config.toml").exists(),
            "建库失败时不得写配置"
        );
    }

    /// DESK-27 (#219)：连续三轮「读回 → 预填归一 → 渲染 → 写盘」，字节数
    /// 必须相同；起点是真机损坏态（每个分隔符四个反斜杠），同时覆盖存量修复。
    #[test]
    fn desk27_three_wizard_rounds_are_byte_identical_and_repair_legacy() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");
        let legacy = format!(
            "data_dir = \"C:{s}{s}{s}{s}Users{s}{s}{s}{s}ethan{s}{s}{s}{s}Pictures\"\n",
            s = '\\'
        );
        std::fs::write(&cfg, &legacy).unwrap();
        let legacy_backslashes = std::fs::read(&cfg)
            .unwrap()
            .iter()
            .filter(|&&b| b == b'\\')
            .count();
        assert_eq!(legacy_backslashes, 12, "起点应当是损坏态（12 个 0x5C）");

        let mut rounds = Vec::new();
        let mut prefills = Vec::new();
        for _ in 0..3 {
            let prefill = configured_library_dir(dir.path()).expect("读不到 data_dir");
            prefills.push(prefill.clone());
            std::fs::write(&cfg, render_first_run_config(&prefill)).unwrap();
            let bytes = std::fs::read(&cfg).unwrap();
            let n = bytes.iter().filter(|&&b| b == b'\\').count();
            let parsed: toml::Value =
                toml::from_str(&String::from_utf8(bytes).unwrap()).expect("必须是合法 TOML");
            rounds.push((n, parsed["data_dir"].as_str().unwrap().to_string()));
        }
        assert_eq!(
            rounds[0].0, rounds[1].0,
            "第 1→2 轮反斜杠数变了: {rounds:?}"
        );
        assert_eq!(
            rounds[1].0, rounds[2].0,
            "第 2→3 轮反斜杠数变了: {rounds:?}"
        );
        let want = format!("C:{s}Users{s}ethan{s}Pictures", s = '\\');
        for (i, (_, v)) in rounds.iter().enumerate() {
            assert_eq!(v, &want, "第 {} 轮的 data_dir 不是归一值", i + 1);
        }
        for (i, v) in prefills.iter().enumerate() {
            assert_eq!(v, &want, "第 {} 轮向导预填的不是归一值", i + 1);
        }
    }

    /// DESK-27：产出必须是真 TOML，读回等于归一后的路径。刻意走
    /// `render_first_run_config`——去掉归一那步本测试必须红。
    #[test]
    fn desk27_rendered_config_round_trips_and_is_normalized() {
        let want = "C:\\Users\\ethan\\Pictures\\P-Pass 家庭照片库";
        for input in [
            want,
            "C:\\\\Users\\\\ethan\\\\Pictures\\\\P-Pass 家庭照片库",
            "C:\\\\\\\\Users\\\\\\\\ethan\\\\\\\\Pictures\\\\\\\\P-Pass 家庭照片库",
        ] {
            let doc = render_first_run_config(input);
            let parsed: toml::Value = toml::from_str(&doc)
                .unwrap_or_else(|e| panic!("产出的不是合法 TOML: {e} / doc={doc}"));
            assert_eq!(
                parsed["data_dir"].as_str().unwrap(),
                want,
                "没把 {input} 归一"
            );
        }
        for input in [
            "\\\\server\\share\\dir",
            "\\\\\\\\server\\\\share\\\\dir",
            "C:\\Users\\O'Brien\\Pics",
            "C:\\Users\\say \"hi\"\\Pics",
            "/Users/ethan/Pictures/P-Pass 家庭照片库",
            "/home/ethan/Pictures/P-Pass",
        ] {
            let doc = render_first_run_config(input);
            let parsed: toml::Value =
                toml::from_str(&doc).unwrap_or_else(|e| panic!("不是合法 TOML: {e}"));
            assert_eq!(
                parsed["data_dir"].as_str().unwrap(),
                normalize_separators(input),
                "往返后值变了: {input}"
            );
        }
    }

    /// 首启模板与运行时解析的关系：模板写死的 bind_addr 就是
    /// [`DESKTOP_BIND_ADDR`]，daemon 读回来生效；而没有 config 时运行时
    /// 默认仍是 `None`（不固定端口）——两者分工见常量注释。
    #[test]
    fn first_run_template_pins_the_desktop_port_and_parses() {
        let doc = render_first_run_config("/lib");
        let cfg = Config::resolve(Some(&doc), &env(&[])).expect("模板必须能被 daemon 读");
        assert_eq!(cfg.bind_addr, Some(DESKTOP_BIND_ADDR.parse().unwrap()));
        assert_eq!(DESKTOP_BIND_ADDR, "0.0.0.0:41145");
        assert!(cfg.relay_urls.is_empty());
        assert!(!doc.contains("telemetry"), "{doc}");
        assert_eq!(Config::resolve(None, &env(&[])).unwrap().bind_addr, None);
    }

    #[test]
    fn desk46_merge_replaces_data_dir_and_keeps_everything_else() {
        let doc = "data_dir = \"/old/library\"\n\n# 固定端口\nbind_addr = \"0.0.0.0:41145\"\n\nrelay_urls = []\n\n[telemetry]\nenabled = false\n";
        let out = merge_library_dir(doc, "/Volumes/My Passport");
        let parsed: toml::Value = toml::from_str(&out).expect("merge 产物必须是合法 TOML");
        assert_eq!(parsed["data_dir"].as_str().unwrap(), "/Volumes/My Passport");
        assert_eq!(parsed["bind_addr"].as_str().unwrap(), "0.0.0.0:41145");
        assert_eq!(parsed["relay_urls"].as_array().unwrap().len(), 0);
        assert!(out.contains("# 固定端口"));
        assert!(out.ends_with("\n[telemetry]\nenabled = false\n"), "{out}");
        let key_pos = out.find("data_dir").unwrap();
        let section_pos = out.find("\n[").expect("原文有 [telemetry] section");
        assert!(key_pos < section_pos, "顶层键必须落在首个 [section] 之前");
    }

    #[test]
    fn desk46_merge_windows_path_roundtrip_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let path = "C:\\Users\\ethan\\P-Pass 家庭照片库";
        let once = merge_library_dir("", path);
        std::fs::write(dir.path().join("config.toml"), &once).unwrap();
        let back = configured_library_dir(dir.path()).expect("写出去必须读得回");
        assert_eq!(back, path, "写→读不得变形（反斜杠不许翻倍）");
        let twice = merge_library_dir(&once, &back);
        assert_eq!(once, twice, "写→读→再写必须逐字节幂等");
    }

    #[test]
    fn desk46_target_verdicts() {
        assert!(library_target_verdict("/new/lib", Some("/old/lib"), true, true).is_ok());
        let e = library_target_verdict("/nope", Some("/old/lib"), false, true).unwrap_err();
        assert!(e.contains("ui.err_library_target_missing"), "{e}");
        let e = library_target_verdict("/ro", None, true, false).unwrap_err();
        assert!(e.contains("ui.err_library_target_readonly"), "{e}");
        for (cur, new) in [
            ("/old/lib", "/old/lib"),
            ("/old/lib", "/old/lib/sub"),
            ("/old/lib/photos", "/old/lib"),
        ] {
            let e = library_target_verdict(new, Some(cur), true, true).unwrap_err();
            assert!(e.contains("ui.err_library_nested"), "{cur} vs {new}: {e}");
        }
        assert!(library_target_verdict("/old/lib2", Some("/old/lib"), true, true).is_ok());
        assert!(library_target_verdict("/anywhere", None, true, true).is_ok());
    }

    /// 错误的线上格式就是壳 `ui_err` 的 `{"key","params"}`（#1045 原样转交前端）。
    #[test]
    fn verdict_errors_use_the_shell_ui_err_wire_shape() {
        let e = library_target_verdict("/nope", None, false, true).unwrap_err();
        let v: serde_json::Value = serde_json::from_str(&e).expect("必须是 JSON");
        assert_eq!(
            v,
            serde_json::json!({"key": "ui.err_library_target_missing", "params": {"dir": "/nope"}})
        );
        let e = library_target_verdict("/a/b", Some("/a"), true, true).unwrap_err();
        assert_eq!(e, r#"{"key":"ui.err_library_nested","params":{}}"#);
    }

    #[test]
    fn desk46_paths_overlap_boundaries() {
        assert!(paths_overlap("/a/b", "/a/b/"));
        assert!(paths_overlap("/a/b", "/a/b/c"));
        assert!(paths_overlap("/a/b/c", "/a/b"));
        assert!(!paths_overlap("/a/b", "/a/bc"));
        assert!(!paths_overlap("/a/b", "/a/c"));
        assert!(paths_overlap("C:\\Lib", "c:\\lib\\sub"));
        assert!(!paths_overlap("C:\\Lib", "C:\\Lib2"));
        assert!(paths_overlap("C:/Lib/sub", "C:\\Lib"));
    }

    const DESK49_FULL_CFG: &str = "data_dir = \"/old/library\"\n\nbind_addr = \"0.0.0.0:41145\"\n\nrelay_urls = []\n\n[telemetry]\nenabled = false\n";

    /// DESK-49 (#710)：读失败（非 UTF-8）⇒ keyed 错误、文件逐字节不变。
    /// 反证：换回 `read_to_string(..).unwrap_or_default()`，本测试必须红。
    #[test]
    fn desk49_non_utf8_config_errors_and_keeps_file() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");
        let bytes: &[u8] = b"data_dir = \"/old\"\nbind_addr = \"\xff\xfe\"\n";
        std::fs::write(&cfg, bytes).unwrap();
        let e = rewrite_library_dir(&cfg, "/new/library").unwrap_err();
        assert!(e.contains("ui.err_set_library"), "{e}");
        assert_eq!(std::fs::read(&cfg).unwrap(), bytes, "读失败时不得写文件");
    }

    #[test]
    fn desk49_missing_config_is_created() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");
        rewrite_library_dir(&cfg, "/new/library").expect("不存在应正常创建");
        let parsed: toml::Value = toml::from_str(&std::fs::read_to_string(&cfg).unwrap()).unwrap();
        assert_eq!(parsed["data_dir"].as_str().unwrap(), "/new/library");
    }

    #[test]
    fn desk49_readable_config_keeps_other_fields() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");
        std::fs::write(&cfg, DESK49_FULL_CFG).unwrap();
        rewrite_library_dir(&cfg, "/new/library").unwrap();
        let parsed: toml::Value = toml::from_str(&std::fs::read_to_string(&cfg).unwrap()).unwrap();
        assert_eq!(parsed["data_dir"].as_str().unwrap(), "/new/library");
        assert_eq!(parsed["bind_addr"].as_str().unwrap(), "0.0.0.0:41145");
        assert_eq!(parsed["relay_urls"].as_array().unwrap().len(), 0);
        assert!(
            std::fs::read_to_string(&cfg)
                .unwrap()
                .ends_with("\n[telemetry]\nenabled = false\n"),
            "旧版 [telemetry] 段必须逐字节保留"
        );
    }

    /// DESK-46：换库全流程——校验通过后只改 data_dir 一行，并清掉旧库里的
    /// 孤儿 config.toml；库 == 平台目录时不得误删平台 config 自己。
    #[test]
    fn desk46_set_library_rewrites_and_removes_orphan() {
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("platform");
        let old = tmp.path().join("old-lib");
        let new = tmp.path().join("new-lib");
        std::fs::create_dir_all(&platform_dir).unwrap();
        std::fs::create_dir_all(&old).unwrap();
        std::fs::create_dir_all(&new).unwrap();
        std::fs::write(
            platform_dir.join("config.toml"),
            merge_library_dir(DESK49_FULL_CFG, old.to_str().unwrap()),
        )
        .unwrap();
        std::fs::write(old.join("config.toml"), "data_dir = \"/x\"\n").unwrap();

        set_library(&platform_dir, new.to_str().unwrap()).unwrap();

        assert_eq!(
            configured_library_dir(&platform_dir).as_deref(),
            new.to_str()
        );
        assert!(
            !old.join("config.toml").exists(),
            "旧库孤儿 config 应被清理"
        );
        let text = std::fs::read_to_string(platform_dir.join("config.toml")).unwrap();
        assert!(text.contains("bind_addr = \"0.0.0.0:41145\""), "{text}");

        // 库 == 平台目录：孤儿就是平台 config 本身，不得删。
        std::fs::write(
            platform_dir.join("config.toml"),
            merge_library_dir(DESK49_FULL_CFG, platform_dir.to_str().unwrap()),
        )
        .unwrap();
        set_library(&platform_dir, new.to_str().unwrap()).unwrap();
        assert!(platform_dir.join("config.toml").is_file());
    }

    /// 读当前库目录用逐行解析，不走 `Config::load`：config 里有 daemon 不认
    /// 识的键时，换库照样要能做（嵌套校验照样生效）。
    #[test]
    fn set_library_tolerates_unknown_keys_and_still_checks_nesting() {
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("platform");
        let old = tmp.path().join("lib");
        let nested = old.join("sub");
        std::fs::create_dir_all(&platform_dir).unwrap();
        std::fs::create_dir_all(&nested).unwrap();
        let doc = format!(
            "data_dir = {}\nsome_future_key = 1\n",
            toml::Value::String(old.to_str().unwrap().into())
        );
        std::fs::write(platform_dir.join("config.toml"), &doc).unwrap();
        let e = set_library(&platform_dir, nested.to_str().unwrap()).unwrap_err();
        assert!(e.contains("ui.err_library_nested"), "{e}");
        assert_eq!(
            std::fs::read_to_string(platform_dir.join("config.toml")).unwrap(),
            doc,
            "校验失败不得写文件"
        );
    }

    #[test]
    fn read_config_data_dir_unescapes_basic_strings_only() {
        let dir = tempfile::tempdir().unwrap();
        let w = |s: &str| std::fs::write(dir.path().join("config.toml"), s).unwrap();
        w("bind_addr = \"0.0.0.0:41145\"\n\ndata_dir = \"/tmp/ppf-lib\"\n");
        assert_eq!(
            read_config_data_dir(dir.path()).as_deref(),
            Some("/tmp/ppf-lib")
        );
        w("data_dir = \"C:\\\\Users\\\\x\"\n");
        assert_eq!(
            read_config_data_dir(dir.path()).as_deref(),
            Some("C:\\Users\\x")
        );
        w("data_dir = 'C:\\Users\\x'\n");
        assert_eq!(
            read_config_data_dir(dir.path()).as_deref(),
            Some("C:\\Users\\x")
        );
        w("data_dir = \"\"\n");
        assert_eq!(read_config_data_dir(dir.path()), None);
    }
}
