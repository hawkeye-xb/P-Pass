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
}

pub type Result<T> = std::result::Result<T, PlatformError>;

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
}
