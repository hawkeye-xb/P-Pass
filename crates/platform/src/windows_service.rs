//! D1 / brief §5.1 第一步：把常驻 daemon 交给 **SCM**（Windows 服务管理器）。
//!
//! 这一层只做「服务在不在、跑到哪、起停、注册/删除、给主人授权」这些**系统操作**；
//! daemon 以服务身份运行（StartServiceCtrlDispatcher）与安装器（perMachine）是同一张
//! 卡的后续部分。在它们落地前，`WindowsAdapter::service_mode()` 仍返回计划任务，
//! 生产行为不变。
//!
//! 为什么不用 `sc.exe`：那是 console 程序，从 GUI 子系统的桌面壳里拉起来会闪黑窗
//! （DESK-19 #168 / DESK-52 #787 的同一类问题），而且拿不到结构化错误码。

use std::path::Path;

use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::ERROR_SERVICE_DOES_NOT_EXIST;
use windows::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
use windows::Win32::Security::{DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR};
use windows::Win32::System::Services::{
    ChangeServiceConfig2W, CloseServiceHandle, ControlService, CreateServiceW, DeleteService,
    OpenSCManagerW, OpenServiceW, QueryServiceStatusEx, SetServiceObjectSecurity, StartServiceW,
    SC_HANDLE, SC_MANAGER_CONNECT, SC_MANAGER_CREATE_SERVICE, SC_STATUS_PROCESS_INFO,
    SERVICE_ACCEPT_STOP, SERVICE_ALL_ACCESS, SERVICE_AUTO_START, SERVICE_CHANGE_CONFIG,
    SERVICE_CONTROL_STOP, SERVICE_ERROR_NORMAL, SERVICE_PAUSED, SERVICE_QUERY_STATUS,
    SERVICE_RUNNING, SERVICE_START, SERVICE_START_PENDING, SERVICE_STATUS, SERVICE_STATUS_PROCESS,
    SERVICE_STOP, SERVICE_STOPPED, SERVICE_STOP_PENDING, SERVICE_WIN32_OWN_PROCESS,
};

use crate::{PlatformError, Result};

/// 服务的当前状态（只列我们关心的几个，其余归到 `Unknown`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceState {
    Stopped,
    StartPending,
    StopPending,
    Running,
    Paused,
    Unknown(u32),
}

