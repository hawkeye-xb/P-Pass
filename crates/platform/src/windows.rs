//! Windows adapter (§4 对照表左列).
//!
//! - Autostart: HKCU `Software\Microsoft\Windows\CurrentVersion\Run`
//!   value (user-level, no admin, no SCM service — §4: 免权限地狱).
//! - Awake: `SetThreadExecutionState(ES_SYSTEM_REQUIRED|ES_CONTINUOUS)`
//!   held RAII-style; drop restores `ES_CONTINUOUS`.
//! - Keys: DPAPI (`CryptProtectData`/`CryptUnprotectData`), blob stored
//!   in the data dir — decryptable only by this Windows user.
//! - Power hint: `powercfg /query` through the shared pure parser.
//!
//! Compile-checked cross-platform in CI (`cargo check --target
//! x86_64-pc-windows-msvc`); live smoke runs on the H-09 Windows box.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{AwakeGuard, KeyStore, PlatformAdapter, PlatformError, PowerHint, Result, ServiceMode};

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "P-Pass";

pub struct WindowsAdapter;

impl WindowsAdapter {
    pub fn new() -> Self {
        Self
    }
}

impl Default for WindowsAdapter {
    fn default() -> Self {
        Self::new()
    }
}

fn io_err(action: &'static str) -> impl Fn(std::io::Error) -> PlatformError {
    move |source| PlatformError::Io { action, source }
}

impl PlatformAdapter for WindowsAdapter {
    fn install_autostart(&self, exec: &Path) -> Result<()> {
        let (key, _) = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
            .create_subkey(RUN_KEY)
            .map_err(io_err("open HKCU Run key"))?;
        key.set_value(RUN_VALUE, &exec.display().to_string())
            .map_err(io_err("set Run value"))?;
        // The Run key only takes effect on the NEXT login/boot — unlike
        // macOS's `launchctl bootstrap` (RunAtLoad), writing the registry
        // value alone does not start anything now. Without this, the
        // wizard's finishSetup() polls daemon_call("status") for 10s,
        // gets nothing, and reports "后台服务没有在 10 秒内就绪" — a real
        // platform gap mis-surfaced as a generic timeout (found 2026-08-26
        // W1 real-box run). Spawn once immediately, windowless, so the
        // observable contract matches macOS: after install_autostart
        // returns Ok, the daemon is already reachable.
        spawn_windowless(exec).map_err(io_err("spawn daemon after registering autostart"))?;
        Ok(())
    }

    fn autostart_installed(&self) -> Result<bool> {
        let key = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
            .open_subkey(RUN_KEY)
            .map_err(io_err("open HKCU Run key"))?;
        Ok(key.get_value::<String, _>(RUN_VALUE).is_ok())
    }

    fn uninstall_autostart(&self) -> Result<()> {
        let key = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
            .open_subkey_with_flags(RUN_KEY, winreg::enums::KEY_ALL_ACCESS)
            .map_err(io_err("open HKCU Run key"))?;
        match key.delete_value(RUN_VALUE) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(io_err("delete Run value")(e)),
        }
    }

    fn service_mode(&self) -> ServiceMode {
        ServiceMode::UserAutostart
    }

    fn key_store(&self) -> Box<dyn KeyStore> {
        Box::new(DpapiStore {
            dir: self.data_dir().join("keys"),
        })
    }

    fn assert_awake(&self) -> Result<AwakeGuard> {
        use windows_sys::Win32::System::Power::{
            SetThreadExecutionState, ES_CONTINUOUS, ES_SYSTEM_REQUIRED,
        };
        // SAFETY: SetThreadExecutionState has no memory-safety
        // preconditions; a zero return means failure.
        let prev = unsafe { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) };
        if prev == 0 {
            return Err(PlatformError::Failed {
                action: "SetThreadExecutionState",
                detail: "returned 0".into(),
            });
        }
        Ok(AwakeGuard {
            inner: ExecutionStateGuard { _private: () },
        })
    }

    fn power_hint(&self) -> PowerHint {
        // NOTE (2026-08-26, W1 real-box run): `powercfg /query` output is
        // localized (zh-CN Windows prints "当前交流电源设置索引" instead of
        // "Current AC Power Setting Index"), so the English-only text
        // parser in crate::parse_powercfg silently matched nothing and
        // this always returned Unknown on non-English systems. Read the
        // effective value straight from the registry instead — locale
        // independent, and it's literally what powercfg itself reads.
        // Path: HKLM\SYSTEM\CurrentControlSet\Control\Power\User\
        //   PowerSchemes\<ActiveScheme>\238c9fa8...(SUB_SLEEP)\
        //   29f6c1db...(STANDBYIDLE), value ACSettingIndex (seconds, 0 = never).
        read_standby_idle_seconds()
            .map(|seconds| {
                if seconds == 0 {
                    PowerHint::NeverSleeps
                } else {
                    PowerHint::SleepsWhenIdle {
                        minutes: seconds.div_ceil(60),
                    }
                }
            })
            .unwrap_or(PowerHint::Unknown)
    }

    fn notify(&self, _title: &str, _body: &str) {
        // Tauri notification carries this in T-041; no-op until then.
    }

    fn data_dir(&self) -> PathBuf {
        PathBuf::from(std::env::var("APPDATA").unwrap_or_else(|_| ".".into())).join("P-Pass")
    }
}

