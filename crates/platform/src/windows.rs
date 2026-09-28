//! Windows adapter (§4 对照表左列).
//!
//! - Autostart: HKCU `Software\Microsoft\Windows\CurrentVersion\Run`
//!   value (user-level, no admin, no SCM service — §4: 免权限地狱).
//! - Awake: `SetThreadExecutionState(ES_SYSTEM_REQUIRED|ES_CONTINUOUS)`
//!   held RAII-style; drop restores `ES_CONTINUOUS`.
//! - Keys: DPAPI (`CryptProtectData`/`CryptUnprotectData`), blob stored
//!   in the data dir — decryptable only by this Windows user **on this
//!   machine**. DESK-24 (#173): that is precisely why the data dir must
//!   live under `%LOCALAPPDATA%` and never under roaming `%APPDATA%`.
//! - Power hint: `powercfg /query` through the shared pure parser.
//!
//! Compile-checked cross-platform in CI (`cargo check --target
//! x86_64-pc-windows-msvc`); live smoke runs on the H-09 Windows box.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{AwakeGuard, KeyStore, PlatformAdapter, PlatformError, PowerHint, Result, ServiceMode};

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "P-Pass";

/// DESK-24 (#173)：数据目录在 `%LOCALAPPDATA%` 下的名字。
///
/// 取自 `apps/desktop/src-tauri/tauri.conf.json` 的 `identifier`，不是随手
/// 起的：`%LOCALAPPDATA%\<identifier>` 已经是本应用的本机数据根目录——
/// Tauri 的网页视图数据 `EBWebView` 现在就在里面，NSIS 的
/// `deleteAppDataOnUninstall` 指的也是它。用它，「应用数据」在我们代码和
/// 打包器眼里是同一个意思。
///
/// ⚠️ **不许改成 `P-Pass`。** 那是安装程序自己的目录，实证：
/// `HKCU\...\Uninstall\P-Pass` 的 `InstallLocation` =
/// `C:\Users\<user>\AppData\Local\P-Pass`，里面是三个 exe 加卸载程序。
/// 用户数据不许用安装程序拥有的目录来定义——卸载的清理范围会和用户数据
/// 焊死；而且 `nsis.installMode` 哪天从 currentUser 改成 perMachine，
/// `$INSTDIR` 就变成 `C:\Program Files\P-Pass`，普通用户根本写不进去。
const DATA_DIR_NAME: &str = "com.p-pass.desktop";

/// 搬家前的老位置：`%APPDATA%`（= Roaming）下的 `P-Pass`。
///
/// 为什么是错的（DESK-24 #173）：Roaming 在域环境里会被系统复制到用户登录
/// 的其他机器上，而这个目录里装的**全是**不该跟着跑的东西——只增不减的
/// 日志、内容是本机绝对路径的 `config.toml`、以及（T-071 之后的）只有本机
/// 能解开的 DPAPI 密文。
fn legacy_data_dir() -> PathBuf {
    PathBuf::from(std::env::var("APPDATA").unwrap_or_else(|_| ".".into())).join("P-Pass")
}

/// 现行位置：`%LOCALAPPDATA%\com.p-pass.desktop`。
fn current_data_dir() -> PathBuf {
    PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".into())).join(DATA_DIR_NAME)
}

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

/// DESK-17 (#166)：toast 挂在这个 AppUserModelID 名下。它等于
/// `tauri.conf.json` 的 `identifier`——NSIS 安装时把开始菜单快捷方式的
/// AUMID 设成的就是它（见 `notify` 的注释）。与 [`DATA_DIR_NAME`] 恰好同值，
/// 但语义不同，刻意分开写。
const APP_USER_MODEL_ID: &str = "com.p-pass.desktop";

/// `notify` 的可注入版本：AUMID 由调用方给，契约测试用一个不存在的 ID 来
/// 验「不可用时不 panic、不阻塞」。
fn notify_as(app_id: &str, title: &str, body: &str) {
    let (app_id, title, body) = (app_id.to_owned(), title.to_owned(), body.to_owned());
    // 线程起不来（资源耗尽）也只是没通知，不能让调用方跟着失败。
    let _ = std::thread::Builder::new()
        .name("ppf-toast".into())
        .spawn(move || {
            let _ = show_toast(&app_id, &title, &body);
        });
}

/// 真正弹 toast 的那一段（同步）。
fn show_toast(app_id: &str, title: &str, body: &str) -> windows::core::Result<()> {
    use windows::core::HSTRING;
    use windows::Data::Xml::Dom::XmlDocument;
    use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};
    use windows::UI::Notifications::{ToastNotification, ToastNotificationManager};

    // 本线程是自己起的，套间由我们定。重复初始化返回 S_FALSE / 已初始化，
    // 都不影响后面的调用，所以结果不看。
    // SAFETY: RoInitialize 没有内存安全前提。
    let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
    let xml = XmlDocument::new()?;
    xml.LoadXml(&HSTRING::from(toast_xml(title, body)))?;
    let toast = ToastNotification::CreateToastNotification(&xml)?;
    ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(app_id))?.Show(&toast)
}

/// toast 的 XML 负载。标题与正文都要做 XML 转义——它们来自产品文案与
/// 文件名之类的外部输入，一个 `<` 就能让整条通知 `LoadXml` 失败。
fn toast_xml(title: &str, body: &str) -> String {
    format!(
        "<toast><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual></toast>",
        xml_escape(title),
        xml_escape(body)
    )
}

fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(c),
        }
    }
    out
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

    /// NET-26 (#419)：`SetThreadExecutionState` 的状态挂在**调用线程**上。
    /// daemon 在 tokio 多线程 runtime 里拿锁、放锁，两次调用多半落在不同的
    /// worker 上——放锁那一下清的是别的线程的状态，拿锁的那个线程会一直让
    /// 系统保持唤醒。所以这里起一个专属线程：它设置状态、汇报结果、阻塞等
    /// guard 被 drop，再在**同一个线程**上清掉状态退出。guard 因此可以在任意
    /// 线程上 drop，语义与 macOS 的 caffeinate 子进程对称。
    fn assert_awake(&self) -> Result<AwakeGuard> {
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<std::result::Result<(), String>>();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let thread = std::thread::Builder::new()
            .name("ppf-awake".into())
            .spawn(move || {
                use windows_sys::Win32::System::Power::{
                    SetThreadExecutionState, ES_CONTINUOUS, ES_SYSTEM_REQUIRED,
                };
                // SAFETY: SetThreadExecutionState has no memory-safety
                // preconditions; a zero return means failure.
                let prev = unsafe { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) };
                if prev == 0 {
                    let _ = ready_tx.send(Err("returned 0".into()));
                    return;
                }
                let _ = ready_tx.send(Ok(()));
                // Blocks until the guard drops (its sender disconnects).
                let _ = release_rx.recv();
                // SAFETY: as above.
                unsafe {
                    SetThreadExecutionState(ES_CONTINUOUS);
                }
            })
            .map_err(io_err("spawn awake thread"))?;
        match ready_rx.recv() {
            Ok(Ok(())) => Ok(AwakeGuard {
                inner: ExecutionStateGuard {
                    release: Some(release_tx),
                    thread: Some(thread),
                },
            }),
            Ok(Err(detail)) => {
                let _ = thread.join();
                Err(PlatformError::Failed {
                    action: "SetThreadExecutionState",
                    detail,
                })
            }
            Err(_) => {
                let _ = thread.join();
                Err(PlatformError::Failed {
                    action: "SetThreadExecutionState",
                    detail: "awake thread exited before reporting".into(),
                })
            }
        }
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

    // ── QA-09 迁移（#211）桌面壳批次 ───────────────────────────────
    fn platform_name(&self) -> &'static str {
        "windows"
    }

    /// Windows 的可执行文件带 `.exe`。与 [`crate::DAEMON_EXECUTABLE_STEM`]
    /// 的关系有单测钉着（`executable_name_is_the_stem_plus_exe`）——写成
    /// 字面量是因为 `const` 里没法做字符串拼接。
    fn daemon_executable_name(&self) -> &'static str {
        "ppf-daemon.exe"
    }

    /// 「电源和睡眠」设置页。迁移前桌面壳直接把这个字符串交给 opener
    /// 插件；现在字符串归这里，打开动作仍归桌面壳（理由见 trait 上的说明）。
    fn power_settings_uri(&self) -> Option<&'static str> {
        Some("ms-settings:powersleep")
    }

    fn kill_daemon_process(&self) -> Result<crate::KillOutcome> {
        let out = Command::new("taskkill")
            .args(["/F", "/IM", "ppf-daemon.exe"])
            .output()
            .map_err(|e| PlatformError::Io {
                action: "kill_daemon_process",
                source: e,
            })?;
        taskkill_verdict(
            out.status.success(),
            out.status.code(),
            &String::from_utf8_lossy(&out.stderr),
        )
    }

    /// DESK-17 (#166)：Windows toast（WinRT `ToastNotificationManager`）。
    ///
    /// ⚠️ Windows 的 toast 要挂在一个 **AppUserModelID** 名下，而且这个 ID
    /// 必须有一个开始菜单快捷方式认领它，否则 `Show()` 返回成功、通知却不显示。
    /// 本应用的快捷方式由 Tauri 的 NSIS 模板创建，模板会用 `SetLnkAppUserModelId`
    /// 把它设成 bundle identifier（真机实测已安装的 `P-Pass.lnk` 的
    /// `System.AppUserModel.ID` = `com.p-pass.desktop`）。所以这里用同一个 ID，
    /// 不需要改安装脚本。
    ///
    /// 不阻塞调用方：WinRT 调用放进一个一次性线程。trait 的返回值是 `()`，
    /// 失败只能吞掉——与 macOS 侧 osascript 的「尽力而为」口径一致。
    fn notify(&self, title: &str, body: &str) {
        notify_as(APP_USER_MODEL_ID, title, body);
    }

    /// DESK-24 (#173)：**生效的**数据目录。老目录还在就是老目录，搬完了
    /// 才是新目录——判据见 [`crate::data_migration::resolve`]。
    ///
    /// 不写死返回新位置，是为了让「搬迁失败」退化成「保持原样」，而不是
    /// 指着一个空目录让 daemon 建一个崭新的空索引。
    fn data_dir(&self) -> PathBuf {
        crate::data_migration::resolve(&legacy_data_dir(), &current_data_dir())
    }

    /// DESK-24 (#173)：见 [`crate::PlatformAdapter::migrate_legacy_data_dir`]。
    fn migrate_legacy_data_dir(&self) -> crate::DataDirMigration {
        crate::data_migration::migrate(&legacy_data_dir(), &current_data_dir())
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
    /// 位置。放在生效的 data dir 下，与 DPAPI blob、索引同域。
    ///
    /// DESK-24 (#173) 那次从 Roaming 迁到 Local，这里**一个字都没改**——
    /// 日志路径是从入参 data dir 算出来的，data dir 换地方它就跟着走。
    fn default_log_file(&self, data_dir: &Path) -> Option<PathBuf> {
        Some(data_dir.join("logs").join("daemon.log"))
    }

    /// SEC-07 (#289)：把文件的 DACL 重写成**只有当前用户一条 ACE**，并切断
    /// 从父目录的继承——与 unix 侧 `0o600` 同一个意思。
    ///
    /// 为什么要显式做（而不是信 `%LOCALAPPDATA%` 的默认 ACL）：默认值只在
    /// 默认位置成立。data_dir 一旦被改到别处（自定义路径、共享盘、
    /// `ProgramData`），继承来的 ACE 就不再有这个保证。
    ///
    /// `PROTECTED_DACL_SECURITY_INFORMATION` 是关键：不带它，父目录继承下来
    /// 的 ACE 照样生效，等于没收紧。路径不存在时 `SetNamedSecurityInfoW`
    /// 返回 `ERROR_FILE_NOT_FOUND`，这里如实报 `Err`，不静默回 `Done`。
    fn restrict_to_owner(&self, path: &Path) -> Result<crate::Applied> {
        restrict_to_current_user(path)?;
        Ok(crate::Applied::Done)
    }

    /// DEVLOG-04 (#290)：把本进程 stderr 背后的**磁盘文件**截到 0 字节。
    ///
    /// 与 unix 侧对 fd 2 `set_len(0)` + `seek(0)` 同义：先把文件指针移回开头
    /// （`SetFilePointerEx`），再在那里截断（`SetEndOfFile`）。
    ///
    /// 三态口径：
    /// - **`Done`**：stderr 是磁盘文件，而且真的截断了。
    /// - **`NotApplicable`**：stderr 不是磁盘文件——控制台、管道、`NUL`，
    ///   或者根本没有 stderr（release 是 `windows_subsystem = "windows"`，
    ///   没人重定向时句柄为空）。这些都没有「磁盘上越长越大的文件」可截，
    ///   机制上就不需要，不是缺口。
    /// - **`Unsupported`**：stderr 是磁盘文件但截不动。典型情形是托管方以
    ///   **只追加**方式打开的文件（`FILE_APPEND_DATA` 没有 `FILE_WRITE_DATA`，
    ///   `SetEndOfFile` 会被拒绝）。那种情况下**文件确实没变小**，绝不能报
    ///   `Done`。`Applied` 眼下没有「试了但失败」这一态，那是 QA-15（#291）
    ///   要收口的事；这里先保证「没做成就不说做成」。
    ///
    /// ⚠️ 句柄是**借来的**：只拿 raw handle 调 Win32，不包进任何会 Drop 的
    /// owned 类型——关掉它等于把 stderr 从整个进程手里拿走（unix 侧
    /// `ManuallyDrop` 那条教训）。
    fn truncate_own_stderr(&self) -> crate::Applied {
        use std::os::windows::io::AsRawHandle as _;
        use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::Storage::FileSystem::{
            GetFileType, SetEndOfFile, SetFilePointerEx, FILE_BEGIN, FILE_TYPE_DISK,
        };

        let handle = std::io::stderr().as_raw_handle() as HANDLE;
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return crate::Applied::NotApplicable;
        }
        // SAFETY: handle 是本进程的标准错误句柄，进程存活期间有效；这里只查询
        // 类型，不接管所有权。
        if unsafe { GetFileType(handle) } != FILE_TYPE_DISK {
            return crate::Applied::NotApplicable;
        }
        // SAFETY: 同上；新位置出参传 null 表示不关心。
        if unsafe { SetFilePointerEx(handle, 0, std::ptr::null_mut(), FILE_BEGIN) } == 0 {
            return crate::Applied::Unsupported;
        }
        // SAFETY: 同上；在当前位置（刚移到 0）截断。
        if unsafe { SetEndOfFile(handle) } == 0 {
            return crate::Applied::Unsupported;
        }
        crate::Applied::Done
    }

    /// QA-09 迁移（#211）：**机制上不需要**，这不是缺口。
    ///
    /// Windows 侧的 IPC 端点是命名管道，内核对象，不在文件系统里留文件，
    /// 所以不存在「被强杀的前任留下一个文件挡住 bind」这个问题。
    fn remove_stale_ipc_endpoint(&self, name: &str) -> crate::Applied {
        let _ = name;
        crate::Applied::NotApplicable
    }

    /// DESK-16 (#165)：Windows 这半的系统兜底 —— Shell 缩略图（COM）。
    /// 实现与注释在本文件下方的 `system_video_thumbnail`。
    fn system_video_thumbnail(
        &self,
        src: &Path,
        max_px: u32,
    ) -> crate::Result<Option<crate::SystemThumbnail>> {
        system_video_thumbnail(src, max_px)
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

/// RAII wrapper over the execution state held by the dedicated awake
/// thread (see `assert_awake`). Dropping disconnects the channel; the
/// thread clears its own state and is joined here.
pub struct ExecutionStateGuard {
    release: Option<std::sync::mpsc::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Drop for ExecutionStateGuard {
    fn drop(&mut self) {
        drop(self.release.take());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
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

/// SEC-07 (#289)：当前进程用户的 SID，按字节拷出来（`TOKEN_USER` 里的
/// `Sid` 指针指向同一块缓冲区内部，缓冲区活多久它就活多久）。
fn current_user_sid() -> Result<Vec<u8>> {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::Security::{
        GetLengthSid, GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: GetCurrentProcess 返回伪句柄，无需关闭；token 是栈上出参。
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(io_err("OpenProcessToken")(std::io::Error::last_os_error()));
    }
    let result = (|| {
        let mut len: u32 = 0;
        // 第一次调用只为拿到所需长度，预期失败（ERROR_INSUFFICIENT_BUFFER）。
        // SAFETY: 传 null 缓冲区 + 0 长度是文档允许的探长度用法。
        unsafe { GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut len) };
        if len == 0 {
            return Err(io_err("GetTokenInformation(len)")(
                std::io::Error::last_os_error(),
            ));
        }
        // u64 对齐的缓冲区：TOKEN_USER 里有指针，按字节 Vec 分配不保证对齐。
        let mut buf = vec![0u64; (len as usize).div_ceil(8)];
        // SAFETY: buf 至少 len 字节且 8 字节对齐；len 是上一次调用给的。
        if unsafe { GetTokenInformation(token, TokenUser, buf.as_mut_ptr().cast(), len, &mut len) }
            == 0
        {
            return Err(io_err("GetTokenInformation")(
                std::io::Error::last_os_error(),
            ));
        }
        // SAFETY: 成功返回后 buf 开头就是一个 TOKEN_USER。
        let sid = unsafe { (*buf.as_ptr().cast::<TOKEN_USER>()).User.Sid };
        // SAFETY: sid 指向 buf 内部的合法 SID。
        let sid_len = unsafe { GetLengthSid(sid) } as usize;
        // SAFETY: 同上，长度来自 GetLengthSid。
        Ok(unsafe { std::slice::from_raw_parts(sid.cast::<u8>(), sid_len) }.to_vec())
    })();
    // SAFETY: token 是 OpenProcessToken 成功返回的真句柄。
    unsafe { CloseHandle(token) };
    result
}

/// SEC-07 (#289)：见 `restrict_to_owner`。
fn restrict_to_current_user(path: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt as _;
    use windows_sys::Win32::Foundation::{LocalFree, ERROR_SUCCESS};
    use windows_sys::Win32::Security::Authorization::{
        SetEntriesInAclW, SetNamedSecurityInfoW, EXPLICIT_ACCESS_W, NO_MULTIPLE_TRUSTEE,
        SET_ACCESS, SE_FILE_OBJECT, TRUSTEE_IS_SID, TRUSTEE_IS_USER, TRUSTEE_W,
    };
    use windows_sys::Win32::Security::{
        ACL, DACL_SECURITY_INFORMATION, NO_INHERITANCE, PROTECTED_DACL_SECURITY_INFORMATION,
    };
    use windows_sys::Win32::Storage::FileSystem::FILE_ALL_ACCESS;

    let mut sid = current_user_sid()?;
    let access = EXPLICIT_ACCESS_W {
        grfAccessPermissions: FILE_ALL_ACCESS,
        grfAccessMode: SET_ACCESS,
        grfInheritance: NO_INHERITANCE,
        Trustee: TRUSTEE_W {
            pMultipleTrustee: std::ptr::null_mut(),
            MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
            TrusteeForm: TRUSTEE_IS_SID,
            TrusteeType: TRUSTEE_IS_USER,
            // TRUSTEE_IS_SID 时这个字段装的是 SID 指针（Win32 的惯用法）。
            ptstrName: sid.as_mut_ptr().cast(),
        },
    };
    let mut acl: *mut ACL = std::ptr::null_mut();
    // SAFETY: access 与它指向的 sid 在调用期间存活；oldacl 传 null = 从空
    // ACL 起建（不保留任何旧 ACE）；成功时 acl 是 LocalAlloc 的，下面释放。
    let rc = unsafe { SetEntriesInAclW(1, &access, std::ptr::null(), &mut acl) };
    if rc != ERROR_SUCCESS {
        return Err(io_err("SetEntriesInAclW")(
            std::io::Error::from_raw_os_error(rc as i32),
        ));
    }
    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: wide 是 NUL 结尾的宽字符串；只改 DACL，owner/group/SACL 传 null
    // 表示不动；acl 是上面建好的合法 ACL。
    let rc = unsafe {
        SetNamedSecurityInfoW(
            wide.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            acl,
            std::ptr::null(),
        )
    };
    // SAFETY: acl 由 SetEntriesInAclW 分配，此后不再使用。
    unsafe { LocalFree(acl.cast()) };
    if rc != ERROR_SUCCESS {
        return Err(io_err("SetNamedSecurityInfoW")(
            std::io::Error::from_raw_os_error(rc as i32),
        ));
    }
    Ok(())
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
    use std::io::Write as _;

    /// SEC-07 (#289) 契约：收紧之后 DACL **只剩当前用户一条 ACE**，且不再
    /// 继承父目录（`SE_DACL_PROTECTED`）。
    ///
    /// 判据刻意读的是**真实的 DACL**，不是返回值：返回 `Done` 而 ACL 没变，
    /// 正是 QA-09 那一轮在修的「静默没做却报成功」。收紧之前先断言文件带着
    /// 继承来的多条 ACE——前后一样就说明本测试什么都没验到。
    #[test]
    fn sec07_restrict_to_owner_leaves_only_the_current_user() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("identity.key");
        std::fs::write(&f, b"x").unwrap();

        let before = dacl_facts(&f);
        assert!(
            !before.protected && before.ace_count > 1,
            "起点应当是继承来的多条 ACE，否则本测试无判别力: {before:?}"
        );

        assert_eq!(
            WindowsAdapter::new().restrict_to_owner(&f).unwrap(),
            crate::Applied::Done
        );

        let after = dacl_facts(&f);
        assert!(after.protected, "继承没有切断: {after:?}");
        assert_eq!(after.ace_count, 1, "应当只剩一条 ACE: {after:?}");
        assert_eq!(
            after.sids,
            vec![current_user_sid().unwrap()],
            "唯一那条 ACE 不是当前用户: {after:?}"
        );
        // 属主自己仍然能读写——收紧不能把自己也锁在外面。
        std::fs::write(&f, b"y").unwrap();
        assert_eq!(std::fs::read(&f).unwrap(), b"y");
    }

    /// 与 unix 侧 `restrict_to_owner_fails_loudly_on_missing_file` 对齐：
    /// 路径不存在必须报错，不许静默回 `Done`。
    #[test]
    fn sec07_restrict_to_owner_fails_loudly_on_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("no-such.key");
        assert!(WindowsAdapter::new().restrict_to_owner(&missing).is_err());
    }

    #[derive(Debug)]
    struct DaclFacts {
        protected: bool,
        ace_count: u32,
        sids: Vec<Vec<u8>>,
    }

    /// 读回文件的真实 DACL：是否 protected、ACE 条数、每条 ACE 的 SID。
    fn dacl_facts(path: &Path) -> DaclFacts {
        use std::os::windows::ffi::OsStrExt as _;
        use windows_sys::Win32::Foundation::{LocalFree, ERROR_SUCCESS};
        use windows_sys::Win32::Security::Authorization::{GetNamedSecurityInfoW, SE_FILE_OBJECT};
        use windows_sys::Win32::Security::{
            GetAce, GetLengthSid, GetSecurityDescriptorControl, ACCESS_ALLOWED_ACE, ACL,
            DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, SE_DACL_PROTECTED,
        };
        let wide: Vec<u16> = path
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut dacl: *mut ACL = std::ptr::null_mut();
        let mut sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        // SAFETY: 测试辅助；出参都是栈上指针，sd 用完 LocalFree。
        unsafe {
            let rc = GetNamedSecurityInfoW(
                wide.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut dacl,
                std::ptr::null_mut(),
                &mut sd,
            );
            assert_eq!(rc, ERROR_SUCCESS, "GetNamedSecurityInfoW");
            let mut control: u16 = 0;
            let mut rev: u32 = 0;
            assert_ne!(GetSecurityDescriptorControl(sd, &mut control, &mut rev), 0);
            let ace_count = u32::from((*dacl).AceCount);
            let mut sids = Vec::new();
            for i in 0..ace_count {
                let mut ace: *mut core::ffi::c_void = std::ptr::null_mut();
                assert_ne!(GetAce(dacl, i, &mut ace), 0);
                // 只会出现 ACCESS_ALLOWED / DENIED 这类，SidStart 偏移相同。
                let sid = std::ptr::addr_of_mut!((*ace.cast::<ACCESS_ALLOWED_ACE>()).SidStart);
                let len = GetLengthSid(sid.cast()) as usize;
                sids.push(std::slice::from_raw_parts(sid.cast::<u8>(), len).to_vec());
            }
            LocalFree(sd.cast());
            DaclFacts {
                protected: control & SE_DACL_PROTECTED != 0,
                ace_count,
                sids,
            }
        }
    }

    // ── DEVLOG-04 (#290)：truncate_own_stderr ───────────────────────────
    //
    // 截的是**本进程自己的** stderr，所以测试必须在一个 stderr 被重定向过的
    // 子进程里跑：父进程把测试二进制自己再拉起一次（只跑 `child` 这一条），
    // 用环境变量告诉它该做什么，结果从 stdout 带回来。

    const DEVLOG04_CHILD_ENV: &str = "PPF_DEVLOG04_CHILD";

    /// 子进程入口。父进程没设环境变量时它什么都不做（直接跑到也是绿的）。
    #[test]
    fn devlog04_child() {
        if std::env::var_os(DEVLOG04_CHILD_ENV).is_none() {
            return;
        }
        // 先往 stderr 灌一批内容，模拟日志洪水。
        let mut err = std::io::stderr();
        for i in 0..2000 {
            let _ = writeln!(
                err,
                "flood line {i:05} ------------------------------------------"
            );
        }
        let _ = err.flush();
        if std::env::var_os("PPF_DEVLOG04_SKIP").is_some() {
            return;
        }
        let verdict = WindowsAdapter::new().truncate_own_stderr();
        // 截断之后、再写之前的文件大小（验收标准 1 要的「必须是 0」）。
        if let Some(path) = std::env::var_os("PPF_DEVLOG04_PATH") {
            let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(u64::MAX);
            println!("DEVLOG04_SIZE_AFTER={size}");
        }
        // 截断之后还能接着写，而且从 0 开始写（不能留出一段空洞）。
        let _ = write!(err, "after");
        let _ = err.flush();
        println!("DEVLOG04_VERDICT={verdict:?}");
    }

    /// 以给定的 stderr 拉起子进程，返回子进程报告的 `Applied`。
    fn devlog04_run_child(stderr: std::process::Stdio) -> String {
        devlog04_run_child_at(stderr, None).0
    }

    /// 同上；给了 `path` 时子进程还会报告截断那一刻的文件大小。
    fn devlog04_run_child_at(
        stderr: std::process::Stdio,
        path: Option<&Path>,
    ) -> (String, Option<String>) {
        let mut cmd = std::process::Command::new(std::env::current_exe().unwrap());
        if let Some(p) = path {
            cmd.env("PPF_DEVLOG04_PATH", p);
        }
        let out = cmd
            .args([
                "--exact",
                "windows::qa09_migrated_capability_tests::devlog04_child",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(DEVLOG04_CHILD_ENV, "1")
            .stdin(std::process::Stdio::null())
            .stderr(stderr)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        assert!(out.status.success(), "子进程失败: {stdout}");
        // libtest 可能把它们和 `test ... ` 打在同一行，按子串找。
        let field = |key: &str| {
            stdout
                .lines()
                .find_map(|l| l.split_once(key).map(|(_, v)| v.trim().to_string()))
        };
        let verdict =
            field("DEVLOG04_VERDICT=").unwrap_or_else(|| panic!("子进程没报结果: {stdout}"));
        (verdict, field("DEVLOG04_SIZE_AFTER="))
    }

    /// 验收标准 1 + 2：stderr 重定向到文件 → 灌入内容 → 截断 → 文件只剩截断
    /// 之后写的那几个字节。截断前的大小也记下来：没灌进去的话本测试等于
    /// 什么都没验。
    #[test]
    fn devlog04_truncates_a_redirected_stderr_file() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("daemon.err");
        let file = std::fs::File::create(&log).unwrap();
        let (verdict, size_after) = devlog04_run_child_at(file.into(), Some(&log));
        assert_eq!(
            size_after.as_deref(),
            Some("0"),
            "截断那一刻文件必须是 0 字节"
        );
        let bytes = std::fs::read(&log).unwrap();
        println!(
            "DEVLOG-04 verdict={verdict} 截断后文件={} 字节",
            bytes.len()
        );
        assert_eq!(verdict, "Done");
        assert_eq!(
            bytes, b"after",
            "截断后应当只剩之后写的 5 个字节（从 0 开始写、无空洞）"
        );
    }

    /// 反证对照：同样灌一批内容但**不截断**时文件有多大——证明上面那条
    /// 测试的「变小」是截断造成的，不是本来就没写进去。
    #[test]
    fn devlog04_flood_really_reaches_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("daemon.err");
        let file = std::fs::File::create(&log).unwrap();
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "windows::qa09_migrated_capability_tests::devlog04_child",
                "--nocapture",
            ])
            .env(DEVLOG04_CHILD_ENV, "1")
            .env("PPF_DEVLOG04_SKIP", "1")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(file)
            .status()
            .unwrap();
        assert!(status.success());
        let size = std::fs::metadata(&log).unwrap().len();
        println!("DEVLOG-04 不截断时文件={size} 字节");
        // 有截断时是 5 字节；这里至少是灌进去的 2000 行。
        assert!(size > 100_000, "洪水没写进文件，对照无效: {size}");
    }

    /// 验收标准 3：stderr 不是文件（这里用 `NUL` 字符设备 / 管道代表）时
    /// 不 panic，也不谎报 `Done`。
    #[test]
    fn devlog04_non_file_stderr_is_not_applicable() {
        assert_eq!(
            devlog04_run_child(std::process::Stdio::null()),
            "NotApplicable"
        );
        assert_eq!(
            devlog04_run_child(std::process::Stdio::piped()),
            "NotApplicable"
        );
    }

    /// 只追加打开的文件截不动：必须如实说没做成（`Unsupported`），文件也
    /// 确实没变小。
    #[test]
    fn devlog04_append_only_stderr_is_not_reported_as_done() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("daemon.err");
        std::fs::write(&log, b"").unwrap();
        let file = std::fs::OpenOptions::new().append(true).open(&log).unwrap();
        let verdict = devlog04_run_child(file.into());
        let size = std::fs::metadata(&log).unwrap().len();
        assert_eq!(verdict, "Unsupported", "只追加的文件截不动，不许报 Done");
        assert!(size > 100_000, "文件应当没被截断: {size}");
    }

    // ── DESK-17 (#166)：notify ───────────────────────────────────────────

    /// 验收标准 3（E2）：通知不可用时**不 panic、不阻塞调用方**。
    ///
    /// 用一个没有任何快捷方式认领的 AUMID，逼它走不可用的路径（CI runner 上
    /// 连通知平台本身都可能缺席，同一条判据）。调用必须立刻返回。
    #[test]
    fn desk17_notify_never_blocks_or_panics_when_unavailable() {
        let start = std::time::Instant::now();
        for _ in 0..20 {
            notify_as("ppf.desk17.no-such-app", "标题", "正文");
        }
        let elapsed = start.elapsed();
        assert!(
            elapsed < std::time::Duration::from_millis(500),
            "notify 阻塞了调用方: {elapsed:?}"
        );
        // 同步那一段本身也不能 panic——失败以 Err 形式回来。
        let _ = show_toast("ppf.desk17.no-such-app", "标题", "正文");
    }

    /// toast 负载必须是合法 XML，且标题 / 正文里的特殊字符被转义——
    /// 否则 `LoadXml` 失败，整条通知静默丢失。
    #[test]
    fn desk17_toast_xml_escapes_user_text() {
        let xml = toast_xml("备份 <完成> & \"好\"", "O'Brien 的 a<b.jpg");
        assert!(!xml.contains("<完成>"), "标题没转义: {xml}");
        assert!(xml.contains("&lt;完成&gt; &amp; &quot;好&quot;"), "{xml}");
        assert!(xml.contains("O&apos;Brien 的 a&lt;b.jpg"), "{xml}");
        // 用系统自己的 XML 解析器验合法性（与 show_toast 用的是同一个）。
        let doc = windows::Data::Xml::Dom::XmlDocument::new().unwrap();
        doc.LoadXml(&windows::core::HSTRING::from(xml)).unwrap();
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

/// DESK-25 (#208)：`taskkill` 用退出码区分「目标进程不存在」和真失败。
///
/// 实测（2026-09-18，Windows 11 26200）：进程在 → 0；进程不存在 → 128
/// `ERROR: The process "x" not found.`；非法参数 → 1。
///
/// 128 与 unix 侧 `pkill` 的 1 同义（[`crate::unix::PKILL_NO_MATCH`]）。
pub const TASKKILL_NOT_FOUND: i32 = 128;

/// 把 `taskkill` 的退出码翻译成结论。
///
/// 抽成纯函数是刻意的，而且这条判据是**有过事故的**：DESK-25 之前它被
/// 内联成一个裸 if、没人守着，于是「没杀掉」（权限不足 / 被杀软拦 /
/// 参数错）被当成杀成功，紧接着就去 spawn 第二个 daemon。
///
/// `code == None` 只在被信号终止时出现（Windows 上不会），保守算失败——
/// 「没法确认」不等于「成功」。
pub fn taskkill_verdict(
    success: bool,
    code: Option<i32>,
    stderr: &str,
) -> Result<crate::KillOutcome> {
    if success {
        Ok(crate::KillOutcome::Killed)
    } else if code == Some(TASKKILL_NOT_FOUND) {
        Ok(crate::KillOutcome::NotRunning)
    } else {
        Err(PlatformError::Failed {
            action: "kill_daemon_process",
            detail: format!("taskkill 退出码 {:?}（{}）", code, stderr.trim()),
        })
    }
}

/// QA-09 迁移（#211）：这组用例原来住在
/// `apps/desktop/src-tauri/src/lib.rs`，随被测函数一起搬过来。
/// 判据一个字没改，只是换了地方——搬家途中丢掉判别力是本次迁移最大的风险。
#[cfg(test)]
mod desk24_data_dir_tests {
    use super::*;

    fn env_dir(var: &str) -> PathBuf {
        PathBuf::from(std::env::var(var).unwrap_or_else(|_| ".".into()))
    }

    /// 本卡的全部目的：数据目录必须在 Local 下，不在 Roaming 下。
    #[test]
    fn the_current_data_dir_is_local_and_the_legacy_one_was_roaming() {
        assert!(
            current_data_dir().starts_with(env_dir("LOCALAPPDATA")),
            "现行数据目录必须在 %LOCALAPPDATA% 下：{}",
            current_data_dir().display()
        );
        assert!(
            legacy_data_dir().starts_with(env_dir("APPDATA")),
            "遗留位置的定义就是 %APPDATA%（Roaming）：{}",
            legacy_data_dir().display()
        );
        assert_ne!(
            legacy_data_dir(),
            current_data_dir(),
            "两者相等的话整张卡就没有意义了"
        );
    }

    /// **反证：数据目录不许踩进安装程序的地盘。**
    ///
    /// NSIS 单用户安装的 `$INSTDIR` 就是 `%LOCALAPPDATA%\P-Pass`——注册表
    /// `HKCU\...\Uninstall\P-Pass` 的 `InstallLocation` 实证，里面是
    /// `p-pass-desktop.exe` / `ppf-daemon.exe` / `uninstall.exe`。
    ///
    /// 「搬到 Local 去」最顺手的写法恰好就是那个错答案（把 `APPDATA` 改成
    /// `LOCALAPPDATA`、`P-Pass` 原样留着），所以这条必须由测试挡着。
    #[test]
    fn the_data_dir_must_not_be_the_installer_directory() {
        let install_dir = env_dir("LOCALAPPDATA").join("P-Pass");
        assert_ne!(
            current_data_dir(),
            install_dir,
            "那是安装目录（NSIS $INSTDIR），用户数据不许放进去"
        );
    }

    /// 目录名与 `tauri.conf.json` 的 `identifier` 是同一个字符串——那不是
    /// 巧合，是选它的理由（`%LOCALAPPDATA%\<identifier>` 已经是本应用的
    /// 本机数据根目录，Tauri 的 `EBWebView` 就在里面）。写死在这里，改名
    /// 时至少有一条测试会开口。
    #[test]
    fn the_directory_name_is_the_bundle_identifier() {
        assert_eq!(DATA_DIR_NAME, "com.p-pass.desktop");
        assert_eq!(current_data_dir().file_name().unwrap(), DATA_DIR_NAME);
    }

    /// 卡面验收标准第 3 条点名的那条性质：**DPAPI 密文搬了位置照样解得开。**
    ///
    /// 用的是真的 `CryptProtectData` / `CryptUnprotectData`，不是模拟——
    /// DPAPI 的用户态密钥挂在 Windows 账户上，与密文文件躺在哪个目录毫无
    /// 关系，所以同机搬家不影响解密。**跨机器才解不开**，而那正是本卡要
    /// 把数据目录挪出漫游目录的理由。
    ///
    /// 今天产品代码还没有一处调 `key_store()`（身份密钥是 data_dir 里的
    /// 明文文件，等 T-071 才进系统密钥仓），所以真机上没有密文可验。
    /// 这条把性质本身钉死，等密文真落地时不必回头补。
    #[test]
    fn a_dpapi_blob_still_decrypts_after_its_directory_moves() {
        let tmp = tempfile::tempdir().unwrap();
        let legacy_keys = tmp.path().join("Roaming").join("P-Pass").join("keys");
        let current = tmp.path().join("Local").join("com.p-pass.desktop");
        let secret = b"32-bytes-of-pretend-device-key!!";

        let before = DpapiStore {
            dir: legacy_keys.clone(),
        };
        before.store("device-key", secret).unwrap();
        assert!(legacy_keys.join("device-key.dpapi").is_file());

        // 搬家：同一台机器、同一个 Windows 用户，换个目录。
        std::fs::create_dir_all(&current).unwrap();
        std::fs::rename(&legacy_keys, current.join("keys")).unwrap();

        let after = DpapiStore {
            dir: current.join("keys"),
        };
        assert_eq!(
            after.load("device-key").unwrap().as_deref(),
            Some(&secret[..]),
            "同机搬家之后必须还解得开"
        );
    }

    /// 适配器返回的是**生效**目录：两者都不存在（全新安装）时应当是新位置。
    /// 有遗留目录时的分支由 `data_migration` 的用例覆盖，那边能造目录。
    #[test]
    fn a_fresh_machine_resolves_straight_to_the_new_location() {
        if legacy_data_dir().is_dir() {
            // 开发机上真有老目录（本卡的验收人机器就是），那这条不适用：
            // 此时 data_dir() 返回老目录才是对的。断言那个。
            assert_eq!(WindowsAdapter::new().data_dir(), legacy_data_dir());
            return;
        }
        assert_eq!(WindowsAdapter::new().data_dir(), current_data_dir());
    }
}

#[cfg(test)]
mod desk25_taskkill_tests {
    use super::*;
    use crate::KillOutcome;

    #[test]
    fn taskkill_success_is_not_a_failure() {
        assert_eq!(
            taskkill_verdict(true, Some(0), "").unwrap(),
            KillOutcome::Killed
        );
    }

    /// 128 = 进程本来就没在跑 ⇒ 正常结果，不是错误。
    #[test]
    fn taskkill_not_found_is_not_a_failure() {
        assert_eq!(
            taskkill_verdict(
                false,
                Some(TASKKILL_NOT_FOUND),
                "ERROR: The process \"x\" not found."
            )
            .unwrap(),
            KillOutcome::NotRunning
        );
    }

    /// 1 = 参数 / 权限问题 ⇒ 真失败。放松这条就回到 DESK-25 的原病。
    #[test]
    fn taskkill_other_nonzero_is_a_failure() {
        let e = taskkill_verdict(false, Some(1), "拒绝访问").unwrap_err();
        assert!(e.to_string().contains("退出码 Some(1)"), "{e}");
    }

    /// 拿不到退出码 ⇒ 保守算失败。
    #[test]
    fn taskkill_unknown_exit_status_is_a_failure() {
        assert!(taskkill_verdict(false, None, "").is_err());
    }

    /// 真机验一次「128 确实代表进程不存在」——判据的前提是**实测事实**，
    /// 不是文档。这条挂在一个必然不存在的进程名上。
    #[test]
    fn real_taskkill_reports_128_for_a_missing_process() {
        let out = Command::new("taskkill")
            .args(["/F", "/IM", "p-pass-no-such-process-zzz.exe"])
            .output()
            .expect("taskkill 必须存在于 Windows");
        assert_eq!(
            out.status.code(),
            Some(TASKKILL_NOT_FOUND),
            "stdout={} stderr={}",
            String::from_utf8_lossy(&out.stdout).trim(),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }

    /// Windows 的文件名就是基名加 `.exe`——两者漂开会让 taskkill 打空。
    #[test]
    fn executable_name_is_the_stem_plus_exe() {
        use crate::PlatformAdapter as _;
        assert_eq!(
            WindowsAdapter::new().daemon_executable_name(),
            format!("{}.exe", crate::DAEMON_EXECUTABLE_STEM)
        );
    }
}

/// DESK-16 (#165)：向 Windows Shell 要一帧视频首帧（COM）。
///
/// 为什么是 COM：macOS 那半能用 `/usr/bin/qlmanage` 这个 CLI，Windows **没有
/// 对等的命令行缩略图器**。Shell 的 `IShellItemImageFactory` 是系统自带能力，
/// 与 qlmanage 同一个姿态 —— 不 ship、不授权、零安装包体积。
///
/// ⚠️ **`SIIGBF_THUMBNAILONLY` 不是可选项**。不带它时 Shell 在拿不到真缩略图
/// 的情况下会**回退给文件类型图标**（那个蓝色的视频文件图标），而调用是成功
/// 的 —— 于是我们会把一个图标当作"首帧"写进缩略图，`thumb_state` 还报正常。
/// 那正是本仓这一轮一直在修的形状：静默给出错的东西而不是承认失败。带上它
/// 之后，没有真缩略图就是 `Err`，由调用方落到占位图。
///
/// ⚠️ 32bpp DIB 的字节序是 **BGRA**，不是 RGBA；下面显式换序。不换的话人脸
/// 会发蓝，而且"看起来能用"——又一个不会报错的错。
pub(crate) fn system_video_thumbnail(
    src: &std::path::Path,
    max_px: u32,
) -> crate::Result<Option<crate::SystemThumbnail>> {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::SIZE;
    use windows::Win32::Graphics::Gdi::{
        DeleteObject, GetDC, GetDIBits, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
    };
    use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED};
    use windows::Win32::UI::Shell::{
        IShellItemImageFactory, SHCreateItemFromParsingName, SIIGBF_THUMBNAILONLY,
    };

    // ⚠️ `SHCreateItemFromParsingName` 对**相对路径**返回 E_INVALIDARG
    // (0x80070057)，实测过。用 `std::path::absolute` 而不是 `canonicalize`：
    // 后者在 Windows 上会产出 `\?\C:\...` 这种 verbatim 前缀，Shell 的
    // 解析名接口对它同样不友好。absolute 只做"补全成绝对路径"这一件事。
    let abs = std::path::absolute(src).map_err(|source| crate::PlatformError::Io {
        action: "shell thumbnail: absolute path",
        source,
    })?;
    let path = abs.as_os_str();
    // COM 套间：单线程套间够用（本调用不跨线程传接口）。
    // RPC_E_CHANGED_MODE = 调用线程已经在别的套间里初始化过了 —— 那不是错误，
    // 继续用现有套间，但**不许**在结尾 CoUninitialize（那会拆掉别人的套间）。
    let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
    let we_initialized = hr.is_ok();

    let result = (|| -> crate::Result<crate::SystemThumbnail> {
        let factory: IShellItemImageFactory = unsafe {
            SHCreateItemFromParsingName(&HSTRING::from(path), None)
        }
        .map_err(|e| crate::PlatformError::Failed {
            action: "shell thumbnail: SHCreateItemFromParsingName",
            detail: format!("{}: {e}", src.display()),
        })?;

        let size = SIZE {
            cx: max_px as i32,
            cy: max_px as i32,
        };
        // THUMBNAILONLY：见上方注释，不带它会静默拿到文件类型图标。
        let hbitmap = unsafe { factory.GetImage(size, SIIGBF_THUMBNAILONLY) }.map_err(|e| {
            crate::PlatformError::Failed {
                action: "shell thumbnail: GetImage (THUMBNAILONLY)",
                detail: format!("no thumbnail for {}: {e}", src.display()),
            }
        })?;

        let out = (|| -> crate::Result<crate::SystemThumbnail> {
            let hdc = unsafe { GetDC(None) };
            if hdc.is_invalid() {
                return Err(crate::PlatformError::Failed {
                    action: "shell thumbnail: GetDC",
                    detail: "returned null".into(),
                });
            }
            let _dc_guard = DcGuard(hdc);

            // 先问尺寸（biBitCount=0 时 GetDIBits 只填头，不拷像素）。
            let mut info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    ..Default::default()
                },
                ..Default::default()
            };
            let probed = unsafe { GetDIBits(hdc, hbitmap, 0, 0, None, &mut info, DIB_RGB_COLORS) };
            if probed == 0 {
                return Err(crate::PlatformError::Failed {
                    action: "shell thumbnail: GetDIBits(probe)",
                    detail: "returned 0 — bitmap header unreadable".into(),
                });
            }
            let w = info.bmiHeader.biWidth;
            let h = info.bmiHeader.biHeight.abs();
            if w <= 0 || h == 0 {
                return Err(crate::PlatformError::Failed {
                    action: "shell thumbnail: size check",
                    detail: format!("degenerate size {w}x{h}"),
                });
            }

            // 取像素：强制 32bpp、BI_RGB、**负高度**（自顶向下），否则拿到的是
            // 自底向上的 DIB，图会上下颠倒——又一个不报错的错。
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biCompression = BI_RGB.0;
            info.bmiHeader.biHeight = -h;
            let mut buf = vec![0u8; (w as usize) * (h as usize) * 4];
            let copied = unsafe {
                GetDIBits(
                    hdc,
                    hbitmap,
                    0,
                    h as u32,
                    Some(buf.as_mut_ptr().cast()),
                    &mut info,
                    DIB_RGB_COLORS,
                )
            };
            if copied == 0 {
                return Err(crate::PlatformError::Failed {
                    action: "shell thumbnail: GetDIBits(pixels)",
                    detail: "returned 0 — no scanlines copied".into(),
                });
            }

            // BGRA → RGBA。
            for px in buf.as_chunks_mut::<4>().0 {
                px.swap(0, 2);
            }
            Ok(crate::SystemThumbnail {
                width: w as u32,
                height: h as u32,
                rgba: buf,
            })
        })();

        let _ = unsafe { DeleteObject(hbitmap.into()) };
        out
    })();

    if we_initialized {
        unsafe { CoUninitialize() };
    }
    result.map(Some)
}

/// 只为保证 `ReleaseDC` 在任何返回路径上都被调到（含 `?` 提前返回）。
struct DcGuard(windows::Win32::Graphics::Gdi::HDC);

impl Drop for DcGuard {
    fn drop(&mut self) {
        unsafe { windows::Win32::Graphics::Gdi::ReleaseDC(None, self.0) };
    }
}
