//! #1042：诊断包由 daemon 组装并脱敏——`ppf-daemon diag export` 的实现。
//!
//! 原先长在桌面壳（`apps/desktop/src-tauri/src/{daemon_logs.rs,lib.rs}` 的
//! `export_logs_bundle` / `assemble_export` / `build_bundle`），壳读回 daemon
//! 的 `logs.export` 再脱敏一遍后覆盖；脱敏规则因此有两份拷贝。S3 拍板：core
//! 是诊断包的唯一写者，经一次性子命令对外提供，壳改调由 #1045 完成。
//!
//! 拍板口径（2026-10-20）：
//! - **导出到哪由调用方定**：`--out <zip 路径>` 必填；
//! - **只打包 daemon 自己拥有的东西**：`<平台数据目录>/logs/` 下 daemon 写的
//!   日志（含轮转份）与启动早期 stderr 落点、在线时 IPC `logs.export` 给的
//!   diag / devices / audit 三份。**不读 launchd plist、不收
//!   `~/Library/Logs/p-pass-daemon.{log,err}`**——#1046 起 launchd 直接写进
//!   daemon 自己的 logs 目录（`daemon.out` / `daemon.err`），随 logs 目录收进包；
//! - 壳自己的 `desktop.log` 在同一个 logs 目录下，按固定路径收进包；
//! - **脱敏一条都不放宽**：只用 [`crate::redact`] 的现行规则（不为了好读把
//!   `desktop.log` 加进安全文件名）。
//!
//! 结构沿用壳的做法：**收集与打包分离**——收集碰文件系统 / IPC，打包
//! （[`build_bundle`]）是纯函数，单测直接构造 [`BundleInputs`]。
//!
//! DESK-10 核心不变：daemon（常驻服务）不在线**不是失败路径**——包照出，
//! 只是少三份 JSON、多一份说明。本进程离线时**不开数据库**（跨进程开 sqlite
//! 有并发 / migration 风险，且离线包从来不含那三份）。

use std::io::{Read as _, Seek as _, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::config::ui_err;

/// 一次 IPC 往返的上限（与壳 NET-11 的 `IPC_READ_TIMEOUT` 同值）：daemon
/// 活着但僵住时导出不能跟着挂死。
pub(crate) const IPC_TIMEOUT: Duration = Duration::from_secs(10);

/// daemon 固定位置日志收进包的尾部上限（与壳现行一致）。
pub(crate) const DAEMON_LOG_TAIL: u64 = 1024 * 1024;
/// 启动早期 stderr、壳日志收进包的尾部上限（与壳现行一致）。
pub(crate) const SMALL_LOG_TAIL: u64 = 256 * 1024;

// ── 读文件 ───────────────────────────────────────────────────────────

/// 文件尾部最多 `max_bytes` 字节（日志一路累积，取尾部就够）。
pub fn tail(path: &Path, max_bytes: u64) -> Option<String> {
    let len = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let mut f = std::fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(len.saturating_sub(max_bytes)))
        .ok()?;
    let mut buf = Vec::new();
    f.take(max_bytes).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).to_string())
}

/// DESK-32 (#367)：读固定位置的日志。返回 `(尾部, 没读到的原因)`，两者恰有
/// 一个是 `Some`——没读到必须说清是哪一种。
pub fn persistent_log(path: Option<&Path>, max_bytes: u64) -> (Option<String>, Option<String>) {
    let Some(path) = path else {
        return (None, Some("本平台没有固定位置的后台服务日志".into()));
    };
    match tail(path, max_bytes) {
        Some(t) => (Some(t), None),
        None if path.exists() => (
            None,
            Some("日志文件存在，但读不出来（被占用或没有权限）".into()),
        ),
        None => (
            None,
            Some(
                "日志文件不存在——后台服务可能从没在这台机器上启动过，\
                 或者日志目录被清理过"
                    .into(),
            ),
        ),
    }
}

/// 轮转出来的上一代：`daemon.log` → `daemon.log.1`（见 `log_guard::rotate_file`）。
fn rotated(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(".1");
    PathBuf::from(s)
}

// ── 脱敏 ─────────────────────────────────────────────────────────────

/// 导出件的统一脱敏（#544）：库目录 → `<LIBRARY>`（先于家目录替换），家目录
/// → `<DATA>`，再过 [`crate::redact::redact_export_json_or_text`]。
pub fn scrub_full(s: &str, home: &str, library: Option<&str>) -> String {
    let pre = |s: &str| {
        let s = match library.filter(|l| !l.is_empty()) {
            Some(lib) => s.replace(lib, "<LIBRARY>"),
            None => s.to_string(),
        };
        if home.is_empty() {
            s
        } else {
            s.replace(home, "<DATA>")
        }
    };
    crate::redact::redact_export_json_or_text(s, &pre)
}