impl ServiceState {
    fn from_raw(raw: u32) -> Self {
        match raw {
            x if x == SERVICE_STOPPED.0 => Self::Stopped,
            x if x == SERVICE_START_PENDING.0 => Self::StartPending,
            x if x == SERVICE_STOP_PENDING.0 => Self::StopPending,
            x if x == SERVICE_RUNNING.0 => Self::Running,
            x if x == SERVICE_PAUSED.0 => Self::Paused,
            other => Self::Unknown(other),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ServiceStatus {
    pub state: ServiceState,
    /// `state == Running` 时的进程号；别的状态是 `None`。
    pub pid: Option<u32>,
    /// SCM 记下的 Win32 退出码（F7：正常停止 0，崩溃 1067）。
    pub exit_code: u32,
}

fn failed(action: &'static str, detail: impl Into<String>) -> PlatformError {
    PlatformError::Failed {
        action,
        detail: detail.into(),
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

struct Manager(SC_HANDLE);

impl Manager {
    fn open(access: u32) -> Result<Self> {
        // SAFETY: 本机 SCM；句柄由 Drop 关闭。
        let handle =
            unsafe { OpenSCManagerW(PCWSTR::null(), PCWSTR::null(), access) }.map_err(|e| {
                PlatformError::Io {
                    action: "OpenSCManagerW",
                    source: std::io::Error::from_raw_os_error(e.code().0),
                }
            })?;
        Ok(Self(handle))
    }
}

impl Drop for Manager {
    fn drop(&mut self) {
        // SAFETY: 句柄来自 OpenSCManagerW，只关一次。
        unsafe { CloseServiceHandle(self.0) }.ok();
    }
}

struct Service(SC_HANDLE);

impl Service {
    fn open(name: &str, access: u32) -> Result<Option<Self>> {
        let manager = Manager::open(SC_MANAGER_CONNECT)?;
        let name_w = wide(name);
        // SAFETY: name_w 是 NUL 结尾；OpenServiceW 的失败有两种：不存在 vs 其他。
        match unsafe { OpenServiceW(manager.0, PCWSTR(name_w.as_ptr()), access) } {
            Ok(handle) => Ok(Some(Self(handle))),
            Err(e)
                if e.code()
                    == windows::core::HRESULT::from_win32(ERROR_SERVICE_DOES_NOT_EXIST.0) =>
            {
                Ok(None)
            }
            Err(e) => Err(PlatformError::Io {
                action: "OpenServiceW",
                source: std::io::Error::from_raw_os_error(e.code().0),
            }),
        }
    }
}

impl Drop for Service {
    fn drop(&mut self) {
        // SAFETY: 句柄来自 OpenServiceW/CreateServiceW，只关一次。
        unsafe { CloseServiceHandle(self.0) }.ok();
    }
}

/// 这台机器上有没有这个服务。
pub fn is_installed(name: &str) -> Result<bool> {
    Ok(Service::open(name, SERVICE_QUERY_STATUS)?.is_some())
}

/// 服务状态；服务没装时 `Ok(None)`（不是错误——「还没装」是常规路径）。
pub fn status(name: &str) -> Result<Option<ServiceStatus>> {
    let Some(service) = Service::open(name, SERVICE_QUERY_STATUS)? else {
        return Ok(None);
    };
    let mut raw = SERVICE_STATUS_PROCESS::default();
    let mut needed = 0u32;
    // SAFETY: raw 是正确大小的结构体，长度按字节给。
    let bytes = unsafe {
        std::slice::from_raw_parts_mut(
            (&mut raw as *mut SERVICE_STATUS_PROCESS).cast::<u8>(),
            std::mem::size_of::<SERVICE_STATUS_PROCESS>(),
        )
    };
    unsafe { QueryServiceStatusEx(service.0, SC_STATUS_PROCESS_INFO, Some(bytes), &mut needed) }
        .map_err(|e| PlatformError::Io {
            action: "QueryServiceStatusEx",
            source: std::io::Error::from_raw_os_error(e.code().0),
        })?;
    let state = ServiceState::from_raw(raw.dwCurrentState.0);
    let pid = matches!(state, ServiceState::Running).then_some(raw.dwProcessId);
    Ok(Some(ServiceStatus {
        state,
        pid,
        exit_code: raw.dwWin32ExitCode,
    }))
}

/// 服务的 ImagePath（注册时写的可执行文件路径），读不到给 `None`。
///
/// 只看第一个 token：SCM 的 BinaryPathName 可能带参数、也可能带引号。
pub fn image_path(name: &str) -> Result<Option<std::path::PathBuf>> {
    Ok(service_config(name)?.and_then(|c| c.image_path))
}

/// 一次 `QueryServiceConfigW` 读出来的、我们关心的两项。
///
/// 结构体里的指针指向临时缓冲，所以在函数内就转成拥有所有权的值，不把裸指针带出去。
struct ServiceConfig {
    start_type: ServiceStartType,
    image_path: Option<std::path::PathBuf>,
}

fn service_config(name: &str) -> Result<Option<ServiceConfig>> {
    use windows::Win32::System::Services::{QueryServiceConfigW, QUERY_SERVICE_CONFIGW};

    let Some(service) =
        Service::open(name, windows::Win32::System::Services::SERVICE_QUERY_CONFIG)?
    else {
        return Ok(None);
    };
    let mut needed = 0u32;
    // SAFETY: 先问长度；这次调用失败是预期的（只取 needed）。
    unsafe { QueryServiceConfigW(service.0, None, 0, &mut needed) }.ok();
    let mut buf = vec![0u8; needed.max(1024) as usize];
    // SAFETY: buf 按 SCM 报的 needed 分配，结构体写在 buf 开头。
    unsafe {
        QueryServiceConfigW(
            service.0,
            Some(buf.as_mut_ptr() as *mut QUERY_SERVICE_CONFIGW),
            buf.len() as u32,
            &mut needed,
        )
    }
    .map_err(|e| PlatformError::Io {
        action: "QueryServiceConfigW",
        source: std::io::Error::from_raw_os_error(e.code().0),
    })?;
    let config = unsafe { &*(buf.as_ptr() as *const QUERY_SERVICE_CONFIGW) };
    let raw = if config.lpBinaryPathName.0.is_null() {
        String::new()
    } else {
        unsafe { config.lpBinaryPathName.to_string() }.unwrap_or_default()
    };
    Ok(Some(ServiceConfig {
        start_type: ServiceStartType::from_raw(config.dwStartType.0),
        image_path: parse_image_path(&raw),
    }))
}

/// 从 `"C:\path\app.exe" --flag` 里取可执行文件路径（去掉引号、参数）。
fn parse_image_path(raw: &str) -> Option<std::path::PathBuf> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let exe = match raw.strip_prefix('"') {
        // 引号没闭合 ⇒ 读不出，不猜。
        Some(rest) => &rest[..rest.find('"')?],
        None => raw.split_whitespace().next().unwrap_or(raw),
    };
    (!exe.is_empty()).then(|| std::path::PathBuf::from(exe))
}

/// 服务的启动类型（只区分我们关心的三档）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceStartType {
    Auto,
    Manual,
    Disabled,
    Other(u32),
}

impl ServiceStartType {
    fn from_raw(raw: u32) -> Self {
        use windows::Win32::System::Services::{
            SERVICE_AUTO_START, SERVICE_DEMAND_START, SERVICE_DISABLED,
        };
        if raw == SERVICE_AUTO_START.0 {
            Self::Auto
        } else if raw == SERVICE_DEMAND_START.0 {
            Self::Manual
        } else if raw == SERVICE_DISABLED.0 {
            Self::Disabled
        } else {
            Self::Other(raw)
        }
    }
}

/// 服务的启动类型。§5.1「用户在 P-Pass 里停服务 = 设为禁用，绝不自动拉回」
/// 要读它来判断当前是不是「用户主动停的」状态。
pub fn start_type(name: &str) -> Result<Option<ServiceStartType>> {
    Ok(service_config(name)?.map(|c| c.start_type))
}

/// 改启动类型。§5.1 的「尊重用户停服务」靠它：用户停止 → [`ServiceStartType::Disabled`]
/// （重启电脑也不会被拉回来），用户在 App 里重新启动 → 改回 [`ServiceStartType::Auto`]。
///
/// 只改这一项，其余字段用 `SERVICE_NO_CHANGE` 原样保留——不会顺手改掉 binPath、
/// 服务账户或失败动作。要求 `SERVICE_CHANGE_CONFIG`：安装器的 `sc sdset` 已把
/// `DC` 授给交互用户，所以停/开服务不弹 UAC。
pub fn set_start_type(name: &str, start: ServiceStartType) -> Result<()> {
    use windows::Win32::System::Services::{
        ChangeServiceConfigW, ENUM_SERVICE_TYPE, SERVICE_DEMAND_START, SERVICE_DISABLED,
        SERVICE_ERROR, SERVICE_NO_CHANGE, SERVICE_START_TYPE,
    };

    let Some(service) = Service::open(name, SERVICE_CHANGE_CONFIG)? else {
        return Err(failed("set_start_type", format!("服务未安装：{name}")));
    };
    let raw = match start {
        ServiceStartType::Auto => SERVICE_AUTO_START,
        ServiceStartType::Manual => SERVICE_DEMAND_START,
        ServiceStartType::Disabled => SERVICE_DISABLED,
        ServiceStartType::Other(raw) => SERVICE_START_TYPE(raw),
    };
    // SAFETY: 服务句柄有效；除启动类型外全部 `SERVICE_NO_CHANGE` + 空指针。
    unsafe {
        ChangeServiceConfigW(
            service.0,
            ENUM_SERVICE_TYPE(SERVICE_NO_CHANGE),
            raw,
            SERVICE_ERROR(SERVICE_NO_CHANGE),
            PCWSTR::null(),
            PCWSTR::null(),
            None,
            PCWSTR::null(),
            PCWSTR::null(),
            PCWSTR::null(),
            PCWSTR::null(),
        )
    }
    .map_err(|e| PlatformError::Io {
        action: "ChangeServiceConfigW",
        source: std::io::Error::from_raw_os_error(e.code().0),
    })
}

/// 起服务（幂等：已经在跑就返回 `Ok`）。
pub fn start(name: &str) -> Result<()> {
    let Some(service) = Service::open(name, SERVICE_START | SERVICE_QUERY_STATUS)? else {
        return Err(failed("start_service", format!("服务未安装：{name}")));
    };
    // SAFETY: 服务句柄有效；不传参数。
    match unsafe { StartServiceW(service.0, None) } {
        Ok(()) => Ok(()),
        // 失败若是「已经在跑」，按幂等处理。
        Err(e) => match status(name)? {
            Some(s) if matches!(s.state, ServiceState::Running | ServiceState::StartPending) => {
                Ok(())
            }
            _ => Err(PlatformError::Io {
                action: "StartServiceW",
                source: std::io::Error::from_raw_os_error(e.code().0),
            }),
        },
    }
}

/// 停服务并等它真的停下（最多 10 秒）；没在跑也算成功。
pub fn stop(name: &str) -> Result<()> {
    let Some(service) = Service::open(name, SERVICE_STOP | SERVICE_QUERY_STATUS)? else {
        return Ok(());
    };
    let mut status = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: SERVICE_RUNNING,
        dwControlsAccepted: SERVICE_ACCEPT_STOP,
        dwWin32ExitCode: 0,
        dwServiceSpecificExitCode: 0,
        dwCheckPoint: 0,
        dwWaitHint: 0,
    };
    // SAFETY: 服务句柄与 status 都有效。
    let _ = unsafe { ControlService(service.0, SERVICE_CONTROL_STOP, &mut status) };
    wait_for(name, |s| matches!(s, ServiceState::Stopped))
}

fn wait_for(name: &str, wanted: impl Fn(ServiceState) -> bool) -> Result<()> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        match status(name)? {
            None => return Ok(()),
            Some(s) if wanted(s.state) => return Ok(()),
            Some(_) if std::time::Instant::now() >= deadline => {
                return Err(failed(
                    "wait_service_state",
                    format!("等待 {name} 状态超时"),
                ));
            }
            Some(_) => std::thread::sleep(std::time::Duration::from_millis(100)),
        }
    }
}

