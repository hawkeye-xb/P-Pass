//! Platform — PlatformAdapter trait + Windows/macOS implementations
//! (T-040, 架构 §4 原样实施).
//!
//! Architecture enforcement: this is the ONLY crate allowed to use
//! `#[cfg(windows)]` / `#[cfg(target_os = "macos")]` (rule B.2).
//!
//! The pure parsers (`pmset` / `powercfg` output → [`PowerHint`]) are
//! platform-independent functions so both are unit-tested everywhere;
//! only the syscall/process wrappers live behind cfg.

use std::path::PathBuf;

#[cfg(target_os = "macos")]
mod macos;
// QA-09 迁移（#211）：macOS 与 Linux 共享的 unix 实现。迁过来的分叉里有
// 3 处是 `#[cfg(unix)]`（同时覆盖两者），没有共享模块就得抄两遍。
#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;

#[cfg(target_os = "macos")]
pub use macos::MacosAdapter;
#[cfg(windows)]
pub use windows::WindowsAdapter;

/// How the daemon stays resident on this platform (§4 对照表).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceMode {
    /// User-level autostart process (registry Run key + watchdog).
    UserAutostart,
    /// LaunchAgent with KeepAlive (crash-restart built in).
    LaunchAgent,
}

/// Current sleep policy, for the first-run wizard's diagnosis (T-042).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PowerHint {
    /// The machine never sleeps on idle — backups run unattended.
    NeverSleeps,
    /// Sleeps after this many idle minutes — the wizard offers a fix.
    SleepsWhenIdle { minutes: u32 },
    /// Could not determine (parse failure, exotic setup).
    Unknown,
}

/// Keeps the system awake while alive (RAII). Dropping releases the
/// assertion. MVP 尽力而为：合盖必睡等平台边界由诊断文案覆盖（§4）。
pub struct AwakeGuard {
    #[allow(dead_code)] // the handle's Drop is the whole point
    inner: AwakeGuardImpl,
}

#[cfg(target_os = "macos")]
type AwakeGuardImpl = macos::CaffeinateGuard;
#[cfg(windows)]
type AwakeGuardImpl = windows::ExecutionStateGuard;
#[cfg(not(any(target_os = "macos", windows)))]
type AwakeGuardImpl = ();

/// Device private-key storage (DPAPI / Keychain).
pub trait KeyStore {
    fn store(&self, name: &str, secret: &[u8]) -> Result<()>;
    fn load(&self, name: &str) -> Result<Option<Vec<u8>>>;
    fn delete(&self, name: &str) -> Result<()>;
}

#[derive(Debug, thiserror::Error)]
pub enum PlatformError {
    #[error("{action}: {source}")]
    Io {
        action: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("{action}: {detail}")]
    Failed {
        action: &'static str,
        detail: String,
    },
    /// DESK-22 (#171)：用户在系统授权弹窗上点了**取消**。
    ///
    /// 单开一个变体而不是并进 `Failed`：取消不是失败，是用户的选择。
    /// 混在一起，调用方要么把取消当错误吓人一跳，要么干脆吞掉假装成功。
    #[error("{action}: 用户取消了授权")]
    Cancelled { action: &'static str },
}

pub type Result<T> = std::result::Result<T, PlatformError>;

/// DAE-05：卷容量水位（`free` 对齐 unix `statvfs` 的 `f_bavail` 语义）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VolumeStats {
    pub free: u64,
    pub total: u64,
}

/// QA-09 迁移（#211）：一个平台动作的结果口径。
///
/// 为什么不用 `Result<()>`：`Ok(())` 会把「这个平台上其实什么都没做」
/// 说成成功。本仓这一轮在修的缺陷全是这个形状——#189 的 paths 让必需
/// 检查永不汇报、#192 的清理脚本静默不删、#268 的 0 字节 daemon 注册完
/// 报 resident。三个变体把「做了 / 没实现 / 不需要」分开，调用方就没法
/// 把缺口当成完成。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Applied {
    /// 本平台做了这件事。
    Done,
    /// 本平台**没有实现**——已知缺口，别当成做过了。
    Unsupported,
    /// 本平台**机制上不需要**做这件事，不是缺口。
    /// 例：Windows 的命名管道不在文件系统留端点，没有残留要清。
    NotApplicable,
}