/// config.toml 里的 `data_dir`（库目录），经 TOML 解析取值（DESK-40：逐行读
/// 会带着转义，脱敏就对不上）。解析不了 / 没设 = None。
pub fn library_root(raw: Option<&str>) -> Option<String> {
    raw?.parse::<toml::Table>()
        .ok()?
        .get("data_dir")?
        .as_str()
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

/// #544：devices.json 里的设备名是用户起的，属于可识别信息。新 daemon 已经
/// 不导出它；这里在包边界再剥一次（版本可能歪：新导出器 + 旧常驻服务）。
fn strip_device_names(json: &str) -> Option<String> {
    let mut v: serde_json::Value = serde_json::from_str(json).ok()?;
    for d in v.as_array_mut()? {
        if let Some(obj) = d.as_object_mut() {
            obj.remove("name");
        }
    }
    serde_json::to_string_pretty(&v).ok()
}

/// config.toml 摘要（只出 `data_dir` / `bind_addr`，库目录本身不出包）。
pub fn config_summary(raw: Option<&str>, home: &str) -> String {
    let Some(raw) = raw else {
        return "config.toml: 不存在（向导还没走完？）\n".to_string();
    };
    let table = match raw.parse::<toml::Table>() {
        Ok(t) => t,
        // 不带错误原文：toml 的报错会引用出错的那一行，那一行里可能就是
        // 没脱敏的路径。只给行号。
        Err(e) => {
            let line = e
                .span()
                .map(|s| raw[..s.start.min(raw.len())].lines().count().max(1));
            return match line {
                Some(n) => format!("config.toml: 解析失败（第 {n} 行附近），文件可能被改坏了\n"),
                None => "config.toml: 解析失败，文件可能被改坏了\n".to_string(),
            };
        }
    };
    let field = |key: &str| {
        table
            .get(key)
            .and_then(toml::Value::as_str)
            .filter(|v| !v.is_empty())
    };
    let data_dir = match field("data_dir") {
        Some(v) if !home.is_empty() && v.starts_with(home) => {
            "<LIBRARY>（位于家目录下）".to_string()
        }
        Some(_) => "<LIBRARY>（不在家目录下）".to_string(),
        None => "(未设置)".to_string(),
    };
    format!(
        "data_dir  = {}\nbind_addr = {}\n",
        data_dir,
        field("bind_addr")
            .map(crate::redact::redact)
            .unwrap_or_else(|| "(未设置)".into()),
    )
}

// ── 打包（纯函数）─────────────────────────────────────────────────────

/// 一份可能没收进来的日志：路径、尾部、没收进来的原因。
#[derive(Debug, Default, Clone)]
pub struct LogPart {
    /// 本该在哪（本平台没有 = None）。
    pub path: Option<String>,
    pub tail: Option<String>,
    /// 没收进来的原因。收进来了 = None。不许静默省略（DESK-32）。
    pub missing: Option<String>,
}

/// 组装 bundle 需要的一切。
#[derive(Debug, Default)]
pub struct BundleInputs {
    pub home: String,
    /// 桌面壳版本（`--app-version`；没给 = None）。
    pub app_version: Option<String>,
    pub daemon_version: Option<String>,
    /// 常驻服务不可达的原因（可达 = None）。
    pub daemon_unreachable: Option<String>,
    /// 常驻服务在线、但三份 JSON 没拿到的原因。与上者互斥（DESK-31）。
    pub daemon_logs_unavailable: Option<String>,
    pub config_toml: Option<String>,
    /// 平台名（来自 platform adapter，不读 `std::env::consts`）。
    pub platform: String,
    /// `<logs>/daemon.log`（DIAG-B1 固定位置）。
    pub daemon_log: LogPart,
    /// `<logs>/daemon.log.1`（轮转出来的上一代；不存在不算缺失）。
    pub daemon_log_rotated: Option<LogPart>,
    /// daemon 的 stderr（启动早期报错、panic）：`<logs>/daemon.err`。Windows 由
    /// daemon 自己接（DESK-58），macOS 由 launchd 接（#1046 起也落在 logs 目录）。
    pub startup_stderr: Option<LogPart>,
    /// 服务管理器接的 stdout（macOS launchd：`<logs>/daemon.out`，#1046）；
    /// 本平台没有时 None。
    pub service_stdout: Option<LogPart>,
    /// `<logs>/desktop.log`（桌面壳自己的状态 / 连接日志，DESK-63）。
    pub desktop_log: LogPart,
    /// 常驻服务在线时它给的那几份（diag_events.json / devices.json / audit.json）。
    pub daemon_entries: Vec<(String, Vec<u8>)>,
    /// 常驻服务在线时 `status` 的 [`STATUS_FIELDS`] 那几项，写成包里的 `status.json`。
    pub daemon_status: Option<serde_json::Value>,
}

/// #1115：诊断包里 `status.json` 只收这几项——回归要核对的版本、状态、照片数、进程号，
/// 不收路径、设备名这类要脱敏的东西。macOS 常驻 daemon 只认签名程序，回归脚本经签名的
/// daemon 自己跑 `diag export` 取这份（daemon 角色本来就能调 `status` 与 `logs.export`，
/// 不新增权限）。
pub const STATUS_FIELDS: &[&str] = &["version", "state", "photo_count", "pid", "started_at"];

/// 从 `status` 应答里挑出 [`STATUS_FIELDS`]（应答里没有的项不补）。
pub fn status_summary(status: &serde_json::Value) -> serde_json::Value {
    let picked: serde_json::Map<String, serde_json::Value> = STATUS_FIELDS
        .iter()
        .filter_map(|k| status.get(*k).map(|v| ((*k).to_string(), v.clone())))
        .collect();
    serde_json::Value::Object(picked)
}

const README: &str = "\
P-Pass 诊断包（导出时间见各文件内容）

先看哪个：
  0. daemon.log         ← 后台服务自己写的完整运行日志（固定位置，每次运行都有）；
                          daemon.log.1 是轮转出来的上一段
  1. daemon-stderr.log  ← 后台服务的 stderr：启动早期的报错、崩溃信息
                          （daemon-stdout.log 是同一来源的 stdout，macOS 才有）
  2. versions.txt       ← App 与后台服务的版本号（版本装反是常见原因）；
                          status.json 是服务在线时的版本 / 状态 / 照片数 / 进程号
  3. config-summary.txt ← 照片库目录 / 监听地址
  4. log-sources.txt    ← 每份日志从哪来、收没收进来
  5. diag_events.json   ← 后台服务自己记的诊断事件流
  6. devices.json       ← 已配对设备（NodeId 只留前缀）
  7. audit.json         ← 审计事件（配对 / 吊销 / 外部删除）
  8. daemon-unreachable.txt / daemon-logs-unavailable.txt
                              ← 前者：导出时后台服务没有在运行，里面写了
                              为什么连不上；后者：服务在线但三份日志没拿到。
                              出现任一个时 5~7 会缺
  9. daemon-log-missing.txt
                              ← 0 那份没收进来，里面写了原因和它本该在的位置
 10. desktop.log         ← 桌面壳自己写的服务状态迁移 / 连接失败（#946）；
                              没有时看 desktop-log-missing.txt

脱敏（导出时自动做）：家目录 → <DATA>，库目录 → <LIBRARY>；路径里的文件夹
名换成 <dir>，照片等文件名换成 <file>.扩展名；公网 IP 换成 <ipv4:public> /
<ipv6:public>（局域网地址保留）；NodeId、hash、票据、配对令牌这类长标识只留
前 8 位；自建中继的域名换成 <host>；不含设备名。保留时间戳与错误信息，供开发者
排查。
";

/// 打包内容（纯函数：入 inputs，出 zip 条目表）。
pub fn build_bundle(i: &BundleInputs) -> Vec<(String, Vec<u8>)> {
    let home = i.home.as_str();
    let library = library_root(i.config_toml.as_deref());
    let scrub = |s: &str| scrub_full(s, home, library.as_deref());
    let scrub_path = |p: Option<&str>, none: &str| p.map(scrub).unwrap_or_else(|| none.into());
    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    entries.push(("README.txt".into(), README.as_bytes().to_vec()));

    // 三态（DESK-31）：不可达 / 在线但日志没拿到 / 完整。
    let reachable = if i.daemon_unreachable.is_some() {
        "no"
    } else if i.daemon_logs_unavailable.is_some() {
        "partial (online, logs unavailable)"
    } else {
        "yes"
    };
    let versions = format!(
        "app_version    = {}\ndaemon_version = {}\ndaemon_reachable = {}\nplatform       = {}\n",
        i.app_version
            .as_deref()
            .map(scrub)
            .unwrap_or_else(|| "(未提供)".into()),
        i.daemon_version
            .as_deref()
            .map(scrub)
            .unwrap_or_else(|| "(读不到)".into()),
        reachable,
        i.platform,
    );
    entries.push(("versions.txt".into(), versions.into_bytes()));
    if let Some(status) = &i.daemon_status {
        entries.push((
            "status.json".into(),
            serde_json::to_vec_pretty(status).unwrap_or_default(),
        ));
    }
    entries.push((
        "config-summary.txt".into(),
        config_summary(i.config_toml.as_deref(), home).into_bytes(),
    ));

    // 日志来源：每份写明路径与收没收进来。
    let status = |p: &LogPart| match &p.missing {
        None if p.tail.is_some() => "已收入包内".to_string(),
        None => "未收入".to_string(),
        Some(reason) => format!("未收入：{reason}"),
    };
    let mut src = String::new();
    src.push_str(&format!(
        "daemon.log（固定位置）= {} —— {}\n",
        scrub_path(i.daemon_log.path.as_deref(), "(本平台没有)"),
        status(&i.daemon_log),
    ));
    if let Some(r) = &i.daemon_log_rotated {
        src.push_str(&format!(
            "daemon.log.1（上一段）= {} —— {}\n",
            scrub_path(r.path.as_deref(), "(本平台没有)"),
            status(r),
        ));
    }
    match &i.startup_stderr {
        Some(e) => src.push_str(&format!(
            "启动早期 stderr = {} —— {}\n",
            scrub_path(e.path.as_deref(), "(本平台没有)"),
            status(e),
        )),
        None => src.push_str("启动早期 stderr = (本平台没有固定落点)\n"),
    }
    if let Some(o) = &i.service_stdout {
        src.push_str(&format!(
            "stdout = {} —— {}\n",
            scrub_path(o.path.as_deref(), "(本平台没有)"),
            status(o),
        ));
    }
    src.push_str(&format!(
        "desktop.log（桌面壳）= {} —— {}\n",
        scrub_path(i.desktop_log.path.as_deref(), "(没有记录)"),
        status(&i.desktop_log),
    ));
    entries.push(("log-sources.txt".into(), src.into_bytes()));

    if let Some(t) = &i.daemon_log.tail {
        entries.push(("daemon.log".into(), scrub(t).into_bytes()));
    } else {
        let text = format!(
            "这个诊断包里没有 daemon.log（后台服务自己写的运行日志）。\n\n原因：{}\n本该在：{}\n",
            i.daemon_log.missing.as_deref().unwrap_or("(没有记录原因)"),
            scrub_path(i.daemon_log.path.as_deref(), "(本平台没有)"),
        );
        entries.push(("daemon-log-missing.txt".into(), text.into_bytes()));
    }
    if let Some(t) = i.daemon_log_rotated.as_ref().and_then(|r| r.tail.as_ref()) {
        entries.push(("daemon.log.1".into(), scrub(t).into_bytes()));
    }
    if let Some(t) = &i.desktop_log.tail {
        entries.push(("desktop.log".into(), scrub(t).into_bytes()));
    } else {
        let text = format!(
            "这个诊断包里没有 desktop.log（桌面壳自己写的服务状态 / 连接日志）。\n\n原因：{}\n本该在：{}\n",
            i.desktop_log
                .missing
                .as_deref()
                .unwrap_or("(没有记录原因)"),
            scrub_path(i.desktop_log.path.as_deref(), "(没有记录路径)"),
        );
        entries.push(("desktop-log-missing.txt".into(), text.into_bytes()));
    }
    if let Some(t) = i.startup_stderr.as_ref().and_then(|e| e.tail.as_ref()) {
        entries.push(("daemon-stderr.log".into(), scrub(t).into_bytes()));
    }
    if let Some(t) = i.service_stdout.as_ref().and_then(|o| o.tail.as_ref()) {
        entries.push(("daemon-stdout.log".into(), scrub(t).into_bytes()));
    }
    if let Some(reason) = &i.daemon_unreachable {
        let text = format!(
            "导出时后台服务没有在运行（连不上），所以包里没有 diag_events.json / \
             devices.json / audit.json（那三份只有运行中的后台服务拿得到）。\n\n\
             不可达原因：{}\n\n\
             其余内容（daemon 的日志、版本号、配置摘要）照常收集——\
             后台服务起不来恰恰是最需要日志的时候。\n",
            scrub(reason)
        );
        entries.push(("daemon-unreachable.txt".into(), text.into_bytes()));
    }
    if let Some(reason) = &i.daemon_logs_unavailable {
        let text = format!(
            "导出时后台服务在线，但 diag_events.json / devices.json / audit.json \
             三份没拿到，所以它们不在包里。\n\n原因：{}\n\n\
             versions.txt 里的 daemon_version 是**在线服务自报**的版本，不是 \
             导出程序自己的版本。服务在线但日志缺失，和服务压根没起来是 \
             两回事——support 排查时别按「服务没起来」的路径走。\n",
            scrub(reason)
        );
        entries.push(("daemon-logs-unavailable.txt".into(), text.into_bytes()));
    }
    // 常驻服务给的那几份 JSON 也过同一道 scrub（DESK-10：版本可以歪，保证
    // 做在包边界上）；非 UTF-8 条目不原样进包（#544：脱敏对它无效）。
    for (name, bytes) in &i.daemon_entries {
        let scrubbed = match std::str::from_utf8(bytes) {
            Ok(text) => {
                let text = if name == "devices.json" {
                    strip_device_names(text).unwrap_or_else(|| text.to_string())
                } else {
                    text.to_string()
                };
                scrub(&text).into_bytes()
            }
            Err(_) => format!("（{name} 不是 UTF-8 文本，无法脱敏，未收入）\n").into_bytes(),
        };
        entries.push((name.clone(), scrubbed));
    }
    entries
}

// ── zip ──────────────────────────────────────────────────────────────

/// 把条目表写成 zip（父目录不存在就建）。
pub fn write_zip(path: &Path, entries: &[(String, Vec<u8>)]) -> Result<(), String> {
    use std::io::Write as _;
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
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

/// 读出 zip 的全部条目（常驻服务 `logs.export` 产的那个）。
pub fn read_zip_entries(path: &Path) -> Result<Vec<(String, Vec<u8>)>, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("打开 daemon zip 失败：{e}"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("daemon zip 不可读：{e}"))?;
    let mut out = Vec::new();
    for idx in 0..zip.len() {
        let mut f = zip
            .by_index(idx)
            .map_err(|e| format!("读 daemon zip 条目失败：{e}"))?;
        let name = f
            .name()
            .map_err(|e| format!("读 daemon zip 条目名失败：{e}"))?
            .to_string();
        let mut buf = Vec::new();
        f.read_to_end(&mut buf)
            .map_err(|e| format!("读 daemon zip 条目 {name} 失败：{e}"))?;
        out.push((name, buf));
    }
    Ok(out)
}

// ── 常驻服务（IPC 客户端）─────────────────────────────────────────────

/// 常驻服务收集结果的三态（DESK-31）。
pub enum DaemonCollection {
    /// 找不到运行中的常驻服务（DESK-10 的不可达分支）。
    Unreachable(String),
    /// 在线（version 已拿到或为 None），但三份 JSON 没拿到。
    LogsUnavailable {
        version: Option<String>,
        /// `status` 应答里 [`STATUS_FIELDS`] 那几项（拿不到 = None）。
        status: Option<serde_json::Value>,
        reason: String,
    },
    /// 三份完整拿到。
    Complete {
        version: Option<String>,
        status: Option<serde_json::Value>,
        entries: Vec<(String, Vec<u8>)>,
    },
}

/// ipc.token 的候选位置（令牌模式：Windows / Linux），顺序与壳 `ipc::token_candidates_from` 一致。
/// #1115：不再认 `PPF_DATA_DIR`——诊断导出连的是常驻 daemon，调用方的环境不许把它指向别处。
pub fn token_candidates(platform_dir: &Path, home: &Path) -> Vec<PathBuf> {
    let mut v = Vec::new();
    v.push(home.join("ppf-library/ipc.token"));
    v.push(platform_dir.join("ipc.token"));
    if let Some(val) = crate::config::read_config_data_dir(platform_dir) {
        v.push(PathBuf::from(val).join("ipc.token"));
    }
    v
}

/// #1115：常驻 daemon 的候选端点。macOS：签名 socket（连上后反向校验服务端是签名
/// daemon）；其余平台：令牌文件里记的端点。
pub fn resident_endpoints(platform_dir: &Path, home: &Path) -> Vec<crate::ipc::PeerEndpoint> {
    use platform::PlatformAdapter as _;
    match platform::adapter().resident_ipc() {
        platform::ResidentIpc::SignedSocket(path) => vec![crate::ipc::PeerEndpoint::Signed(path)],
        platform::ResidentIpc::NamespacedWithToken => token_candidates(platform_dir, home)
            .iter()
            .filter_map(|path| {
                let content = std::fs::read_to_string(path).ok()?;
                let mut lines = content.lines();
                let (name, token) = (lines.next()?, lines.next()?);
                Some(crate::ipc::PeerEndpoint::Token {
                    socket_name: name.trim().to_string(),
                    token_hex: token.trim().to_string(),
                })
            })
            .collect(),
    }
}

pub(crate) struct DaemonHandle {
    pub(crate) endpoint: crate::ipc::PeerEndpoint,
}

impl DaemonHandle {
    /// 一次请求 / 应答往返，整体有 [`IPC_TIMEOUT`] 上限。
    async fn call(&self, method: &str) -> Result<serde_json::Value, String> {
        use interprocess::local_socket::tokio::prelude::*;
        use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};
        let round_trip = async {
            let (conn, preamble) = self
                .endpoint
                .connect()
                .await
                .map_err(|e| ui_err("ui.err_connect", &[("err", &e)]))?;
            let (rx, mut tx) = conn.split();
            let req = serde_json::json!({ "id": method, "method": method, "params": {} });
            let wire = match preamble {
                Some(token) => format!("{token}\n{req}\n"),
                None => format!("{req}\n"),
            };
            tx.write_all(wire.as_bytes())
                .await
                .map_err(|e| ui_err("ui.err_send", &[("err", &e)]))?;
            let mut line = String::new();
            BufReader::new(rx)
                .read_line(&mut line)
                .await
                .map_err(|e| ui_err("ui.err_read_response", &[("err", &e)]))?;
            Ok::<String, String>(line)
        };
        let line = tokio::time::timeout(IPC_TIMEOUT, round_trip)
            .await
            .map_err(|_| format!("ipc timeout: {method} > {}s", IPC_TIMEOUT.as_secs()))??;
        let resp: serde_json::Value = serde_json::from_str(line.trim())
            .map_err(|e| ui_err("ui.err_not_json", &[("err", &e)]))?;
        if resp["ok"].as_bool() == Some(true) {
            Ok(resp["result"].clone())
        } else {
            // #1070: errors are `{code, reason, params}`; the reason names the cause.
            let reason = serde_json::from_value::<proto::RespError>(resp["error"].clone())
                .map(|e| e.reason().to_string())
                .unwrap_or_else(|_| "unknown".to_string());
            Err(format!("ipc {method}: {reason}"))
        }
    }
}