/// 注册服务：自动启动、以**虚拟服务账户**运行（`NT SERVICE\<name>`），不是 LocalSystem。
pub fn install(name: &str, display_name: &str, exe: &Path, args: &[&str]) -> Result<()> {
    let manager = Manager::open(SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE)?;
    let mut command_line = format!("\"{}\"", exe.display());
    for a in args {
        command_line.push(' ');
        command_line.push_str(a);
    }
    let name_w = wide(name);
    let display_w = wide(display_name);
    let bin_w = wide(&command_line);
    let account_w = wide(&format!("NT SERVICE\\{name}"));
    // SAFETY: 所有字符串都是 NUL 结尾；服务创建后由 Drop 关闭句柄。
    let handle = unsafe {
        CreateServiceW(
            manager.0,
            PCWSTR(name_w.as_ptr()),
            PCWSTR(display_w.as_ptr()),
            SERVICE_ALL_ACCESS,
            SERVICE_WIN32_OWN_PROCESS,
            SERVICE_AUTO_START,
            SERVICE_ERROR_NORMAL,
            PCWSTR(bin_w.as_ptr()),
            None,
            None,
            None,
            PCWSTR(account_w.as_ptr()),
            None,
        )
    }
    .map_err(|e| PlatformError::Io {
        action: "CreateServiceW",
        source: std::io::Error::from_raw_os_error(e.code().0),
    })?;
    let service = Service(handle);
    // 失败自动重启（等价于 launchd KeepAlive 的第一层）。
    let mut actions = vec![
        windows::Win32::System::Services::SC_ACTION {
            Type: windows::Win32::System::Services::SC_ACTION_RESTART,
            Delay: 5_000,
        };
        2
    ];
    actions.push(windows::Win32::System::Services::SC_ACTION {
        Type: windows::Win32::System::Services::SC_ACTION_NONE,
        Delay: 0,
    });
    let mut failure = windows::Win32::System::Services::SERVICE_FAILURE_ACTIONSW {
        dwResetPeriod: 86_400,
        lpRebootMsg: PWSTR::null(),
        lpCommand: PWSTR::null(),
        cActions: actions.len() as u32,
        lpsaActions: actions.as_mut_ptr(),
    };
    // SAFETY: failure 与 actions 在调用期间存活。
    unsafe {
        ChangeServiceConfig2W(
            service.0,
            windows::Win32::System::Services::SERVICE_CONFIG_FAILURE_ACTIONS,
            Some(
                (&mut failure as *mut windows::Win32::System::Services::SERVICE_FAILURE_ACTIONSW)
                    .cast(),
            ),
        )
    }
    .ok();
    Ok(())
}