/// 架构 §4 trait —— 签名原样实施（updater/notify 的完整实现随
/// T-041/T-062 落地，此处为可用的最小形态）.
pub trait PlatformAdapter: Send + Sync {
    // 生命周期
    fn install_autostart(&self, exec: &std::path::Path) -> Result<()>;
    fn autostart_installed(&self) -> Result<bool>;
    fn uninstall_autostart(&self) -> Result<()>;
    fn service_mode(&self) -> ServiceMode;
    // 安全
    fn key_store(&self) -> Box<dyn KeyStore>;
    // 电源（MVP 尽力而为）
    fn assert_awake(&self) -> Result<AwakeGuard>;
    fn power_hint(&self) -> PowerHint;
    // 系统集成
    fn notify(&self, title: &str, body: &str);
    fn data_dir(&self) -> PathBuf;
    /// DEVLOG-02：daemon 在 `PPF_LOG_FILE` 未设时的**平台默认**日志文件。
    ///
    /// macOS 返回 `None`：launchd plist 的 `StandardErrorPath` 已经把 stderr
    /// 重定向到文件，再叠一层只会写两份。Windows 必须返回 `Some`：HKCU Run
    /// 键没有任何重定向能力，release 又不再分配控制台，不落盘就等于没有日志。
    /// DAE-05：`path` 所在卷的容量水位。`None` = 本平台没有实现（调用方
    /// 应当序列化成 null，而不是编一个数字出来）。
    ///
    /// `free` 的语义**必须**是「无特权写入者真正可用的字节数」，对齐 unix
    /// 侧 `statvfs` 的 `f_bavail`（也就是 `df` / Finder 显示的那个数），
    /// 而不是卷上的物理空闲量——两者在有配额/保留区的卷上不一样。
    fn volume_stats(&self, path: &std::path::Path) -> Option<VolumeStats> {
        let _ = path;
        None
    }

    /// 入参是**生效的** data dir（由调用方解析 env / 平台约定后给出），
    /// 因为一次性 daemon 靠 `PPF_DATA_DIR` 做隔离，日志不跟着走就会污染
    /// 真实日志文件。默认实现返回 `None`——既无 launchd 托管也无 Run 键的
    /// 平台自己决定。
    fn default_log_file(&self, data_dir: &std::path::Path) -> Option<PathBuf> {
        let _ = data_dir;
        None
    }

    /// QA-09 迁移（#211）：把文件权限收紧到「只有属主可读写」。
    ///
    /// 用在身份密钥这类文件上。默认实现返回 [`Applied::Unsupported`] 而
    /// **不是** `Ok(Applied::Done)`——没实现却报做过了，正是这套口径要防的。
    fn restrict_to_owner(&self, path: &std::path::Path) -> Result<Applied> {
        let _ = path;
        Ok(Applied::Unsupported)
    }

    /// QA-09 迁移（#211）：把本进程自己的 stderr 截断到 0 字节。
    ///
    /// 日志洪水防线的最后一环（前面还有「折叠重复行」那道，那道是所有
    /// 平台共同的主防线）。只有当 stderr 被托管方重定向到文件时才有意义。
    fn truncate_own_stderr(&self) -> Applied {
        Applied::Unsupported
    }

    /// DESK-22 (#171)：关掉「空闲自动睡眠」，让备份能在无人值守时跑完。
    ///
    /// 两个平台都要走系统的授权弹窗（macOS 是 Touch ID/密码，Windows 是
    /// UAC），所以 `Err(PlatformError::Cancelled)` 是**正常路径之一**，
    /// 调用方必须把它和真失败分开呈现。
    ///
    /// ⚠️ 实现方**必须回读确认**再返回 `Done`。Windows 上实测过：
    /// `powercfg /x standby-timeout-ac 0` 在非管理员下**退出码是 0，但注册表
    /// 根本没被写**（用注册表键的最后写入时间比对出来的）。拿退出码当"已
    /// 生效"就是本仓这一轮在修的那类缺陷——静默没做却报成功。
    fn disable_auto_sleep(&self) -> Result<Applied> {
        Ok(Applied::Unsupported)
    }

