//! Daemon log access from the shell — DESK-09（启动失败时把 daemon 自己
//! 打出来的那行错误捞出来）与 DESK-10（导出包本地组装，daemon 挂着照样
//! 能导）共用的一层。
//!
//! 铁律两条，都是真机事故换来的：
//!
//! 1. **日志路径从 LaunchAgent plist 读，不硬编码**。plist 的
//!    `StandardOutPath` / `StandardErrorPath` 是唯一真相；plist 不在
//!    （没注册成常驻服务）就如实说"没注册"，不去猜 `~/Library/Logs`。
//! 2. **只看新增的那段**。launchd 的 stderr 文件是 append 的，跨多次运行
//!    累积。拿整个文件去找错误行，会把四天前的旧错误当成这次的原因——
//!    那正是 DESK-10 要消灭的「导出包里只有一条四天前的事件」同一种病。
//!    所以启动前记长度，超时后只读新增字节。

use std::io::{Read as _, Seek as _, SeekFrom};
use std::path::{Path, PathBuf};

/// LaunchAgent plist（macOS 常驻服务的唯一登记处，label 与
/// `crates/platform/src/macos.rs` 的 `AGENT_LABEL` 一致）。
pub fn plist_path() -> PathBuf {
    home_dir().join("Library/LaunchAgents/com.p-pass.daemon.plist")
}

pub fn home_dir() -> PathBuf {
    PathBuf::from(
        std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_else(|_| ".".into()),
    )
}

/// plist 里的 stdout / stderr 路径。纯函数——单测直接喂 plist 文本。
///
/// 只认 `<key>X</key><string>path</string>` 这种紧挨着的写法（我们自己
/// 生成的 plist 就是这么写的），跨行的也认（key 与 string 之间只允许
/// 空白）。认不出来 = 返回 None，调用方如实报"读不到"，不猜路径。
pub fn parse_plist_log_paths(xml: &str) -> (Option<String>, Option<String>) {
    (
        plist_string_value(xml, "StandardOutPath"),
        plist_string_value(xml, "StandardErrorPath"),
    )
}

fn plist_string_value(xml: &str, key: &str) -> Option<String> {
    let needle = format!("<key>{key}</key>");
    let rest = &xml[xml.find(&needle)? + needle.len()..];
    let rest = rest.trim_start();
    let rest = rest.strip_prefix("<string>")?;
    let end = rest.find("</string>")?;
    let val = rest[..end].trim();
    (!val.is_empty()).then(|| val.to_string())
}

/// 文件当前长度（读不到 = 0，等价于"还没有任何输出"）。
pub fn file_len(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

/// 从 `offset` 起读到文件末尾，最多 `max_bytes`（超了取尾部）。
/// 文件被 truncate/轮转（当前长度 < offset）时从 0 读——不返回空。
pub fn read_since(path: &Path, offset: u64, max_bytes: u64) -> Option<String> {
    let len = file_len(path);
    let start = if len < offset { 0 } else { offset };
    let start = start.max(len.saturating_sub(max_bytes));
    let mut f = std::fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::new();
    f.take(max_bytes).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).to_string())
}

/// 文件尾部最多 `max_bytes` 字节（导出用）。
pub fn tail(path: &Path, max_bytes: u64) -> Option<String> {
    read_since(path, 0, max_bytes)
}

/// 从 daemon 新增的输出里挑出"最像错误原因"的那一行。
///
/// 优先带错误标记的最后一行（anyhow 的 `Error:`、tracing 的 `ERROR`、
/// panic）；没有标记就退回最后一行非空输出——有原文总比只报超时好。
/// 完全没有新增输出 → None，调用方必须明说"没捕获到新输出"，不许拿
/// 旧内容顶上。**返回的行是原文，不截断、不翻译**（验收判据要 grep
/// `migration ... missing in the resolved migrations` 这串原文）。
pub fn extract_error_line(appended: &str) -> Option<String> {
    let lines: Vec<&str> = appended
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    const MARKERS: [&str; 5] = ["Error:", "error:", "ERROR", "panicked", "Caused by"];
    lines
        .iter()
        .rev()
        .find(|l| MARKERS.iter().any(|m| l.contains(m)))
        .or_else(|| lines.last())
        .map(|l| (*l).to_string())
}