/// 停止并删除服务；本来就没有不算错。
pub fn uninstall(name: &str) -> Result<()> {
    stop(name)?;
    let Some(service) = Service::open(name, windows::Win32::Storage::FileSystem::DELETE.0)? else {
        return Ok(());
    };
    // SAFETY: 句柄有效。
    unsafe { DeleteService(service.0) }.map_err(|e| PlatformError::Io {
        action: "DeleteService",
        source: std::io::Error::from_raw_os_error(e.code().0),
    })
}

/// 「用户希望这个服务运行吗」的开关文件：`%ProgramData%\P-Pass\wanted-state`。
///
/// §5.1 的「尊重用户停服务」在 Windows 上没有免提权的实现：改启动类型要
/// `SERVICE_CHANGE_CONFIG`，把它给普通用户等于允许改 binPath、以服务账户跑任意
/// 代码（D4 作废）。所以改成**服务自检**：用户点停止 → 壳写 `stopped`；开机时
/// SCM 拉起服务，daemon 第一件事读这个文件，看到 `stopped` 就 `exit 0`（成功退出，
/// SCM 不会重启）——表现就是「停着」。点启动 → 壳写回 `running` 再 `sc start`。
///
/// 文件只是**一个开关**，不含任何数据；给交互用户读写不扩大他的权限（他本来就有
/// `RP`/`WP`）。父目录仍然是私有的，用户只能按全路径打开这一个文件（列目录仍被拒）。
pub fn wanted_state_path() -> std::path::PathBuf {
    std::path::Path::new(r"C:\ProgramData\P-Pass").join("wanted-state")
}

