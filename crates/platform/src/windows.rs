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

    /// DESK-22 (#171)：一键关闭「空闲自动睡眠」，让备份能在无人值守时跑完。
    ///
    /// 等价物是 `powercfg /x standby-timeout-ac 0`，它写的是 HKLM 下的电源
    /// 方案键，**非管理员没有写权限**（2026-09-21 实测：以写权限打开该键
    /// 直接被拒，`Requested registry access is not allowed`）。所以必须提权，
    /// 走 `ShellExecuteExW` 的 `runas` 动词弹 UAC——与 macOS 侧那个管理员
    /// 授权弹窗对等。
    ///
    /// ⚠️ **只设 AC，不设 DC**。理由是与本适配器的检测口径严格一致：
    /// [`read_standby_idle_seconds`] 只读 `ACSettingIndex`。设了 DC 却不检测
    /// 它，就会出现「改了但没法验证」的半截状态，而"没法验证"在本仓等于
    /// "不许报成功"。AC / DC 口径不一致是**检测侧既有的**问题，另开卡处理。
    /// （macOS 侧 `pmset -a` 设所有场景，是因为 `parse_pmset` 也检测所有场景，
    /// 两边各自自洽。）
    ///
    /// ⚠️ **不信退出码，动手后回读**。2026-09-21 在 Windows 11 26200 上实测
    /// （非管理员）：`powercfg /x standby-timeout-ac 0` 退出码是 **0**，而那个
    /// 注册表键的最后写入时间**一点没变**——它压根没写成，却报了成功。拿退出
    /// 码当"已生效"就是本仓这一轮在修的那类缺陷（#268 那个 0 字节 daemon
    /// 注册完报 resident 是同一形状）。
    fn disable_auto_sleep(&self) -> Result<crate::Applied> {
        let before = read_standby_idle_seconds();
        elevated_powercfg("/x standby-timeout-ac 0")?;
        verdict_from_readback(before, read_standby_idle_seconds())
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

/// DESK-22 (#171)：把「回读到的值」翻译成结果。
///
/// 抽成纯函数是刻意的——提权那半只能真机手测（要 UAC 交互、要改这台机器的
/// 电源设置），但**「回读不是 0 就不许报成功」这条判据本身**可以在不提权、
/// 不改任何设置的前提下锁成断言。判据一旦松掉（比如有人图省事让 `None` 也
/// 返回 `Done`），单测必须立刻红。
fn verdict_from_readback(before: Option<u32>, after: Option<u32>) -> Result<crate::Applied> {
    match after {
        Some(0) => Ok(crate::Applied::Done),
        Some(seconds) => Err(PlatformError::Failed {
            action: "disable_auto_sleep",
            detail: format!(
                "powercfg 报了成功，但回读到空闲睡眠仍是 {seconds} 秒（改动前 {before:?}）——设置没有生效"
            ),
        }),
        None => Err(PlatformError::Failed {
            action: "disable_auto_sleep",
            detail: "powercfg 报了成功，但读不回设置值，无法确认是否生效".into(),
        }),
    }
}

/// 以管理员身份、**隐藏窗口**地跑 `powercfg.exe`，等它结束并检查退出码。
///
/// 为什么不用 `std::process::Command`：只有 shell 的 `runas` 动词能触发 UAC，
/// `CreateProcess`（`Command` 走的那条）做不到提权。
///
/// 为什么 `SW_HIDE`：`powercfg.exe` 是 console 子系统程序，桌面壳自己是 GUI
/// 子系统、手上没有控制台，不隐藏的话 Windows 会给它新分配一个 ⇒ 闪一下黑窗。
/// 这正是 DESK-19 (#168) 修过的那一类。`ShellExecuteEx` **不接受**
/// `CREATE_NO_WINDOW`（那是 `CreateProcess` 的标志），`nShow` 是唯一的手柄。
/// ⚠️ 这一条只能真机肉眼验，代码里锁不住——列在 #171 的手测清单第一条。
fn elevated_powercfg(params: &str) -> Result<()> {
    use std::os::windows::ffi::OsStrExt as _;
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_CANCELLED};
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, WaitForSingleObject, INFINITE,
    };
    use windows_sys::Win32::UI::Shell::{
        ShellExecuteExW, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_HIDE;

    fn wide(s: &str) -> Vec<u16> {
        std::ffi::OsStr::new(s)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }
    let verb = wide("runas");
    let file = wide("powercfg.exe");
    let args = wide(params);

    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    // NOCLOSEPROCESS: 要拿到进程句柄才能等它结束、读退出码。
    // NOASYNC: 本调用返回后我们还要立刻回读注册表，必须确保动作已经完成。
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    info.lpVerb = verb.as_ptr();
    info.lpFile = file.as_ptr();
    info.lpParameters = args.as_ptr();
    info.nShow = SW_HIDE;

    // SAFETY: info 已零初始化并填好 cbSize；三个宽字符串都是 NUL 结尾且在
    // 整个调用期间存活（它们的所有权在本函数栈上，晚于本次调用释放）。
    let started = unsafe { ShellExecuteExW(&mut info) };
    if started == 0 {
        // SAFETY: 紧跟失败调用之后读取本线程的错误码。
        let code = unsafe { GetLastError() };
        // 用户在 UAC 上点了「否」——这不是失败，是他的选择。
        if code == ERROR_CANCELLED {
            return Err(PlatformError::Cancelled {
                action: "disable_auto_sleep",
            });
        }
        return Err(PlatformError::Failed {
            action: "disable_auto_sleep",
            detail: format!("提权启动失败（Win32 错误码 {code}）"),
        });
    }

    if info.hProcess.is_null() {
        // 拿不到句柄就等不了、也读不到退出码。不装作成功——反正后面还有
        // 回读兜底，但这里先把"没法确认"说出来。
        return Err(PlatformError::Failed {
            action: "disable_auto_sleep",
            detail: "提权进程已启动，但拿不到句柄，无法确认它是否跑完".into(),
        });
    }

    // SAFETY: hProcess 由 SEE_MASK_NOCLOSEPROCESS 保证有效，且下面只用一次。
    unsafe { WaitForSingleObject(info.hProcess, INFINITE) };
    let mut exit_code: u32 = 0;
    // SAFETY: 同上；exit_code 是栈上的 u32 出参。
    let got = unsafe { GetExitCodeProcess(info.hProcess, &mut exit_code) };
    // SAFETY: 同上；之后不再使用该句柄。
    unsafe { CloseHandle(info.hProcess) };

    if got == 0 {
        return Err(PlatformError::Failed {
            action: "disable_auto_sleep",
            detail: "读不到提权进程的退出码，无法确认它是否成功".into(),
        });
    }
    if exit_code != 0 {
        return Err(PlatformError::Failed {
            action: "disable_auto_sleep",
            detail: format!("powercfg 退出码 {exit_code}"),
        });
    }
    // ⚠️ 退出码 0 **不代表设置生效**（见 disable_auto_sleep 的注释）。
    // 判定交给调用方的回读。
    Ok(())
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

#[cfg(test)]
mod desk22_disable_auto_sleep_tests {
    use super::*;

    /// 唯一可信的成功条件：回读到 0。
    #[test]
    fn readback_zero_is_the_only_success() {
        assert_eq!(
            verdict_from_readback(Some(1200), Some(0)).unwrap(),
            crate::Applied::Done
        );
    }

    /// 回读仍是非零 ⇒ 没生效，必须报错。
    ///
    /// 这条守的是那个实测事实：非管理员下 `powercfg /x` 退出码是 0 但注册表
    /// 没被写。谁把判据放松成"退出码 0 就算成功"，这里必须红。
    #[test]
    fn readback_nonzero_must_not_be_reported_as_success() {
        let e = verdict_from_readback(Some(1200), Some(1200)).unwrap_err();
        let msg = e.to_string();
        assert!(msg.contains("1200"), "错误信息要带上实际读到的值：{msg}");
        assert!(msg.contains("没有生效"), "错误信息要说清没生效：{msg}");
    }

    /// 读不回值 ⇒ **不许**当成功。「没法确认」不等于「成功」——
    /// 这是 fail-closed 的方向，放松它就是静默放行。
    #[test]
    fn unreadable_state_must_not_be_reported_as_success() {
        assert!(verdict_from_readback(None, None).is_err());
        assert!(verdict_from_readback(Some(0), None).is_err());
    }

    /// 取消是独立的一类，不能被归成失败——否则 UI 会把用户自己的选择
    /// 说成出错。
    #[test]
    fn cancelled_is_its_own_variant_not_a_failure() {
        let c = PlatformError::Cancelled {
            action: "disable_auto_sleep",
        };
        assert!(matches!(c, PlatformError::Cancelled { .. }));
        assert!(c.to_string().contains("取消"), "{c}");
    }
}