/// 家目录 → `<DATA>`（与 daemon 侧 `sanitize()` 同语义：导出件绝不带
/// 用户名）。桌面壳是独立 workspace（ADR-012：不依赖内部业务 crate），
/// 所以这里是同语义的第二份实现，靠"包里不许出现真实 HOME"的测试锁死。
pub fn sanitize(s: &str, home: &str) -> String {
    if home.is_empty() {
        return s.to_string();
    }
    s.replace(home, "<DATA>")
}

/// 长 hex 串（NodeId 全长 64 hex、配对令牌 24 hex）只留前 8 位。
/// daemon 的 stdout 日志里有 NodeId 和配对串，导出包的脱敏口径必须跟
/// `devices.json` 一致：只出前缀。
pub fn mask_long_hex(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_hexdigit() {
            let mut j = i;
            while j < chars.len() && chars[j].is_ascii_hexdigit() {
                j += 1;
            }
            let run: String = chars[i..j].iter().collect();
            if run.len() >= 24 {
                out.push_str(&run[..8]);
                out.push_str("…<masked>");
            } else {
                out.push_str(&run);
            }
            i = j;
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

/// 导出件的统一脱敏：家目录 + 长 hex。新加的文件一律过这里。
pub fn scrub(s: &str, home: &str) -> String {
    mask_long_hex(&sanitize(s, home))
}

/// config.toml 摘要（只出 `data_dir` / `bind_addr`，路径脱敏）——
/// 全文可能有别的东西，摘要只取这两条支持案子真的会问的。
pub fn config_summary(raw: Option<&str>, home: &str) -> String {
    let Some(raw) = raw else {
        return "config.toml: 不存在（向导还没走完？）\n".to_string();
    };
    let mut data_dir = None;
    let mut bind_addr = None;
    for line in raw.lines() {
        let line = line.trim();
        for (key, slot) in [("data_dir", &mut data_dir), ("bind_addr", &mut bind_addr)] {
            if let Some(rest) = line.strip_prefix(key) {
                if let Some(val) = rest.trim_start().strip_prefix('=') {
                    let val = val.trim().trim_matches('"').trim();
                    if !val.is_empty() && slot.is_none() {
                        *slot = Some(val.to_string());
                    }
                }
            }
        }
    }
    format!(
        "data_dir  = {}\nbind_addr = {}\n",
        data_dir
            .as_deref()
            .map(|v| scrub(v, home))
            .unwrap_or_else(|| "(未设置)".into()),
        bind_addr.as_deref().unwrap_or("(未设置)"),
    )
}

/// 组装 bundle 需要的一切。**收集与打包分离**：收集碰文件系统/IPC，
/// 打包是纯函数（单测直接构造 inputs，不需要真 daemon、真 plist）。
#[derive(Debug, Default)]
pub struct BundleInputs {
    pub home: String,
    pub app_version: String,
    pub daemon_version: Option<String>,
    /// daemon 不可达时的原因（可达 = None）。
    pub daemon_unreachable: Option<String>,
    pub config_toml: Option<String>,
    /// plist 是否存在（不存在 = 没注册成常驻服务，也就没有日志路径）。
    pub plist_found: bool,
    pub stdout_path: Option<String>,
    pub stderr_path: Option<String>,
    pub stdout_tail: Option<String>,
    pub stderr_tail: Option<String>,
    /// daemon 活着时它自己给的那几份（diag_events.json / devices.json /
    /// audit.json），原样搬进来（daemon 侧已脱敏）。
    pub daemon_entries: Vec<(String, Vec<u8>)>,
}

const README: &str = "\
P-Pass 诊断包（导出时间见各文件内容）

先看哪个：
  1. daemon-stderr.log  ← 后台服务起不来 / 崩了，原因几乎总在这里
  2. daemon-stdout.log  ← 正常运行日志（连接、备份、库目录）
  3. versions.txt       ← App 与后台服务的版本号（版本装反是常见原因）
  4. config-summary.txt ← 照片库目录 / 监听地址
  5. diag_events.json   ← 后台服务自己记的诊断事件流
  6. devices.json       ← 已配对设备（NodeId 只留前缀）
  7. audit.json         ← 审计事件（配对 / 吊销 / 外部删除）
  8. daemon-unreachable.txt ← 只在导出时后台服务不可达才有；里面写了
                              为什么连不上（此时 5~7 会缺）

脱敏：家目录路径统一替换成 <DATA>，NodeId / 配对令牌这类长 hex 串只
留前 8 位。可以直接把整个 zip 发给开发者。
";

/// 打包内容（纯函数：入 inputs，出 zip 条目表）。
pub fn build_bundle(i: &BundleInputs) -> Vec<(String, Vec<u8>)> {
    let home = i.home.as_str();
    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    entries.push(("README.txt".into(), README.as_bytes().to_vec()));

    let versions = format!(
        "app_version    = {}\ndaemon_version = {}\ndaemon_reachable = {}\nplatform       = {}\n",
        i.app_version,
        i.daemon_version.as_deref().unwrap_or("(读不到)"),
        if i.daemon_unreachable.is_none() {
            "yes"
        } else {
            "no"
        },
        std::env::consts::OS,
    );
    entries.push(("versions.txt".into(), versions.into_bytes()));
    entries.push((
        "config-summary.txt".into(),
        config_summary(i.config_toml.as_deref(), home).into_bytes(),
    ));

    // 日志来源写进包里——路径是从 plist 读的还是没读到，支持方一眼可见。
    let mut src = String::new();
    if i.plist_found {
        src.push_str("LaunchAgent plist: 已注册（日志路径从 plist 读取）\n");
    } else {
        src.push_str(
            "LaunchAgent plist: 未注册（后台服务没有设为常驻服务）——\
             因此没有 stdout/stderr 日志路径可读，包里不会有 daemon-*.log\n",
        );
    }
    src.push_str(&format!(
        "StandardOutPath  = {}\nStandardErrorPath = {}\n",
        i.stdout_path
            .as_deref()
            .map(|p| scrub(p, home))
            .unwrap_or_else(|| "(读不到)".into()),
        i.stderr_path
            .as_deref()
            .map(|p| scrub(p, home))
            .unwrap_or_else(|| "(读不到)".into()),
    ));
    entries.push(("log-sources.txt".into(), src.into_bytes()));

    if let Some(t) = &i.stderr_tail {
        entries.push(("daemon-stderr.log".into(), scrub(t, home).into_bytes()));
    }
    if let Some(t) = &i.stdout_tail {
        entries.push(("daemon-stdout.log".into(), scrub(t, home).into_bytes()));
    }
    if let Some(reason) = &i.daemon_unreachable {
        let text = format!(
            "导出时后台服务不可达，所以包里没有 diag_events.json / devices.json / \
             audit.json（那三份只有后台服务拿得到）。\n\n不可达原因：{}\n\n\
             其余内容（daemon 的 stdout/stderr 日志、版本号、配置摘要）照常收集——\
             后台服务起不来恰恰是最需要日志的时候。\n",
            scrub(reason, home)
        );
        entries.push(("daemon-unreachable.txt".into(), text.into_bytes()));
    }
    for (name, bytes) in &i.daemon_entries {
        entries.push((name.clone(), bytes.clone()));
    }
    entries
}

/// 把条目表写成 zip。
pub fn write_zip(path: &Path, entries: &[(String, Vec<u8>)]) -> Result<(), String> {
    use std::io::Write as _;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("建目录失败：{e}"))?;
    }
    let file = std::fs::File::create(path).map_err(|e| format!("创建 zip 失败：{e}"))?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::SimpleFileOptions::default();
    for (name, bytes) in entries {
        zip.start_file(name.as_str(), opts)
            .map_err(|e| format!("写 zip 条目 {name} 失败：{e}"))?;
        zip.write_all(bytes)
            .map_err(|e| format!("写 zip 条目 {name} 失败：{e}"))?;
    }
    zip.finish().map_err(|e| format!("收尾 zip 失败：{e}"))?;
    Ok(())
}