// #1238：开关文件的读写挪到 `crate::stop_switch`（三平台都编译、都跑单测——壳在 macOS 上
// 也要测服务形态的判据）；这里保留原名供 daemon / 适配器调用。
pub use crate::stop_switch::{read_at as read_wanted_state_at, write_at as write_wanted_state_at};

/// 把启动 / 停止 / 查询的权限授给 `owner_sid`（§5.1：普通用户控制服务不弹 UAC）。
///
/// 服务 SD 用 SDDL 表达：`CC`=查询配置、`LC`=查询状态、`RP`=启动、`WP`=停止。
pub fn grant_owner_control(name: &str, owner_sid: &str) -> Result<()> {
    let Some(service) = Service::open(name, SERVICE_CHANGE_CONFIG)? else {
        return Err(failed(
            "grant_service_control",
            format!("服务未安装：{name}"),
        ));
    };
    let sddl = format!(
        "D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCLCSWRPWPDTLOCRRC;;;BA)\
         (A;;CCLCSWRPWPDTLOCRRC;;;{owner_sid})"
    );
    let sddl_w = wide(&sddl);
    let mut sd = PSECURITY_DESCRIPTOR::default();
    // SAFETY: sddl_w 是 NUL 结尾；sd 由 LocalAlloc，用完 LocalFree。
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(sddl_w.as_ptr()),
            1,
            &mut sd,
            None,
        )
    }
    .map_err(|e| PlatformError::Io {
        action: "ConvertStringSecurityDescriptorToSecurityDescriptorW",
        source: std::io::Error::from_raw_os_error(e.code().0),
    })?;
    // SAFETY: sd 合法；只改 DACL。
    let result = unsafe { SetServiceObjectSecurity(service.0, DACL_SECURITY_INFORMATION, sd) };
    unsafe {
        windows::Win32::Foundation::LocalFree(Some(windows::Win32::Foundation::HLOCAL(sd.0)))
    };
    result.map_err(|e| PlatformError::Io {
        action: "SetServiceObjectSecurity",
        source: std::io::Error::from_raw_os_error(e.code().0),
    })
}

// ── SCM 分发器：daemon 以服务身份运行 ───────────────────────────────────────

/// 服务名。与 identifier `com.hawkeyexb.ppass.desktop` 对齐（#1112 统一过命名）。
pub const SERVICE_NAME: &str = "P-Pass";

/// daemon 的服务入口：`body` 在 SCM 的服务线程上跑，返回进程退出码。
static SERVICE_BODY: std::sync::Mutex<Option<Box<dyn FnOnce() -> i32 + Send>>> =
    std::sync::Mutex::new(None);

