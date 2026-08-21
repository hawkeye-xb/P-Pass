//! macOS adapter (§4 对照表右列).
//!
//! - Autostart: LaunchAgent plist (`RunAtLoad` + `KeepAlive` — crash
//!   restart comes free) + `launchctl bootstrap/bootout`.
//! - Awake: a `caffeinate -i` child process held RAII-style — zero FFI,
//!   visible in `pmset -g assertions` (the smoke check). IOKit
//!   assertions are the Phase-2 upgrade, interface unchanged.
//! - Keys: the login Keychain via the `security` CLI (generic password).
//! - Power hint: `pmset -g custom` through the shared pure parser.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{AwakeGuard, KeyStore, PlatformAdapter, PlatformError, PowerHint, Result, ServiceMode};

const AGENT_LABEL: &str = "com.p-pass.daemon";
const KEYCHAIN_SERVICE: &str = "P-Pass";

pub struct MacosAdapter;

impl MacosAdapter {
    pub fn new() -> Self {
        Self
    }

    fn agent_plist_path() -> PathBuf {
        home().join(format!("Library/LaunchAgents/{AGENT_LABEL}.plist"))
    }
}

/// DAE-02: LaunchAgent plist 文本（纯函数——测试断言 KeepAlive 语义）。
///
/// KeepAlive 不是无条件 `<true/>`：主动退位（stand_down / step_down 都
/// 是 exit(0)）后 launchd 若照旧每 ~10s 重拉，退位实例会被自己的旧
/// plist 无限复活，永久空转 churn（验收人实锤：升级接管场景必现）。
/// `SuccessfulExit=false` 的语义 = 成功退出不重拉；崩溃/被杀（非零退出
/// 或信号）照样复活——pkill 复活验收不回归。
pub(crate) fn agent_plist(exec: &Path) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>{AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>{}</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>StandardOutPath</key><string>{}/Library/Logs/p-pass-daemon.log</string>
    <key>StandardErrorPath</key><string>{}/Library/Logs/p-pass-daemon.err</string>
</dict>
</plist>
"#,
        exec.display(),
        home().display(),
        home().display(),
    )
}

impl Default for MacosAdapter {
    fn default() -> Self {
        Self::new()
    }
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()))
}

fn io_err(action: &'static str) -> impl Fn(std::io::Error) -> PlatformError {
    move |source| PlatformError::Io { action, source }
}