/// 找**运行中的**常驻服务：每个候选都用一次 status 探活——死实例留下的
/// 旧 token 文件不许劫持发现（与壳 `DaemonHandle::discover` 同规则）。
async fn discover(candidates: &[crate::ipc::PeerEndpoint]) -> Result<DaemonHandle, String> {
    let mut last_err = ui_err("ui.err_no_daemon", &[]);
    for endpoint in candidates {
        let handle = DaemonHandle {
            endpoint: endpoint.clone(),
        };
        match handle.call("status").await {
            Ok(_) => return Ok(handle),
            Err(e) => {
                last_err = ui_err(
                    "ui.err_daemon_unresponsive",
                    &[("path", &endpoint.label()), ("err", &e)],
                );
            }
        }
    }
    Err(last_err)
}

/// 向常驻服务要那三份。它把 zip 写在自己的库目录（`logs.export` 的现行
/// 行为）；读进内存后，若那不是调用方要的输出位置，就把这份中间产物删掉
/// ——导出位置只由 `--out` 决定，库目录里不留第二份包。
pub async fn collect_from_daemon(
    candidates: &[crate::ipc::PeerEndpoint],
    out: &Path,
) -> DaemonCollection {
    let handle = match discover(candidates).await {
        Ok(h) => h,
        Err(e) => return DaemonCollection::Unreachable(e),
    };
    // DESK-31：版本号在 status 那一步就拿定，独立于三份日志要不要得到。
    let status = handle.call("status").await.ok();
    let version = status
        .as_ref()
        .and_then(|v| v["version"].as_str().map(str::to_string));
    let status = status.as_ref().map(status_summary);
    let zip = match handle.call("logs.export").await {
        Ok(v) => v["zip"].as_str().unwrap_or_default().to_string(),
        Err(e) => {
            return DaemonCollection::LogsUnavailable {
                version,
                status,
                reason: format!("后台服务拒绝了 logs.export：{e}"),
            }
        }
    };
    let zip = PathBuf::from(zip);
    match read_zip_entries(&zip) {
        Ok(entries) => {
            let same = match (zip.canonicalize(), out.canonicalize()) {
                (Ok(a), Ok(b)) => a == b,
                _ => zip == out,
            };
            if !same {
                let _ = std::fs::remove_file(&zip);
            }
            DaemonCollection::Complete {
                version,
                status,
                entries,
            }
        }
        Err(e) => DaemonCollection::LogsUnavailable {
            version,
            status,
            reason: format!("后台服务的日志包读不出来：{e}"),
        },
    }
}