/// D4：本进程此刻是不是由 SCM 拉起的服务（`service_main` 已进入）。
///
/// 适配器据此把数据根从用户的 `%LOCALAPPDATA%` 切到 `%ProgramData%\P-Pass`：
/// 服务账户 `NT SERVICE\P-Pass` 的配置文件在 `C:\Windows\ServiceProfiles\` 下，
/// 它读不到交互用户的任何用户级路径。默认 `false`＝控制台 / 桌面壳 spawn。
static RUNNING_AS_SERVICE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// 本进程是否运行在 SCM 的服务分发器里。见 [`RUNNING_AS_SERVICE`]。
pub fn is_running_as_service() -> bool {
    RUNNING_AS_SERVICE.load(std::sync::atomic::Ordering::SeqCst)
}
static SERVICE_STATUS_HANDLE_RAW: std::sync::atomic::AtomicPtr<std::ffi::c_void> =
    std::sync::atomic::AtomicPtr::new(std::ptr::null_mut());

fn set_service_status(
    state: windows::Win32::System::Services::SERVICE_STATUS_CURRENT_STATE,
    accepted: u32,
) {
    use windows::Win32::System::Services::{
        SetServiceStatus, SERVICE_STATUS, SERVICE_WIN32_OWN_PROCESS,
    };
    let handle = SERVICE_STATUS_HANDLE_RAW.load(std::sync::atomic::Ordering::SeqCst);
    if handle.is_null() {
        return;
    }
    let status = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: state,
        dwControlsAccepted: accepted,
        dwWin32ExitCode: 0,
        dwServiceSpecificExitCode: 0,
        dwCheckPoint: 0,
        dwWaitHint: 0,
    };
    // SAFETY: handle 来自 RegisterServiceCtrlHandlerExW，set 之后只读。
    unsafe {
        SetServiceStatus(
            windows::Win32::System::Services::SERVICE_STATUS_HANDLE(handle),
            &status,
        )
    }
    .ok();
}

unsafe extern "system" fn service_control_handler(
    control: u32,
    _event_type: u32,
    _event_data: *mut std::ffi::c_void,
    _context: *mut std::ffi::c_void,
) -> u32 {
    use windows::Win32::System::Services::{
        SERVICE_ACCEPT_STOP, SERVICE_CONTROL_STOP, SERVICE_STOP_PENDING,
    };
    if control == SERVICE_CONTROL_STOP || control == 5 {
        // SHUTDOWN 也按停止处理：收尾后退出，由 SCM 记录。
        boot_log("service control: STOP");
        set_service_status(SERVICE_STOP_PENDING, SERVICE_ACCEPT_STOP);
        crate::signal::request_stop("SERVICE_CONTROL_STOP");
        return 0;
    }
    0
}

unsafe extern "system" fn service_main(_argc: u32, _argv: *mut PWSTR) {
    use windows::Win32::System::Services::{
        RegisterServiceCtrlHandlerExW, SERVICE_ACCEPT_SHUTDOWN, SERVICE_ACCEPT_STOP,
        SERVICE_RUNNING, SERVICE_START_PENDING, SERVICE_STOPPED,
    };

    boot_log("service main: entered");
    // 服务没有控制台：把 stderr 接到启动日志，daemon 的 eprintln 才看得见
    // （1067 的真实原因往往就写在那些早期错误里）。
    redirect_stderr_to_boot_log();
    // 服务里的 panic 没有控制台可看：先落盘。反证：不装这个钩子，1067 什么线索都没有。
    std::panic::set_hook(Box::new(|info| {
        boot_log(&format!("PANIC: {info}"));
    }));
    let name_w = wide(SERVICE_NAME);
    let Ok(handle) =
        RegisterServiceCtrlHandlerExW(PCWSTR(name_w.as_ptr()), Some(service_control_handler), None)
    else {
        return;
    };
    // D4：从这一刻起，凡问「数据根在哪」都必须是 %ProgramData%\P-Pass。
    // 在跑 body 之前设，早于任何配置 / 身份读写。
    RUNNING_AS_SERVICE.store(true, std::sync::atomic::Ordering::SeqCst);
    SERVICE_STATUS_HANDLE_RAW.store(handle.0, std::sync::atomic::Ordering::SeqCst);
    set_service_status(SERVICE_START_PENDING, 0);
    set_service_status(
        SERVICE_RUNNING,
        SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN,
    );

    let body = SERVICE_BODY.lock().ok().and_then(|mut g| g.take());
    if let Some(body) = body {
        let _ = body();
    }
    boot_log("service body: exited");
    set_service_status(SERVICE_STOPPED, 0);
}