    /// QA-09 迁移（#211）：清掉被强杀的前任留在文件系统里的 IPC 端点。
    ///
    /// 默认 [`Applied::NotApplicable`]：只有 unix domain socket 会落文件，
    /// 命名管道这类端点不存在「残留」这个问题。
    fn remove_stale_ipc_endpoint(&self, name: &str) -> Applied {
        let _ = name;
        Applied::NotApplicable
    }
}

/// The adapter for the current platform.
#[cfg(target_os = "macos")]
pub fn adapter() -> impl PlatformAdapter {
    MacosAdapter::new()
}
#[cfg(windows)]
pub fn adapter() -> impl PlatformAdapter {
    WindowsAdapter::new()
}
/// Headless/server platforms (Linux cloud boxes run the daemon too):
/// data dir follows XDG; desktop-only capabilities answer honestly.
#[cfg(not(any(target_os = "macos", windows)))]
pub fn adapter() -> impl PlatformAdapter {
    HeadlessAdapter
}

#[cfg(not(any(target_os = "macos", windows)))]
pub struct HeadlessAdapter;

#[cfg(not(any(target_os = "macos", windows)))]
impl PlatformAdapter for HeadlessAdapter {
    fn install_autostart(&self, _exec: &std::path::Path) -> Result<()> {
        Err(PlatformError::Failed {
            action: "autostart",
            detail: "unsupported on this platform (use systemd)".into(),
        })
    }
    fn autostart_installed(&self) -> Result<bool> {
        Ok(false)
    }
    fn uninstall_autostart(&self) -> Result<()> {
        Ok(())
    }
    fn service_mode(&self) -> ServiceMode {
        ServiceMode::UserAutostart
    }
    fn key_store(&self) -> Box<dyn KeyStore> {
        Box::new(NoKeyStore)
    }
    fn assert_awake(&self) -> Result<AwakeGuard> {
        // Servers don't idle-sleep; a no-op guard keeps callers simple.
        Ok(AwakeGuard { inner: () })
    }
    fn power_hint(&self) -> PowerHint {
        PowerHint::NeverSleeps
    }
    fn notify(&self, _title: &str, _body: &str) {}
    fn data_dir(&self) -> PathBuf {
        let base = std::env::var("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
                    .join(".local/share")
            });
        base.join("p-pass")
    }

    // QA-09 迁移（#211）：headless 平台实际上就是 Linux（unix），四个能力
    // 直接走共享的 unix 实现。这里的 cfg 在 platform crate 内部，是 B.2
    // 规则的自留地。`not(unix)` 那半保持诚实的「没实现」，不编数字。
    fn volume_stats(&self, path: &std::path::Path) -> Option<VolumeStats> {
        #[cfg(unix)]
        {
            crate::unix::volume_stats(path)
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            None
        }
    }
    fn restrict_to_owner(&self, path: &std::path::Path) -> Result<Applied> {
        #[cfg(unix)]
        {
            crate::unix::restrict_to_owner(path)
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            Ok(Applied::Unsupported)
        }
    }
    fn truncate_own_stderr(&self) -> Applied {
        #[cfg(unix)]
        {
            crate::unix::truncate_own_stderr()
        }
        #[cfg(not(unix))]
        {
            Applied::Unsupported
        }
    }
    fn remove_stale_ipc_endpoint(&self, name: &str) -> Applied {
        #[cfg(unix)]
        {
            crate::unix::remove_stale_ipc_endpoint(name)
        }
        #[cfg(not(unix))]
        {
            let _ = name;
            Applied::NotApplicable
        }
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
struct NoKeyStore;

#[cfg(not(any(target_os = "macos", windows)))]
impl KeyStore for NoKeyStore {
    fn store(&self, _name: &str, _secret: &[u8]) -> Result<()> {
        Err(PlatformError::Failed {
            action: "key store",
            detail: "no secure store on this platform".into(),
        })
    }
    fn load(&self, _name: &str) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }
    fn delete(&self, _name: &str) -> Result<()> {
        Ok(())
    }
}

// ── Pure parsers (unit-tested on every platform) ─────────────────────