// ── 收集 + 落盘 ───────────────────────────────────────────────────────

/// 收集时需要知道的目录与参数（测试注入 tempdir）。
pub struct ExportEnv {
    /// 平台数据目录（config.toml 与 logs/ 在这里）。
    pub platform_dir: PathBuf,
    /// 家目录（脱敏基准）。
    pub home: PathBuf,
    /// 桌面壳版本（`--app-version`）。
    pub app_version: Option<String>,
    /// 输出 zip 路径（`--out`）。
    pub out: PathBuf,
}

impl ExportEnv {
    /// 生产环境：平台目录与家目录都来自 adapter（#1043：不读 HOME/USERPROFILE；
    /// 读不到家目录退回 "."，与壳同口径）。
    pub fn from_process(out: PathBuf, app_version: Option<String>) -> Self {
        use platform::PlatformAdapter as _;
        let adapter = platform::adapter();
        Self {
            platform_dir: adapter.data_dir(),
            home: adapter.home_dir().unwrap_or_else(|| PathBuf::from(".")),
            app_version,
            out,
        }
    }
}

/// 读一份固定位置日志成 [`LogPart`]。
fn log_part(path: Option<PathBuf>, max: u64) -> LogPart {
    let (tail, missing) = persistent_log(path.as_deref(), max);
    LogPart {
        path: path.map(|p| p.display().to_string()),
        tail,
        missing,
    }
}