/// D1：服务没有控制台，stderr 也看不到。启动阶段的致命错误（含 panic）写这里，
/// 早于读取任何配置/身份。目录由安装器建好；写不进去也不影响启动。
pub fn boot_log(msg: &str) {
    use std::io::Write as _;
    let dir = std::path::Path::new(r"C:\ProgramData\P-Pass\logs");
    let _ = std::fs::create_dir_all(dir);
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("daemon-boot.log"))
    {
        let _ = writeln!(
            f,
            "[{:?}] {}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
            msg
        );
    }
}

/// 让 SCM 看到「服务已正常停止」。
///
/// 进程在服务主体里自己 `exit`（例如收到停止信号后走 `StopRequest::finish`）之前
/// 必须调它：不调，SCM 会把「进程没了但状态还停在 STOP_PENDING」记成 1067
/// （进程意外终止），哪怕退出码是 0（真机实测）。非服务上下文是 no-op。
pub fn mark_stopped() {
    boot_log("service: stopped");
    set_service_status(SERVICE_STOPPED, 0);
}

/// 把本进程的 STD_ERROR_HANDLE 指向启动日志（追加）。失败就算了，不影响启动。
fn redirect_stderr_to_boot_log() {
    use std::os::windows::io::AsRawHandle as _;
    use windows_sys::Win32::System::Console::{SetStdHandle, STD_ERROR_HANDLE};

    let dir = std::path::Path::new(r"C:\ProgramData\P-Pass\logs");
    let _ = std::fs::create_dir_all(dir);
    let Ok(file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("daemon-boot.log"))
    else {
        return;
    };
    let handle = file.as_raw_handle();
    // SAFETY: 句柄属于 file；进程生命周期内不能让 file 被 drop 关闭。
    let ok = unsafe { SetStdHandle(STD_ERROR_HANDLE, handle) } != 0;
    if ok {
        std::mem::forget(file);
    }
}