impl PlatformAdapter for MacosAdapter {
    fn install_autostart(&self, exec: &Path) -> Result<()> {
        // DAE-01 稳定路径纪律：plist 绝不指向 target/ 开发路径或 /tmp/——
        // 指向那里的 launchd 条目会把旧构建永远钉在岗上（用户机实锤：
        // launchd 至今指向 7/31 开发构建路径）。非法路径直接拒绝，不写。
        let exec_str = exec.display().to_string();
        if exec_str.contains("/target/") || exec_str.contains("/tmp/") {
            return Err(PlatformError::Failed {
                action: "install_autostart rejects unstable path",
                detail: exec_str,
            });
        }
        let plist = agent_plist(exec);
        let path = Self::agent_plist_path();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(io_err("create LaunchAgents dir"))?;
        }
        std::fs::write(&path, plist).map_err(io_err("write LaunchAgent plist"))?;
        // Load now (idempotent-ish: bootout first, ignore its failure).
        let uid = Command::new("id")
            .arg("-u")
            .output()
            .map_err(io_err("id -u"))?;
        let uid = String::from_utf8_lossy(&uid.stdout).trim().to_string();
        let _ = Command::new("launchctl")
            .args(["bootout", &format!("gui/{uid}/{AGENT_LABEL}")])
            .output();
        let out = Command::new("launchctl")
            .args(["bootstrap", &format!("gui/{uid}")])
            .arg(&path)
            .output()
            .map_err(io_err("launchctl bootstrap"))?;
        if !out.status.success() {
            return Err(PlatformError::Failed {
                action: "launchctl bootstrap",
                detail: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        Ok(())
    }

    fn autostart_installed(&self) -> Result<bool> {
        Ok(Self::agent_plist_path().exists())
    }

    fn uninstall_autostart(&self) -> Result<()> {
        let uid = Command::new("id")
            .arg("-u")
            .output()
            .map_err(io_err("id -u"))?;
        let uid = String::from_utf8_lossy(&uid.stdout).trim().to_string();
        let _ = Command::new("launchctl")
            .args(["bootout", &format!("gui/{uid}/{AGENT_LABEL}")])
            .output();
        let path = Self::agent_plist_path();
        if path.exists() {
            std::fs::remove_file(&path).map_err(io_err("remove LaunchAgent plist"))?;
        }
        Ok(())
    }

    fn service_mode(&self) -> ServiceMode {
        ServiceMode::LaunchAgent
    }

    fn key_store(&self) -> Box<dyn KeyStore> {
        Box::new(KeychainStore)
    }

    fn assert_awake(&self) -> Result<AwakeGuard> {
        let child = Command::new("caffeinate")
            .arg("-i") // prevent idle sleep while we run
            .spawn()
            .map_err(io_err("spawn caffeinate"))?;
        Ok(AwakeGuard {
            inner: CaffeinateGuard { child },
        })
    }

    fn power_hint(&self) -> PowerHint {
        match Command::new("pmset").args(["-g", "custom"]).output() {
            Ok(out) if out.status.success() => {
                crate::parse_pmset(&String::from_utf8_lossy(&out.stdout))
            }
            _ => PowerHint::Unknown,
        }
    }

    fn notify(&self, title: &str, body: &str) {
        // Reliable notifications need a notarized .app (T-041/T-071);
        // best-effort osascript until then.
        let script = format!(
            "display notification \"{}\" with title \"{}\"",
            body.replace('"', "'"),
            title.replace('"', "'")
        );
        let _ = Command::new("osascript").args(["-e", &script]).output();
    }

    fn data_dir(&self) -> PathBuf {
        home().join("Library/Application Support/P-Pass")
    }
}

/// RAII wrapper over a `caffeinate -i` child: alive = system stays awake.
pub struct CaffeinateGuard {
    child: std::process::Child,
}

impl Drop for CaffeinateGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Login-keychain generic passwords via the `security` CLI. Secrets are
/// stored hex-encoded (the CLI is text-oriented).
struct KeychainStore;

impl KeyStore for KeychainStore {
    fn store(&self, name: &str, secret: &[u8]) -> Result<()> {
        let hex: String = secret.iter().map(|b| format!("{b:02x}")).collect();
        let out = Command::new("security")
            .args([
                "add-generic-password",
                "-U", // update if exists
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                name,
                "-w",
                &hex,
            ])
            .output()
            .map_err(io_err("security add-generic-password"))?;
        if !out.status.success() {
            return Err(PlatformError::Failed {
                action: "keychain store",
                detail: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        Ok(())
    }

    fn load(&self, name: &str) -> Result<Option<Vec<u8>>> {
        let out = Command::new("security")
            .args([
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                name,
                "-w",
            ])
            .output()
            .map_err(io_err("security find-generic-password"))?;
        if !out.status.success() {
            return Ok(None); // not found (or locked — treated as absent)
        }
        let hex = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let mut bytes = Vec::with_capacity(hex.len() / 2);
        let raw = hex.as_bytes();
        for chunk in raw.as_chunks::<2>().0 {
            let hi = (chunk[0] as char).to_digit(16);
            let lo = (chunk[1] as char).to_digit(16);
            match (hi, lo) {
                (Some(h), Some(l)) => bytes.push(((h << 4) | l) as u8),
                _ => {
                    return Err(PlatformError::Failed {
                        action: "keychain load",
                        detail: "stored value is not hex".into(),
                    })
                }
            }
        }
        Ok(Some(bytes))
    }

    fn delete(&self, name: &str) -> Result<()> {
        let _ = Command::new("security")
            .args([
                "delete-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                name,
            ])
            .output()
            .map_err(io_err("security delete-generic-password"))?;
        Ok(())
    }
}