/// 收集本机事实（不碰常驻服务）+ 常驻服务那部分 → [`BundleInputs`]。
pub fn gather(env: &ExportEnv, daemon: DaemonCollection) -> BundleInputs {
    use platform::PlatformAdapter as _;
    let adapter = platform::adapter();
    // #1043：落点问 daemon_log_paths()（合并了原 default_log_file /
    // startup_stderr_file）。
    let paths = adapter.daemon_log_paths(&env.platform_dir);
    let log_path = paths.log_file.clone();
    let daemon_log = log_part(log_path.clone(), DAEMON_LOG_TAIL);
    // 上一代只在存在时收（还没轮转过不是缺失）。
    let daemon_log_rotated = log_path
        .map(|p| rotated(&p))
        .filter(|p| p.exists())
        .map(|p| log_part(Some(p), DAEMON_LOG_TAIL));
    // #1046：stderr / stdout 不论谁接（Windows daemon 自己、macOS launchd），都在
    // daemon 自己的 `<logs>/` 里——只读这个目录，不读 plist 反推。
    let startup_stderr = paths.stderr.map(|p| log_part(Some(p), SMALL_LOG_TAIL));
    let service_stdout = paths.stdout.map(|p| log_part(Some(p), SMALL_LOG_TAIL));
    let desktop_path = env.platform_dir.join("logs").join("desktop.log");
    let desktop_tail = tail(&desktop_path, SMALL_LOG_TAIL);
    let desktop_log = LogPart {
        path: Some(desktop_path.display().to_string()),
        missing: desktop_tail
            .is_none()
            .then(|| "文件不存在或读不出来（桌面壳还没写过日志）".to_string()),
        tail: desktop_tail,
    };
    let mut inputs = BundleInputs {
        home: env.home.display().to_string(),
        app_version: env.app_version.clone(),
        config_toml: std::fs::read_to_string(
            env.platform_dir.join(crate::config::CONFIG_FILE_NAME),
        )
        .ok(),
        platform: adapter.platform_name().to_string(),
        daemon_log,
        daemon_log_rotated,
        startup_stderr,
        service_stdout,
        desktop_log,
        ..Default::default()
    };
    match daemon {
        DaemonCollection::Complete {
            version,
            status,
            entries,
        } => {
            inputs.daemon_version = version;
            inputs.daemon_status = status;
            inputs.daemon_entries = entries;
        }
        DaemonCollection::LogsUnavailable {
            version,
            status,
            reason,
        } => {
            inputs.daemon_version = version;
            inputs.daemon_status = status;
            inputs.daemon_logs_unavailable = Some(reason);
        }
        DaemonCollection::Unreachable(reason) => {
            inputs.daemon_unreachable = Some(reason);
            // 不在线时，版本号就是本程序自己（与壳问 sidecar `--version`
            // 拿到的整串同形）。
            inputs.daemon_version = Some(format!(
                "{} {}",
                crate::cli::VERSION_PRODUCT,
                crate::daemon_version()
            ));
        }
    }
    inputs
}