/// 如果本进程是被 SCM 拉起的，就在**当前线程**跑 SCM 分发器，并在服务线程上执行
/// `body`；返回 `Ok(true)`。
///
/// 不是服务上下文（控制台/桌面壳直接 spawn）时 `StartServiceCtrlDispatcherW` 以
/// `ERROR_FAILED_SERVICE_CONTROLLER_CONNECT` 失败，返回 `Ok(false)`——这条路径必须在
/// 30 秒内让 SCM 看到分发器，所以调用方要在任何重活之前调它。
pub fn run_service_dispatcher(body: impl FnOnce() -> i32 + Send + 'static) -> Result<bool> {
    use windows::Win32::Foundation::ERROR_FAILED_SERVICE_CONTROLLER_CONNECT;
    use windows::Win32::System::Services::{StartServiceCtrlDispatcherW, SERVICE_TABLE_ENTRYW};

    // 这里**还不知道**是不是被 SCM 拉起：控制台、测试、安装器的 `--version`、壳的 shell-out
    // 也都走到这儿。所以这里不写启动日志、不改 stderr、不装 panic 钩子——那些只在
    // `service_main`（SCM 确认是服务之后）里做。以前放在这里，所有控制台调用的 stderr 都被
    // 吞进 ProgramData 的启动日志（CI 上 cli_flow 等用例读不到「用法」），还会以调用者身份
    // 建出默认 ACL 的 `%ProgramData%\P-Pass\logs`（#1167）。
    if let Ok(mut slot) = SERVICE_BODY.lock() {
        *slot = Some(Box::new(body));
    }
    let mut name_w = wide(SERVICE_NAME);
    let mut table = [
        SERVICE_TABLE_ENTRYW {
            lpServiceName: PWSTR(name_w.as_mut_ptr()),
            lpServiceProc: Some(service_main),
        },
        SERVICE_TABLE_ENTRYW::default(),
    ];
    // SAFETY: name_w 在分发器返回前一直存活；表以零项结尾。
    match unsafe { StartServiceCtrlDispatcherW(table.as_mut_ptr()) } {
        Ok(()) => {
            boot_log("dispatcher: returned Ok");
            Ok(true)
        }
        Err(e)
            if e.code()
                == windows::core::HRESULT::from_win32(
                    ERROR_FAILED_SERVICE_CONTROLLER_CONNECT.0,
                ) =>
        {
            Ok(false)
        }
        Err(e) => Err(PlatformError::Io {
            action: "StartServiceCtrlDispatcherW",
            source: std::io::Error::from_raw_os_error(e.code().0),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// SCM 查询只读：拿系统里一定存在的服务验「能读到状态」，不是读返回值。
    #[test]
    fn queries_a_builtin_service() {
        let name = "EventLog";
        assert!(is_installed(name).expect("is_installed"));
        let status = status(name).expect("status").expect("EventLog 一定存在");
        assert!(matches!(
            status.state,
            ServiceState::Running | ServiceState::Stopped | ServiceState::StartPending
        ));
        if matches!(status.state, ServiceState::Running) {
            assert!(status.pid.is_some_and(|pid| pid > 0));
        }
    }

    /// 不存在的服务名：`is_installed` 是 `false`、`status` 是 `None`，都不是错误。
    #[test]
    fn unknown_service_is_absent_not_an_error() {
        let name = "PPassDefinitelyNotInstalledService";
        assert!(!is_installed(name).expect("is_installed"));
        assert!(status(name).expect("status").is_none());
    }
}

#[cfg(all(test, windows))]
mod dispatcher_tests {
    use super::*;

    /// 从普通进程（测试/控制台）调分发器：必须是 `Ok(false)`，不是错误、也不阻塞。
    #[test]
    fn dispatcher_reports_not_a_service_outside_scm() {
        let ran = run_service_dispatcher(|| 0).expect("不是服务不是错误");
        assert!(!ran, "测试进程不是 SCM 启动的");
    }
}

#[cfg(all(test, windows))]
mod image_path_tests {
    use super::*;

    /// 读系统服务的 ImagePath：EventLog 的 BinaryPathName 是
    /// `C:\Windows\system32\svchost.exe -k LocalServiceNetworkRestricted ...`，第一个 token 是 exe。
    #[test]
    fn reads_a_builtin_service_image_path() {
        let path = image_path("EventLog")
            .expect("image_path")
            .expect("EventLog 存在");
        assert!(path.is_absolute(), "{path:?}");
        assert_eq!(
            path.file_name()
                .and_then(|n| n.to_str())
                .map(str::to_ascii_lowercase),
            Some("svchost.exe".to_string()),
            "{path:?}"
        );
    }

    #[test]
    fn unknown_service_has_no_image_path() {
        assert!(image_path("PPassDefinitelyNotInstalledService")
            .expect("image_path")
            .is_none());
    }

    #[test]
    fn parses_quoted_and_bare_image_paths() {
        assert_eq!(
            parse_image_path("\"C:\\Program Files\\P-Pass\\ppf-daemon.exe\" --service"),
            Some(std::path::PathBuf::from(
                "C:\\Program Files\\P-Pass\\ppf-daemon.exe"
            ))
        );
        assert_eq!(
            parse_image_path("C:\\Windows\\system32\\svchost.exe -k LocalService"),
            Some(std::path::PathBuf::from(
                "C:\\Windows\\system32\\svchost.exe"
            ))
        );
        assert_eq!(parse_image_path(""), None);
        assert_eq!(parse_image_path("\"unterminated"), None);
    }
}

#[cfg(all(test, windows))]
mod start_type_tests {
    use super::*;

    /// EventLog 是系统自带的自动启动服务：读真实 SCM 的启动类型。
    #[test]
    fn reads_a_builtin_service_start_type() {
        assert_eq!(
            start_type("EventLog").expect("start_type"),
            Some(ServiceStartType::Auto)
        );
    }

    #[test]
    fn unknown_service_has_no_start_type() {
        assert!(start_type("PPassDefinitelyNotInstalledService")
            .expect("start_type")
            .is_none());
    }

    /// 反证：对不存在的服务改启动类型必须报错，不能静默成功。
    /// （真机上的「改成 Disabled 后重启不再起来」是 A15，需要已安装的服务 + 管理员，见 #1161。）
    #[test]
    fn changing_the_start_type_of_a_missing_service_is_an_error() {
        let err = set_start_type(
            "PPassDefinitelyNotInstalledService",
            ServiceStartType::Disabled,
        )
        .expect_err("不存在的服务不能改");
        assert!(format!("{err}").contains("服务未安装"), "{err}");
    }
}
