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

    /// DAE-05：`GetDiskFreeSpaceExW`。free 取 `lpFreeBytesAvailableToCaller`
    /// 而不是 `lpTotalNumberOfFreeBytes`——前者是「本调用者（受配额约束后）
    /// 真正能写多少」，正是 unix 侧 `statvfs.f_bavail` 的对等语义，也是
    /// 资源管理器显示的那个数。取错的话在带配额的卷上会偏大。
    ///
    /// 路径要先转成 UTF-16 + NUL 结尾的宽字符串（Win32 W 系列 API 的要求）。
    /// 目录不存在或无权限时 API 返回 0，此处回 `None`——调用方序列化成 null，
    /// 绝不编造数字。
    fn volume_stats(&self, path: &Path) -> Option<crate::VolumeStats> {
        use std::os::windows::ffi::OsStrExt as _;
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

        let wide: Vec<u16> = path
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut free_to_caller: u64 = 0;
        let mut total: u64 = 0;
        // SAFETY: wide 是 NUL 结尾的合法宽字符串且在调用期间存活；两个出参
        // 是栈上的 u64，指针非空且对齐。第三个出参传 null 表示不关心
        // 「卷上物理空闲量」（我们要的是 caller-available 那个）。
        let ok = unsafe {
            GetDiskFreeSpaceExW(
                wide.as_ptr(),
                &mut free_to_caller,
                &mut total,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            return None;
        }
        Some(crate::VolumeStats {
            free: free_to_caller,
            total,
        })
    }

    /// DEVLOG-02：Run 键启动的 daemon，其 stderr 唯一去处就是 Windows 自动
    /// 分配的那个控制台——而 release 已经不再分配它，所以必须有确定的落盘
    /// 位置。放在生效的 data dir 下，与 DPAPI blob、索引同域：data_dir 将来
    /// 若从 Roaming 迁到 Local（DESK-24），日志跟着一起搬，不必改两处。
    fn default_log_file(&self, data_dir: &Path) -> Option<PathBuf> {
        Some(data_dir.join("logs").join("daemon.log"))
    }

    /// QA-09 迁移（#211）：**没实现**，不是「不需要」。
    ///
    /// 迁移前 daemon 里那段 0o600 是 `#[cfg(unix)]`，Windows 上整块被编译
    /// 掉——也就是说这里返回 `Unsupported` **与迁移前的行为完全一致**，
    /// 只是从「代码里看不见」变成「契约里写明」。
    ///
    /// 现状下的实际风险有限：身份密钥落在 `%APPDATA%` 之下，用户配置目录
    /// 本身的 ACL 已经限定到当前用户。但那是**依赖默认值**，不是显式收紧，
    /// 所以口径是缺口而不是 NotApplicable。要真做得走 `SetNamedSecurityInfo`
    /// 重写 DACL。
    fn restrict_to_owner(&self, path: &Path) -> Result<crate::Applied> {
        let _ = path;
        Ok(crate::Applied::Unsupported)
    }

    /// QA-09 迁移（#211）：**没实现**，与迁移前一致。
    ///
    /// fd 级别的截断在 Windows 上要走 `SetEndOfFile` 之类的 Win32 调用。
    /// 计数器照样清零（不会每行都重复触发），但底层文件不会真的变小。
    /// 日志洪水的主防线是「折叠重复行」，那道所有平台都有。
    fn truncate_own_stderr(&self) -> crate::Applied {
        crate::Applied::Unsupported
    }

    /// QA-09 迁移（#211）：**机制上不需要**，这不是缺口。
    ///
    /// Windows 侧的 IPC 端点是命名管道，内核对象，不在文件系统里留文件，
    /// 所以不存在「被强杀的前任留下一个文件挡住 bind」这个问题。
    fn remove_stale_ipc_endpoint(&self, name: &str) -> crate::Applied {
        let _ = name;
        crate::Applied::NotApplicable
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

#[cfg(test)]
mod dae05_volume_stats_tests {
    use super::*;

    /// DAE-05 契约：Windows 上 volume_stats 必须回真实数字，不能是 None。
    /// 这条就是那个产品缺口的守卫——改回 `None` 它必须红。
    #[test]
    fn volume_stats_reports_real_numbers_for_an_existing_dir() {
        let a = WindowsAdapter::new();
        let stats = a
            .volume_stats(&std::env::temp_dir())
            .expect("Windows 必须能报出卷容量（None = DAE-05 的缺口又回来了）");
        assert!(stats.total > 0, "total 必须为正，实测 {}", stats.total);
        assert!(
            stats.free <= stats.total,
            "free({}) 不可能大于 total({})",
            stats.free,
            stats.total
        );
    }

    /// 不存在的路径要老实回 None，而不是编一个数字。
    #[test]
    fn volume_stats_returns_none_for_a_nonexistent_volume() {
        let a = WindowsAdapter::new();
        assert_eq!(
            a.volume_stats(std::path::Path::new(r"Q:\definitely-not-a-volume\dae05")),
            None
        );
    }
}

#[cfg(test)]
mod qa09_migrated_capability_tests {
    use super::*;

    /// QA-09 迁移（#211）契约：Windows 上收紧权限是**已知缺口**，必须
    /// 明说 `Unsupported`。
    ///
    /// 这条守的是口径而不是功能：谁哪天把它改成 `Ok(Applied::Done)` 来
    /// 「让返回值好看」，这里必须红——静默什么都没做却报成功，正是本仓
    /// 这一轮在修的那类缺陷。真做出来了要连这条测试一起改。
    #[test]
    fn restrict_to_owner_admits_it_is_unsupported() {
        let a = WindowsAdapter::new();
        let f = std::env::temp_dir().join("ppf-qa09-restrict.probe");
        std::fs::write(&f, b"x").unwrap();
        assert_eq!(
            a.restrict_to_owner(&f).unwrap(),
            crate::Applied::Unsupported
        );
        let _ = std::fs::remove_file(&f);
    }

    /// 同上：fd 级别截断在 Windows 上没接，必须说 `Unsupported`。
    #[test]
    fn truncate_own_stderr_admits_it_is_unsupported() {
        assert_eq!(
            WindowsAdapter::new().truncate_own_stderr(),
            crate::Applied::Unsupported
        );
    }

    /// 这条相反：命名管道**机制上就不落文件**，没有残留要清，所以是
    /// `NotApplicable` 而不是 `Unsupported`。
    ///
    /// 两者绝不能混：`Unsupported` 是「该做没做」（将来要补），
    /// `NotApplicable` 是「本来就不用做」（将来也不用补）。混成一个，
    /// 清单上就分不出哪些是真欠的。
    #[test]
    fn remove_stale_ipc_endpoint_is_not_applicable_for_named_pipes() {
        assert_eq!(
            WindowsAdapter::new().remove_stale_ipc_endpoint("ppf-qa09-whatever"),
            crate::Applied::NotApplicable
        );
    }
}