/// `diag export` 的本体：收集 → 打包 → 写到 `env.out`。返回 stdout 契约
/// 那行 JSON：`{"zip":"<out>","daemon_reachable":bool}`。常驻服务不在线
/// **不是**失败；只有 zip 写不出来才是。
pub async fn export(env: &ExportEnv) -> Result<serde_json::Value, String> {
    let candidates = resident_endpoints(&env.platform_dir, &env.home);
    let daemon = collect_from_daemon(&candidates, &env.out).await;
    let inputs = gather(env, daemon);
    write_zip(&env.out, &build_bundle(&inputs))?;
    Ok(serde_json::json!({
        "zip": env.out.display().to_string(),
        "daemon_reachable": inputs.daemon_unreachable.is_none(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(entries: &[(String, Vec<u8>)], name: &str) -> Option<String> {
        entries
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, b)| String::from_utf8_lossy(b).to_string())
    }

    fn all_text(entries: &[(String, Vec<u8>)]) -> String {
        entries
            .iter()
            .map(|(n, b)| format!("--- {n}\n{}", String::from_utf8_lossy(b)))
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn names(entries: &[(String, Vec<u8>)]) -> Vec<&str> {
        entries.iter().map(|(n, _)| n.as_str()).collect()
    }

    // ── DESK-40 (#483)：config 摘要（平移自壳）──

    #[test]
    fn desk40_windows_config_summary_is_scrubbed_and_unescaped() {
        let raw = "data_dir = \"C:\\\\Users\\\\alice\\\\Pictures\\\\lib\"\nbind_addr = \"0.0.0.0:41145\"\n";
        let out = config_summary(Some(raw), r"C:\Users\alice");
        assert_eq!(
            out,
            "data_dir  = <LIBRARY>（位于家目录下）\nbind_addr = 0.0.0.0:41145\n"
        );
        assert!(!out.contains("alice"), "username leaked: {out}");
        assert!(!out.contains(r"\\"), "TOML escapes leaked: {out}");
    }

    #[test]
    fn desk40_unix_config_summary_still_scrubbed() {
        let raw = "data_dir = \"/Users/alice/Pictures/lib\"\nbind_addr = \"0.0.0.0:41145\"\n\n[telemetry]\nenabled = false\n";
        assert_eq!(
            config_summary(Some(raw), "/Users/alice"),
            "data_dir  = <LIBRARY>（位于家目录下）\nbind_addr = 0.0.0.0:41145\n"
        );
    }

    #[test]
    fn desk40_missing_fields_and_absent_file() {
        assert_eq!(
            config_summary(Some("[telemetry]\nenabled = false\n"), "/Users/alice"),
            "data_dir  = (未设置)\nbind_addr = (未设置)\n"
        );
        assert!(config_summary(None, "/Users/alice").contains("不存在"));
    }

    #[test]
    fn desk40_broken_config_is_reported_without_echoing_content() {
        let raw = "bind_addr = \"0.0.0.0:41145\"\ndata_dir = \"C:\\\\Users\\\\alice\\\\Pictures\n";
        let out = config_summary(Some(raw), r"C:\Users\alice");
        assert!(out.contains("解析失败"), "{out}");
        assert!(out.contains("第 2 行"), "{out}");
        assert!(!out.contains("alice"), "{out}");
    }

    // ── DESK-10 / 31 / 32 / 63 与 #544（平移自壳，去掉 plist 来源）──

    /// DESK-10 硬判据：常驻服务不可达时也必须出包，且含日志与版本。
    #[test]
    fn bundle_without_daemon_still_carries_logs_and_versions() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            app_version: Some("0.4.0-test.2".into()),
            daemon_version: Some("P-Pass daemon 0.3.0".into()),
            daemon_unreachable: Some("找不到运行中的 P-Pass 后台服务（ipc.token 不存在）".into()),
            config_toml: Some(
                "data_dir = \"/Users/someone/Pictures/lib\"\nbind_addr = \"0.0.0.0:41145\"\n"
                    .into(),
            ),
            platform: "macos".into(),
            daemon_log: LogPart {
                path: Some("/Users/someone/Library/Application Support/P-Pass/logs/daemon.log".into()),
                tail: Some(
                    "Error: migration: migration 2 was previously applied but is missing in the resolved migrations\n"
                        .into(),
                ),
                missing: None,
            },
            ..Default::default()
        };
        let entries = build_bundle(&i);
        let n = names(&entries);
        for want in [
            "README.txt",
            "versions.txt",
            "config-summary.txt",
            "log-sources.txt",
            "daemon.log",
            "daemon-unreachable.txt",
        ] {
            assert!(n.contains(&want), "缺 {want}：{n:?}");
        }
        let text = all_text(&entries);
        assert!(text.contains("app_version    = 0.4.0-test.2"), "{text}");
        assert!(
            text.contains("daemon_version = P-Pass daemon 0.3.0"),
            "{text}"
        );
        assert!(text.contains("platform       = macos"), "{text}");
        assert!(
            text.contains(
                "migration 2 was previously applied but is missing in the resolved migrations"
            ),
            "{text}"
        );
        assert!(!text.contains("/Users/someone"), "{text}");
        assert!(
            text.contains("data_dir  = <LIBRARY>（位于家目录下）"),
            "{text}"
        );
    }

    /// 拍板口径 2：包里不再有 plist 来源的那两份，README / log-sources 不提 plist。
    #[test]
    fn bundle_has_no_launchd_plist_sources() {
        let entries = build_bundle(&BundleInputs::default());
        let n = names(&entries);
        assert!(!n.contains(&"daemon-stdout.log"), "{n:?}");
        let text = all_text(&entries);
        for gone in [
            "plist",
            "LaunchAgent",
            "StandardOutPath",
            "StandardErrorPath",
        ] {
            assert!(!text.contains(gone), "{gone} 不该再出现：{text}");
        }
        assert!(text.contains("app_version    = (未提供)"), "{text}");
    }

    #[test]
    fn bundle_with_daemon_adds_diag_devices_audit() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            daemon_version: Some("0.4.0".into()),
            daemon_entries: vec![
                ("diag_events.json".into(), b"[]".to_vec()),
                ("devices.json".into(), b"[]".to_vec()),
                ("audit.json".into(), b"[]".to_vec()),
            ],
            ..Default::default()
        };
        let entries = build_bundle(&i);
        let n = names(&entries);
        for want in ["diag_events.json", "devices.json", "audit.json"] {
            assert!(n.contains(&want), "缺 {want}：{n:?}");
        }
        assert!(!n.contains(&"daemon-unreachable.txt"), "{n:?}");
        assert!(all_text(&entries).contains("daemon_reachable = yes"));
    }

    /// DESK-10 补漏：常驻服务给的 JSON 也要过 scrub。
    #[test]
    fn daemon_entries_are_scrubbed_at_the_bundle_boundary() {
        let node = "c4".repeat(32);
        let audit = format!(
            "[{{\"actor_prefix\": \"abababab\", \"detail\": \
             \"外部删除 /Users/someone/lib/originals/{node}/2026/08/a.jpg\"}}]"
        );
        let i = BundleInputs {
            home: "/Users/someone".into(),
            daemon_entries: vec![("audit.json".into(), audit.into_bytes())],
            ..Default::default()
        };
        let text = entry(&build_bundle(&i), "audit.json").expect("audit.json 必须在包里");
        assert!(!text.contains(&node), "全长 NodeId 泄漏了: {text}");
        assert!(text.contains("c4c4c4c4…<masked>"), "{text}");
        let v: serde_json::Value = serde_json::from_str(&text).expect("scrub 后仍是合法 JSON");
        assert_eq!(v[0]["actor_prefix"], "abababab", "{text}");
        assert!(!text.contains("/Users/someone"), "家目录也要脱敏: {text}");
    }

    #[test]
    fn long_hex_is_masked_to_a_prefix() {
        let node = "ab".repeat(32);
        let masked = scrub_full(&format!("peer {node} connected"), "", None);
        assert!(masked.contains("abababab…<masked>"), "{masked}");
        assert!(!masked.contains(&node), "{masked}");
        assert_eq!(scrub_full("port 41145 beef", "", None), "port 41145 beef");
    }

    /// #544 硬判据：整包公开也不能带出能连上设备、定位或识别用户的信息。
    #[test]
    fn issue544_public_bundle_leaks_no_address_identifier_or_name() {
        let vectors: serde_json::Value =
            serde_json::from_str(include_str!("../../../assets/privacy/redact-vectors.json"))
                .unwrap();
        let blob: String = ["exact", "export"]
            .iter()
            .flat_map(|g| vectors[*g].as_array().unwrap().iter())
            .map(|c| format!("{}\n", c["in"].as_str().unwrap()))
            .collect();
        let library = "/Volumes/Zhang San Disk/Photos";
        let devices =
            "[{\"node_id_prefix\": \"eaeaeaea\", \"name\": \"张三的手机\", \"role\": \"member\"}]";
        let part = |t: String| LogPart {
            path: Some("/Users/someone/Library/Application Support/P-Pass/logs/x.log".into()),
            tail: Some(t),
            missing: None,
        };
        let i = BundleInputs {
            home: "/Users/someone".into(),
            app_version: Some("0.6.1".into()),
            daemon_version: Some("0.6.1".into()),
            daemon_unreachable: Some(format!("dial 203.0.113.7:4433 failed\n{blob}")),
            config_toml: Some(format!(
                "data_dir = \"{library}\"\nbind_addr = \"203.0.113.7:41145\"\n"
            )),
            daemon_log: part(format!("{blob}ingest {library}/originals/x.jpg ok\n")),
            daemon_log_rotated: Some(part(blob.clone())),
            startup_stderr: Some(part(blob.clone())),
            service_stdout: Some(part(blob.clone())),
            desktop_log: part(blob.clone()),
            daemon_entries: vec![
                ("devices.json".into(), devices.as_bytes().to_vec()),
                (
                    "diag_events.json".into(),
                    serde_json::to_vec(&blob).unwrap(),
                ),
                ("audit.json".into(), vec![0xff, 0xfe, 0x00, 0x41]),
            ],
            ..Default::default()
        };
        let tmp = tempfile::tempdir().unwrap();
        let zip = tmp.path().join("out.zip");
        write_zip(&zip, &build_bundle(&i)).unwrap();
        let back = read_zip_entries(&zip).unwrap();
        let mut text = String::new();
        for (name, bytes) in &back {
            let t = std::str::from_utf8(bytes)
                .unwrap_or_else(|_| panic!("{name} 不是 UTF-8——未经脱敏的字节进了包"));
            text.push_str(t);
        }
        for needle in [
            "张三",
            "Zhang San",
            "Li Si",
            "王五",
            "wangwu",
            "Alice",
            "alice",
            "家庭",
            "zhangsan",
            "IMG_0001",
            "DSC",
            "family-example",
            "203.0.113.",
            "198.51.100.",
            "2001:db8",
            "/Users/someone",
        ] {
            assert!(!text.contains(needle), "{needle} leaked:\n{text}");
        }
        assert!(text.contains("<LIBRARY>/originals/<file>.jpg"), "{text}");
        assert!(text.contains("<LIBRARY>（不在家目录下）"), "{text}");
        assert_no_leak(&text);
    }

    /// 独立检测器（#544）：公网 IP、≥24 位 hex、≥32 位含数字的不透明串一个都不许有。
    fn assert_no_leak(text: &str) {
        use std::net::{IpAddr, Ipv4Addr};
        let public_v4 = |v4: Ipv4Addr| {
            let o = v4.octets();
            !(v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_unspecified()
                || (o[0] == 100 && (64..128).contains(&o[1])))
        };
        let public = |ip: IpAddr| match ip {
            IpAddr::V4(v4) => public_v4(v4),
            IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
                Some(v4) => public_v4(v4),
                None => {
                    !(v6.is_loopback()
                        || v6.is_unspecified()
                        || (v6.segments()[0] & 0xfe00) == 0xfc00
                        || (v6.segments()[0] & 0xffc0) == 0xfe80)
                }
            },
        };
        for tok in text.split(|c: char| !(c.is_ascii_hexdigit() || c == ':' || c == '.')) {
            for cand in [tok, tok.trim_matches(|c| c == ':' || c == '.')] {
                if let Ok(ip) = cand.parse::<IpAddr>() {
                    assert!(!public(ip), "public IP {ip} leaked");
                }
                if let Some((a, port)) = cand.rsplit_once(':') {
                    if port.bytes().all(|b| b.is_ascii_digit()) {
                        if let Ok(v4) = a.parse::<Ipv4Addr>() {
                            assert!(!public_v4(v4), "public IP {v4} leaked");
                        }
                    }
                }
            }
        }
        let mut run = 0usize;
        for ch in text.chars() {
            run = if ch.is_ascii_hexdigit() { run + 1 } else { 0 };
            assert!(run < 24, "≥24-char hex run leaked");
        }
        for tok in text.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-')) {
            let digits = tok.bytes().filter(u8::is_ascii_digit).count();
            assert!(tok.len() < 32 || digits < 2, "opaque token leaked: {tok}");
        }
    }

    #[test]
    fn desk32_missing_daemon_log_is_reported_not_silently_omitted() {
        let i = BundleInputs {
            home: r"C:\Users\someone".into(),
            daemon_log: LogPart {
                path: Some(r"C:\Users\someone\AppData\Local\P-Pass\logs\daemon.log".into()),
                tail: None,
                missing: Some("日志文件不存在".into()),
            },
            ..Default::default()
        };
        let entries = build_bundle(&i);
        assert!(entry(&entries, "daemon.log").is_none());
        let note = entry(&entries, "daemon-log-missing.txt")
            .expect("a missing daemon.log must be explained in the bundle");
        assert!(note.contains("日志文件不存在"), "{note}");
        assert!(
            note.contains(r"<DATA>\AppData\Local\P-Pass\logs\daemon.log"),
            "{note}"
        );
        assert!(!note.contains("someone"), "home must be scrubbed: {note}");
        let src = entry(&entries, "log-sources.txt").unwrap();
        assert!(
            src.starts_with(r"daemon.log（固定位置）= <DATA>\AppData\Local\P-Pass\logs\daemon.log —— 未收入：日志文件不存在"),
            "{src}"
        );
    }

    #[test]
    fn desk32_log_sources_says_when_the_daemon_log_is_included() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            daemon_log: LogPart {
                path: Some("/Users/someone/P-Pass/logs/daemon.log".into()),
                tail: Some("INFO hello\n".into()),
                missing: None,
            },
            ..Default::default()
        };
        let entries = build_bundle(&i);
        assert!(entry(&entries, "daemon-log-missing.txt").is_none());
        let src = entry(&entries, "log-sources.txt").unwrap();
        assert!(
            src.starts_with("daemon.log（固定位置）= <DATA>/P-Pass/logs/daemon.log —— 已收入包内"),
            "{src}"
        );
    }

    #[test]
    fn desk32_persistent_log_names_each_reason() {
        let dir = tempfile::tempdir().unwrap();
        let present = dir.path().join("daemon.log");
        std::fs::write(&present, "INFO up\n").unwrap();
        assert_eq!(
            persistent_log(Some(&present), 1024),
            (Some("INFO up\n".to_string()), None)
        );
        let (t, why) = persistent_log(Some(&dir.path().join("absent.log")), 1024);
        assert!(t.is_none());
        assert!(why.unwrap().contains("不存在"));
        let (t, why) = persistent_log(None, 1024);
        assert!(t.is_none());
        assert!(why.unwrap().contains("本平台没有"));
    }

    /// 拍板口径 2：轮转出来的上一段同样收进包、同样脱敏。
    #[test]
    fn rotated_daemon_log_is_included_and_scrubbed() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            daemon_log_rotated: Some(LogPart {
                path: Some("/Users/someone/P-Pass/logs/daemon.log.1".into()),
                tail: Some("INFO older at /Users/someone/x\n".into()),
                missing: None,
            }),
            ..Default::default()
        };
        let entries = build_bundle(&i);
        let log = entry(&entries, "daemon.log.1").expect("daemon.log.1 必须在包里");
        assert!(log.contains("INFO older"), "{log}");
        assert!(!log.contains("/Users/someone"), "{log}");
        let src = entry(&entries, "log-sources.txt").unwrap();
        assert!(
            src.contains("daemon.log.1（上一段）= <DATA>/P-Pass/logs/daemon.log.1 —— 已收入包内"),
            "{src}"
        );
    }

    #[test]
    fn startup_stderr_is_included_when_the_platform_has_one() {
        let i = BundleInputs {
            startup_stderr: Some(LogPart {
                path: Some(r"C:\x\logs\daemon.err".into()),
                tail: Some("库目录不存在\n".into()),
                missing: None,
            }),
            ..Default::default()
        };
        let entries = build_bundle(&i);
        assert_eq!(
            entry(&entries, "daemon-stderr.log").as_deref(),
            Some("库目录不存在\n")
        );
        let none = build_bundle(&BundleInputs::default());
        assert!(entry(&none, "daemon-stderr.log").is_none());
        assert!(entry(&none, "log-sources.txt")
            .unwrap()
            .contains("启动早期 stderr = (本平台没有固定落点)"));
    }

    #[test]
    fn zip_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("nested").join("out.zip");
        write_zip(&p, &[("a.txt".into(), b"hello".to_vec())]).unwrap();
        let back = read_zip_entries(&p).unwrap();
        assert_eq!(back, vec![("a.txt".to_string(), b"hello".to_vec())]);
    }

    /// DESK-31：服务在线但三份没拿到——三态的 partial，版本是在线自报的。
    #[test]
    fn bundle_with_live_daemon_but_no_logs_marks_partial() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            daemon_version: Some("9.9.9-fake".into()),
            daemon_logs_unavailable: Some("后台服务拒绝了 logs.export：模拟拒绝".into()),
            ..Default::default()
        };
        let entries = build_bundle(&i);
        let n = names(&entries);
        assert!(n.contains(&"daemon-logs-unavailable.txt"), "{n:?}");
        assert!(!n.contains(&"daemon-unreachable.txt"), "{n:?}");
        let text = all_text(&entries);
        assert!(text.contains("daemon_version = 9.9.9-fake"), "{text}");
        assert!(
            text.contains("daemon_reachable = partial (online, logs unavailable)"),
            "{text}"
        );
        let note = entry(&entries, "daemon-logs-unavailable.txt").unwrap();
        assert!(note.contains("在线"), "{note}");
        assert!(note.contains("两回事"), "{note}");
    }

    #[test]
    fn versions_txt_scrubs_daemon_and_app_version() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            app_version: Some("1.0+/Users/someone".into()),
            daemon_version: Some("9.9.9+私货/Users/someone".into()),
            ..Default::default()
        };
        let text = all_text(&build_bundle(&i));
        assert!(!text.contains("/Users/someone"), "{text}");
        assert!(text.contains("<DATA>"), "{text}");
    }

    /// DESK-63 (#946)：壳日志按固定路径收进包，照常脱敏。拍板口径 3：脱敏
    /// 不放宽——文件名 `desktop.log` 不在安全名单里，路径里同样被打码。
    #[test]
    fn desk63_bundle_carries_the_shell_state_log() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            desktop_log: LogPart {
                path: Some(
                    "/Users/someone/Library/Application Support/P-Pass/logs/desktop.log".into(),
                ),
                tail: Some(
                    "at_ms=1 event=state from=starting to=running reason=event stream open at /Users/someone\n"
                        .into(),
                ),
                missing: None,
            },
            ..Default::default()
        };
        let entries = build_bundle(&i);
        let log = entry(&entries, "desktop.log").expect("desktop.log must be in the bundle");
        assert!(log.contains("from=starting to=running"), "{log}");
        assert!(
            !log.contains("/Users/someone"),
            "home must be scrubbed: {log}"
        );
        let src = entry(&entries, "log-sources.txt").unwrap();
        assert!(src.contains("desktop.log（桌面壳）"), "{src}");
        assert!(src.contains("已收入包内"), "{src}");
        assert!(
            src.contains("/logs/<file>.log"),
            "脱敏不放宽：desktop.log 文件名照常打码：{src}"
        );
    }

    #[test]
    fn desk63_missing_shell_log_is_reported() {
        let i = BundleInputs {
            home: "/Users/someone".into(),
            desktop_log: LogPart {
                path: Some(
                    "/Users/someone/Library/Application Support/P-Pass/logs/desktop.log".into(),
                ),
                tail: None,
                missing: Some("文件不存在".into()),
            },
            ..Default::default()
        };
        let entries = build_bundle(&i);
        assert!(entry(&entries, "desktop.log").is_none());
        let note = entry(&entries, "desktop-log-missing.txt").expect("must be explained");
        assert!(note.contains("文件不存在"), "{note}");
        assert!(!note.contains("someone"), "{note}");
        assert!(entry(&entries, "log-sources.txt")
            .unwrap()
            .contains("未收入：文件不存在"));
    }

    // ── 收集（真文件系统，tempdir）──

    /// gather 读的是平台目录下 logs/ 里的那几份，不碰别处；常驻服务不可达
    /// 时版本号是本程序自己的整串。
    /// #1115：status.json 只收白名单里的几项；不在线就没有这份。
    /// 反证：status_summary 改成原样返回 ⇒ 路径那项进包，红。
    #[test]
    fn status_json_carries_only_the_whitelisted_fields() {
        let full = serde_json::json!({
            "version": "1.2.3", "state": "idle", "photo_count": 46, "pid": 42, "started_at": 7,
            "library_dir": "/Users/someone/Pictures/Lib", "msg_key": "x",
        });
        let summary = status_summary(&full);
        let keys: Vec<&String> = summary.as_object().unwrap().keys().collect();
        assert_eq!(keys.len(), STATUS_FIELDS.len(), "{summary}");
        assert!(summary.get("library_dir").is_none());
        let inputs = BundleInputs {
            daemon_status: Some(summary),
            ..Default::default()
        };
        let entries = build_bundle(&inputs);
        let status = entry(&entries, "status.json").expect("在线时要有 status.json");
        assert!(status.contains("\"photo_count\": 46"), "{status}");
        assert!(!status.contains("Pictures"), "{status}");
        let offline = build_bundle(&BundleInputs::default());
        assert!(entry(&offline, "status.json").is_none());
    }

    #[test]
    fn gather_reads_own_logs_dir_and_reports_own_version_when_offline() {
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("platform");
        let logs = platform_dir.join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(logs.join("desktop.log"), "shell line\n").unwrap();
        std::fs::write(
            platform_dir.join("config.toml"),
            "data_dir = \"/lib\"\nbind_addr = \"0.0.0.0:41145\"\n",
        )
        .unwrap();
        let env = ExportEnv {
            platform_dir: platform_dir.clone(),
            home: tmp.path().to_path_buf(),
            app_version: Some("0.9.9".into()),
            out: tmp.path().join("out.zip"),
        };
        let i = gather(&env, DaemonCollection::Unreachable("no".into()));
        assert_eq!(i.desktop_log.tail.as_deref(), Some("shell line\n"));
        assert_eq!(
            i.daemon_version,
            Some(format!("P-Pass daemon {}", crate::daemon_version()))
        );
        assert!(i.config_toml.unwrap().contains("41145"));
        assert!(!i.platform.is_empty());
    }

    /// #1046：服务管理器接的 stdout/stderr（macOS launchd）也在 `<logs>/` 里，
    /// 诊断包照收；Windows 是 daemon 自己接的 stderr。所有落点都在本平台目录的
    /// logs 下——不读 plist、不读 `~/Library/Logs`。
    /// 反证：gather 退回「服务管理器接的不收」→ macOS 上 stderr 那条红。
    #[test]
    fn gather_collects_the_service_stdio_from_the_logs_dir() {
        use platform::PlatformAdapter as _;
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("platform");
        let logs = platform_dir.join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        let paths = platform::adapter().daemon_log_paths(&platform_dir);
        for p in [&paths.log_file, &paths.stdout, &paths.stderr]
            .into_iter()
            .flatten()
        {
            assert!(
                p.starts_with(&logs),
                "日志落点必须在 logs 目录里：{}",
                p.display()
            );
        }
        if let Some(p) = &paths.stderr {
            std::fs::write(p, "panicked at boot\n").unwrap();
        }
        if let Some(p) = &paths.stdout {
            std::fs::write(p, "stdout line\n").unwrap();
        }
        let env = ExportEnv {
            platform_dir: platform_dir.clone(),
            home: tmp.path().to_path_buf(),
            app_version: None,
            out: tmp.path().join("out.zip"),
        };
        let i = gather(&env, DaemonCollection::Unreachable("no".into()));
        if paths.stderr.is_some() {
            let e = i.startup_stderr.as_ref().expect("stderr 要收");
            assert_eq!(e.tail.as_deref(), Some("panicked at boot\n"));
        }
        if paths.stdout.is_some() {
            let o = i.service_stdout.as_ref().expect("stdout 要收");
            assert_eq!(o.tail.as_deref(), Some("stdout line\n"));
            let entries = build_bundle(&i);
            assert_eq!(
                entry(&entries, "daemon-stdout.log").as_deref(),
                Some("stdout line\n")
            );
        }
    }
}