/// Parse `pmset -g custom` output: the smallest positive `sleep` value
/// across power profiles wins (the machine sleeps whenever the current
/// profile says so); 0 = never.
pub fn parse_pmset(output: &str) -> PowerHint {
    let mut min_positive: Option<u32> = None;
    let mut saw_sleep = false;
    for line in output.lines() {
        let t = line.trim();
        // ` sleep    10` — exact key match, not displaysleep/disksleep.
        let mut parts = t.split_whitespace();
        if parts.next() == Some("sleep") {
            if let Some(v) = parts.next().and_then(|v| v.parse::<u32>().ok()) {
                saw_sleep = true;
                if v > 0 {
                    min_positive = Some(min_positive.map_or(v, |m| m.min(v)));
                }
            }
        }
    }
    match (saw_sleep, min_positive) {
        (true, None) => PowerHint::NeverSleeps,
        (true, Some(minutes)) => PowerHint::SleepsWhenIdle { minutes },
        (false, _) => PowerHint::Unknown,
    }
}

/// Parse `powercfg /query <scheme> SUB_SLEEP STANDBYIDLE` style output:
/// the current AC setting index is seconds (0 = never).
pub fn parse_powercfg(output: &str) -> PowerHint {
    for line in output.lines() {
        let t = line.trim();
        // "Current AC Power Setting Index: 0x00000384"
        if let Some(rest) = t
            .strip_prefix("Current AC Power Setting Index:")
            .map(str::trim)
        {
            let seconds = if let Some(hex) = rest.strip_prefix("0x") {
                u32::from_str_radix(hex, 16).ok()
            } else {
                rest.parse::<u32>().ok()
            };
            return match seconds {
                Some(0) => PowerHint::NeverSleeps,
                Some(s) => PowerHint::SleepsWhenIdle {
                    minutes: s.div_ceil(60),
                },
                None => PowerHint::Unknown,
            };
        }
    }
    PowerHint::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pmset_sleep_zero_means_never() {
        let out = "System-wide power settings:\nCurrently in use:\n standby 1\n sleep 0\n displaysleep 10\n";
        assert_eq!(parse_pmset(out), PowerHint::NeverSleeps);
    }

    #[test]
    fn pmset_positive_sleep_reports_minutes() {
        let out = "Battery Power:\n sleep 10\nAC Power:\n sleep 30\n";
        assert_eq!(parse_pmset(out), PowerHint::SleepsWhenIdle { minutes: 10 });
    }

    #[test]
    fn pmset_displaysleep_is_not_system_sleep() {
        let out = " displaysleep 5\n disksleep 10\n";
        assert_eq!(parse_pmset(out), PowerHint::Unknown);
    }

    #[test]
    fn powercfg_hex_seconds_to_minutes() {
        let out = "  Current AC Power Setting Index: 0x00000384\n"; // 900 s
        assert_eq!(
            parse_powercfg(out),
            PowerHint::SleepsWhenIdle { minutes: 15 }
        );
    }

    #[test]
    fn powercfg_zero_means_never() {
        let out = "Current AC Power Setting Index: 0x00000000";
        assert_eq!(parse_powercfg(out), PowerHint::NeverSleeps);
    }

    #[test]
    fn powercfg_garbage_is_unknown() {
        assert_eq!(parse_powercfg("no such section"), PowerHint::Unknown);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_plist_keepalive_spares_clean_exit() {
        // DAE-02 缺陷①：退位实例 exit(0) 后 launchd 不得重拉（无条件
        // KeepAlive 会把它无限复活成 churn）。plist 必须是
        // SuccessfulExit=false 语义——成功退出不重拉、崩溃/被杀才复活。
        let plist = macos::agent_plist(std::path::Path::new(
            "/Applications/P-Pass.app/Contents/MacOS/ppf-daemon",
        ));
        assert!(
            plist.contains("<key>SuccessfulExit</key><false/>"),
            "clean exit (stand-down) must not relaunch: {plist}"
        );
        assert!(
            !plist.contains("<key>KeepAlive</key><true/>"),
            "unconditional KeepAlive would churn a stepped-down instance: {plist}"
        );
        assert!(
            plist.contains("<key>RunAtLoad</key><true/>"),
            "RunAtLoad must stay"
        );
    }
}