/// 读出 daemon 自己产的那个 zip 的全部条目（读进内存后才允许覆盖同名
/// 文件——daemon 和我们写的是同一个 `ppf-logs.zip`）。
pub fn read_zip_entries(path: &Path) -> Result<Vec<(String, Vec<u8>)>, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("打开 daemon zip 失败：{e}"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("daemon zip 不可读：{e}"))?;
    let mut out = Vec::new();
    for idx in 0..zip.len() {
        let mut f = zip
            .by_index(idx)
            .map_err(|e| format!("读 daemon zip 条目失败：{e}"))?;
        let name = f.name().to_string();
        let mut buf = Vec::new();
        f.read_to_end(&mut buf)
            .map_err(|e| format!("读 daemon zip 条目 {name} 失败：{e}"))?;
        out.push((name, buf));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PLIST: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key><string>com.p-pass.daemon</string>
    <key>StandardOutPath</key><string>/Users/someone/Library/Logs/p-pass-daemon.log</string>
    <key>StandardErrorPath</key><string>/Users/someone/Library/Logs/p-pass-daemon.err</string>
</dict>
</plist>
"#;

    // DESK-10: 日志路径必须从 plist 读出来（不硬编码 ~/Library/Logs）。
    #[test]
    fn plist_log_paths_come_from_the_plist() {
        let (out, err) = parse_plist_log_paths(PLIST);
        assert_eq!(
            out.as_deref(),
            Some("/Users/someone/Library/Logs/p-pass-daemon.log")
        );
        assert_eq!(
            err.as_deref(),
            Some("/Users/someone/Library/Logs/p-pass-daemon.err")
        );
    }

    // plist 里没这两个 key（或压根不是我们的 plist）→ 老实说读不到。
    #[test]
    fn plist_without_log_keys_reads_nothing() {
        let (out, err) = parse_plist_log_paths("<plist><dict></dict></plist>");
        assert!(out.is_none() && err.is_none());
    }

    // DESK-09: 只读新增的那段——旧内容不许冒充这次的错误。
    #[test]
    fn read_since_returns_only_appended_bytes() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("d.err");
        std::fs::write(&p, "四天前的旧错误\n").unwrap();
        let before = file_len(&p);
        std::fs::write(
            &p,
            "四天前的旧错误\nError: migration: migration 2 was previously applied but is missing in the resolved migrations\n",
        )
        .unwrap();
        let appended = read_since(&p, before, 64 * 1024).unwrap();
        assert!(!appended.contains("四天前"), "{appended}");
        assert!(
            appended.contains("migration 2 was previously applied"),
            "{appended}"
        );
    }

    // DESK-09: 那次真实事故的原文行，必须原样被挑出来（不截断、不翻译）。
    #[test]
    fn extract_error_line_picks_the_migration_error_verbatim() {
        let stderr = "2026-08-25 starting daemon\n\
             Error: migration: migration 2 was previously applied but is missing in the resolved migrations\n";
        assert_eq!(
            extract_error_line(stderr).unwrap(),
            "Error: migration: migration 2 was previously applied but is missing in the resolved migrations"
        );
    }

    // 没有错误标记也别丢原文——最后一行非空输出仍然比"超时"有用。
    #[test]
    fn extract_error_line_falls_back_to_last_line() {
        assert_eq!(
            extract_error_line("bind 41145 busy\n").unwrap(),
            "bind 41145 busy"
        );
        assert!(extract_error_line("   \n\n").is_none());
    }

    // DESK-10 硬判据：daemon 不可达时也必须出包，且含 .err/.log 与版本。
    #[test]
    fn bundle_without_daemon_still_carries_logs_and_versions() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            app_version: "0.4.0-test.2".into(),
            daemon_version: Some("0.3.0".into()),
            daemon_unreachable: Some("找不到运行中的 P-Pass 后台服务（ipc.token 不存在）".into()),
            config_toml: Some("data_dir = \"/Users/someone/Pictures/lib\"\nbind_addr = \"0.0.0.0:41145\"\n".into()),
            plist_found: true,
            stdout_path: Some("/Users/someone/Library/Logs/p-pass-daemon.log".into()),
            stderr_path: Some("/Users/someone/Library/Logs/p-pass-daemon.err".into()),
            stdout_tail: Some("node ready\n".into()),
            stderr_tail: Some(
                "Error: migration: migration 2 was previously applied but is missing in the resolved migrations\n".into(),
            ),
            daemon_entries: Vec::new(),
        };
        let entries = build_bundle(&i);
        let names: Vec<&str> = entries.iter().map(|(n, _)| n.as_str()).collect();
        for want in [
            "README.txt",
            "versions.txt",
            "config-summary.txt",
            "log-sources.txt",
            "daemon-stderr.log",
            "daemon-stdout.log",
            "daemon-unreachable.txt",
        ] {
            assert!(names.contains(&want), "缺 {want}：{names:?}");
        }
        let text = all_text(&entries);
        // 版本信息在包里。
        assert!(text.contains("app_version    = 0.4.0-test.2"), "{text}");
        assert!(text.contains("daemon_version = 0.3.0"), "{text}");
        // 复现那次事故：错误原文必须出现在包里。
        assert!(
            text.contains(
                "migration 2 was previously applied but is missing in the resolved migrations"
            ),
            "{text}"
        );
        // 脱敏不回退：真实家目录路径不许出现。
        assert!(!text.contains("/Users/someone"), "{text}");
        assert!(text.contains("<DATA>/Pictures/lib"), "{text}");
    }

    // daemon 活着时，它给的那三份原样进包。
    #[test]
    fn bundle_with_daemon_adds_diag_devices_audit() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            app_version: "0.4.0".into(),
            daemon_version: Some("0.4.0".into()),
            daemon_unreachable: None,
            plist_found: true,
            daemon_entries: vec![
                ("diag_events.json".into(), b"[]".to_vec()),
                ("devices.json".into(), b"[]".to_vec()),
                ("audit.json".into(), b"[]".to_vec()),
            ],
            ..Default::default()
        };
        let entries = build_bundle(&i);
        let names: Vec<&str> = entries.iter().map(|(n, _)| n.as_str()).collect();
        for want in ["diag_events.json", "devices.json", "audit.json"] {
            assert!(names.contains(&want), "缺 {want}：{names:?}");
        }
        // daemon 可达 → 不该有"不可达"说明文件。
        assert!(!names.contains(&"daemon-unreachable.txt"), "{names:?}");
    }

    // 脱敏口径与 devices.json 一致：NodeId / 配对令牌只出前缀。
    #[test]
    fn long_hex_is_masked_to_a_prefix() {
        let node = "ab".repeat(32);
        let masked = mask_long_hex(&format!("peer {node} connected"));
        assert!(masked.contains("abababab…<masked>"), "{masked}");
        assert!(!masked.contains(&node), "{masked}");
        // 短 hex（端口号、小 id）不动。
        assert_eq!(mask_long_hex("port 41145 beef"), "port 41145 beef");
    }

    // zip 真的能写出来、读回来（write_zip / read_zip_entries 往返）。
    #[test]
    fn zip_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("ppf-logs.zip");
        write_zip(&p, &[("a.txt".into(), b"hello".to_vec())]).unwrap();
        let back = read_zip_entries(&p).unwrap();
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].0, "a.txt");
        assert_eq!(back[0].1, b"hello");
    }

    fn all_text(entries: &[(String, Vec<u8>)]) -> String {
        entries
            .iter()
            .map(|(n, b)| format!("--- {n}\n{}", String::from_utf8_lossy(b)))
            .collect::<Vec<_>>()
            .join("\n")
    }
}