/// Spawn `exec` detached, with no console window (equivalent to macOS's
/// `launchctl bootstrap` giving the daemon an immediate first run instead
/// of waiting for the next login). CREATE_NO_WINDOW keeps a bare console
/// app from flashing a black window when spawned from the desktop shell.
fn spawn_windowless(exec: &Path) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    Command::new(exec)
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .stdin(std::process::Stdio::null())
        .spawn()?;
    Ok(())
}

/// Read the active power scheme's AC standby-idle timeout (seconds; 0 =
/// never) straight from the registry — locale-independent, unlike parsing
/// `powercfg /query`'s localized text output.
fn read_standby_idle_seconds() -> Option<u32> {
    use winreg::enums::HKEY_LOCAL_MACHINE;
    use winreg::RegKey;
    const SUB_SLEEP: &str = "238c9fa8-0aad-41ed-83f4-97be242c8f20";
    const STANDBYIDLE: &str = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da";
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let schemes = hklm
        .open_subkey(r"SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes")
        .ok()?;
    let active: String = schemes.get_value("ActivePowerScheme").ok()?;
    let setting = schemes
        .open_subkey(format!("{active}\\{SUB_SLEEP}\\{STANDBYIDLE}"))
        .ok()?;
    // AC (plugged in) is the relevant one for "will this backup session
    // get interrupted" — mirrors the SCHEME_CURRENT/SUB_SLEEP/STANDBYIDLE
    // AC query `powercfg` itself defaults to.
    setting.get_value::<u32, _>("ACSettingIndex").ok()
}

/// RAII wrapper over the thread execution state.
pub struct ExecutionStateGuard {
    _private: (),
}

impl Drop for ExecutionStateGuard {
    fn drop(&mut self) {
        use windows_sys::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS};
        // SAFETY: as above.
        unsafe {
            SetThreadExecutionState(ES_CONTINUOUS);
        }
    }
}

/// DPAPI-protected key files under the data dir — only this Windows
/// user (on this machine) can decrypt them.
struct DpapiStore {
    dir: PathBuf,
}

impl DpapiStore {
    fn path(&self, name: &str) -> PathBuf {
        // Names are internal identifiers (e.g. "device-key"), sanitized
        // defensively anyway.
        let safe: String = name
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        self.dir.join(format!("{safe}.dpapi"))
    }
}

impl KeyStore for DpapiStore {
    fn store(&self, name: &str, secret: &[u8]) -> Result<()> {
        std::fs::create_dir_all(&self.dir).map_err(io_err("create keys dir"))?;
        let blob = dpapi_protect(secret)?;
        std::fs::write(self.path(name), blob).map_err(io_err("write key blob"))?;
        Ok(())
    }

    fn load(&self, name: &str) -> Result<Option<Vec<u8>>> {
        let path = self.path(name);
        let blob = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(io_err("read key blob")(e)),
        };
        dpapi_unprotect(&blob).map(Some)
    }

    fn delete(&self, name: &str) -> Result<()> {
        match std::fs::remove_file(self.path(name)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(io_err("delete key blob")(e)),
        }
    }
}

fn dpapi_protect(data: &[u8]) -> Result<Vec<u8>> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CryptProtectData, CRYPT_INTEGER_BLOB};
    let input = CRYPT_INTEGER_BLOB {
        cbData: data.len() as u32,
        pbData: data.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    // SAFETY: input points at valid memory for the duration of the call;
    // on success output is a LocalAlloc'd buffer we copy then free.
    let ok = unsafe {
        CryptProtectData(
            &input,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            &mut output,
        )
    };
    if ok == 0 {
        return Err(PlatformError::Failed {
            action: "CryptProtectData",
            detail: "returned FALSE".into(),
        });
    }
    let blob =
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() };
    unsafe { LocalFree(output.pbData as _) };
    Ok(blob)
}

fn dpapi_unprotect(blob: &[u8]) -> Result<Vec<u8>> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CryptUnprotectData, CRYPT_INTEGER_BLOB};
    let input = CRYPT_INTEGER_BLOB {
        cbData: blob.len() as u32,
        pbData: blob.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    // SAFETY: as in dpapi_protect.
    let ok = unsafe {
        CryptUnprotectData(
            &input,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            &mut output,
        )
    };
    if ok == 0 {
        return Err(PlatformError::Failed {
            action: "CryptUnprotectData",
            detail: "returned FALSE (wrong user or corrupted blob)".into(),
        });
    }
    let data =
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() };
    unsafe { LocalFree(output.pbData as _) };
    Ok(data)
}
