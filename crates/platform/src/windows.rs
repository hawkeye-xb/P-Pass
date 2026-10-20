//! Windows adapter (§4 对照表左列).
//!
//! - Autostart: a per-user Task Scheduler task (DESK-65 #957) — logon
//!   trigger + a once-a-minute watchdog trigger, the Windows counterpart
//!   of launchd's RunAtLoad + KeepAlive. User-level, no admin, no SCM
//!   service (§4: 免权限地狱). Older versions used the HKCU `Run` value;
//!   it is migrated away and still recognised.
//! - Awake: `SetThreadExecutionState(ES_SYSTEM_REQUIRED|ES_CONTINUOUS)`
//!   held RAII-style; drop restores `ES_CONTINUOUS`.
//!
//! Compile-checked cross-platform in CI (`cargo check --target
//! x86_64-pc-windows-msvc`); live smoke runs on the H-09 Windows box.

use std::path::{Path, PathBuf};

use crate::{AwakeGuard, HostingAdapter, PlatformAdapter, PlatformError, Result, ServiceMode};

/// 老版本（#957 之前）daemon 的登记方式：HKCU Run 值。现在只读它、删它（迁移），不再写。
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "P-Pass";

/// DESK-72 (#1012)：桌面壳的登录项，同一个 Run 键下的另一个值。
/// 不能叫 `P-Pass`：那是上面 daemon 的老登记，迁移逻辑见到就删。
/// 卸载时由 NSIS 钩子（`NSIS_HOOK_PREUNINSTALL`）删掉。
const SHELL_RUN_VALUE: &str = "P-Pass Desktop";

/// Run 值里的命令行：路径带引号（安装目录可能含空格）。
fn shell_run_command(exec: &Path) -> String {
    format!("\"{}\"", exec.display())
}

/// 幂等写 `HKCU\<key>` 下的字符串值：内容一致就不写。
/// 只碰这一个值——用户在「启动应用」里的开关记在 `StartupApproved\Run`，不动它。
fn write_run_value(key: &str, name: &str, command: &str) -> Result<()> {
    use winreg::enums::{HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE};
    let (run, _) = winreg::RegKey::predef(HKEY_CURRENT_USER)
        .create_subkey_with_flags(key, KEY_QUERY_VALUE | KEY_SET_VALUE)
        .map_err(io_err("open HKCU Run key"))?;
    if run.get_value::<String, _>(name).ok().as_deref() == Some(command) {
        return Ok(());
    }
    run.set_value(name, &command)
        .map_err(io_err("write Run value"))
}

/// DESK-60 (#877)：NSIS（Tauri 模板，currentUser 模式）的卸载登记。
/// `InstallLocation` 是带引号的安装目录。
const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass";

/// 带引号或不带引号的命令行 → 可执行路径（Run 值、`InstallLocation` 都是这种
/// 写法）。引号后面跟的参数不算路径。空值 = 读不出。
fn exec_from_run_value(value: &str) -> Option<PathBuf> {
    let v = value.trim();
    let path = match v.strip_prefix('"') {
        Some(rest) => rest.split('"').next().unwrap_or(""),
        None => v,
    };
    (!path.is_empty()).then(|| PathBuf::from(path))
}

fn installed_location() -> Option<PathBuf> {
    let key = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
        .open_subkey(UNINSTALL_KEY)
        .ok()?;
    let raw: String = key.get_value("InstallLocation").ok()?;
    exec_from_run_value(&raw)
}

/// `exec` 是否就在 `install_dir` 里（直接子文件）。Windows 路径不分大小写，
/// 结尾的分隔符不算数。
fn is_in_install_dir(exec: &Path, install_dir: &Path) -> bool {
    fn norm(p: &Path) -> String {
        p.display()
            .to_string()
            .replace('/', "\\")
            .trim_end_matches('\\')
            .to_lowercase()
    }
    match exec.parent() {
        Some(parent) => !norm(install_dir).is_empty() && norm(parent) == norm(install_dir),
        None => false,
    }
}

// ── DESK-65 (#957)：常驻服务交给任务计划程序 ───────────────────────────
//
// Run 值只管「登录时拉一次」：崩溃后没人拉、不能按需立即拉起，停止也只是删一个
// 值。这些能力于是散落在桌面壳的补位逻辑里，与 macOS（launchd 一份登记全包）
// 走两套流程。每用户计划任务与 launchd 一一对应，壳从此只依赖
// `PlatformAdapter` 的常驻服务接口（依赖倒置），不再区分平台。

/// 计划任务名（任务计划程序库的根目录下，用户能在「任务计划程序」里看到）。
const TASK_NAME: &str = "P-Pass";

/// 任务定义。
///
/// - 登录触发 = launchd 的 `RunAtLoad`。
/// - 每分钟触发 + `IgnoreNew` = `KeepAlive`：任务计划自带的「失败后重启」只认
///   **启动失败**，进程自己异常退出不算，靠不住；看门狗式的重复触发是标准
///   做法，已在跑就跳过，不会多拉。实测（#957）：杀掉后下一个整分钟拉回。
/// - 优先级 5（正常）：计划任务默认 7 = 低于正常，传输和转码会被拖慢。
/// - 电池供电照常跑、没有执行时限：这是常驻服务，不是一次性任务。
fn task_xml(exec: &Path, user: &str) -> String {
    let exec = xml_escape(&exec.display().to_string());
    let user = xml_escape(user);
    format!(
        r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>P-Pass background service: starts at logon and is restarted within a minute if it exits. Stopping the service in P-Pass removes this task.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>{user}</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <Enabled>true</Enabled>
      <StartBoundary>2000-01-01T00:00:00</StartBoundary>
      <Repetition>
        <Interval>PT1M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{user}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{exec}</Command>
    </Exec>
  </Actions>
</Task>"#
    )
}

/// 任务的主体：`域\用户名`（登录触发和运行身份都是它）。
fn current_user() -> Result<String> {
    match (std::env::var("USERDOMAIN"), std::env::var("USERNAME")) {
        (Ok(domain), Ok(user)) if !domain.is_empty() && !user.is_empty() => {
            Ok(format!("{domain}\\{user}"))
        }
        _ => Err(PlatformError::Failed {
            action: "register scheduled task",
            detail: "读不到当前用户（USERDOMAIN / USERNAME 为空）".into(),
        }),
    }
}

/// 在一条专属线程上跑任务计划程序的 COM 调用。
///
/// 桌面壳的命令跑在任意线程上，有的线程已经初始化成 STA（WebView 所在的
/// 主线程）。单开一条线程、自己初始化成 MTA，套间与调用方无关；所有 COM
/// 对象都在闭包里用完、在反初始化之前释放。
fn with_task_folder<T: Send + 'static>(
    action: &'static str,
    f: impl FnOnce(&windows::Win32::System::TaskScheduler::ITaskFolder) -> windows::core::Result<T>
        + Send
        + 'static,
) -> Result<T> {
    use windows::core::BSTR;
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_MULTITHREADED,
    };
    use windows::Win32::System::TaskScheduler::{ITaskService, TaskScheduler};
    use windows::Win32::System::Variant::VARIANT;

    let run = move || -> windows::core::Result<T> {
        // SAFETY: 本线程是自己起的，只初始化这一次，返回前配对反初始化。
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.ok()?;
        let result = (|| {
            // SAFETY: 标准的 COM 激活与调用；参数都是本栈上的有效值。
            unsafe {
                let service: ITaskService =
                    CoCreateInstance(&TaskScheduler, None, CLSCTX_INPROC_SERVER)?;
                let local = VARIANT::default();
                service.Connect(&local, &local, &local, &local)?;
                let folder = service.GetFolder(&BSTR::from("\\"))?;
                f(&folder)
            }
        })();
        // SAFETY: 与上面的 CoInitializeEx 配对；COM 对象已在上面的闭包里释放。
        unsafe { CoUninitialize() };
        result
    };
    std::thread::Builder::new()
        .name("ppf-task".into())
        .spawn(run)
        .map_err(io_err(action))?
        .join()
        .map_err(|_| PlatformError::Failed {
            action,
            detail: "任务计划线程异常退出".into(),
        })?
        .map_err(|e| PlatformError::Failed {
            action,
            detail: e.to_string(),
        })
}

/// 找不到任务（`HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)`）不是错误，是「没登记」。
fn get_task(
    folder: &windows::Win32::System::TaskScheduler::ITaskFolder,
) -> windows::core::Result<Option<windows::Win32::System::TaskScheduler::IRegisteredTask>> {
    // SAFETY: folder 是有效的 COM 接口；BSTR 在调用期间有效。
    match unsafe { folder.GetTask(&windows::core::BSTR::from(TASK_NAME)) } {
        Ok(task) => Ok(Some(task)),
        Err(e) if e.code() == windows::core::HRESULT::from_win32(2) => Ok(None),
        Err(e) => Err(e),
    }
}

/// 任务正在跑的那个实例的进程号（`None` = 没在跑）。执行类任务的「引擎进程」
/// 就是被拉起的程序本身。
fn task_running_pid(
    task: &windows::Win32::System::TaskScheduler::IRegisteredTask,
) -> windows::core::Result<Option<u32>> {
    use windows::Win32::System::Variant::VARIANT;
    // SAFETY: task 是有效的 COM 接口；集合下标从 1 开始。
    unsafe {
        let instances = task.GetInstances(0)?;
        if instances.Count()? < 1 {
            return Ok(None);
        }
        let pid = instances.get_Item(&VARIANT::from(1i32))?.EnginePID()?;
        Ok((pid != 0).then_some(pid))
    }
}

/// 结束任务正在跑的实例（= `launchctl bootout` / `kickstart -k` 里的「杀」）。
/// 删除或禁用任务都**不会**结束已在跑的实例（#957 实测），所以要单独结束。
fn stop_task_instances(
    task: &windows::Win32::System::TaskScheduler::IRegisteredTask,
) -> windows::core::Result<()> {
    // SCHED_E_TASK_NOT_RUNNING：本来就没在跑。
    const NOT_RUNNING: windows::core::HRESULT = windows::core::HRESULT(0x8004_130B_u32 as i32);
    // SAFETY: task 是有效的 COM 接口。
    match unsafe { task.Stop(0) } {
        Err(e) if e.code() != NOT_RUNNING => return Err(e),
        _ => {}
    }
    // 结束是异步的：等实例真的没了（最长 5s），调用方紧接着要拉新的或删任务。
    for _ in 0..50 {
        if task_running_pid(task)?.is_none() {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    Ok(())
}

/// 老版本留下的 Run 值（原始字符串）。没有 Run 键或没有这个值 = `None`。
fn legacy_run_value() -> Result<Option<String>> {
    let key = match winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER).open_subkey(RUN_KEY) {
        Ok(k) => k,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(io_err("open HKCU Run key")(e)),
    };
    match key.get_value::<String, _>(RUN_VALUE) {
        Ok(v) => Ok(Some(v)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        // 值在、但不是字符串（被别的工具写坏）——仍然是一条要清掉的老登记。
        Err(_) => Ok(Some(String::new())),
    }
}

/// 删掉老版本的 Run 值。留着它，下次登录会在任务之外再拉一个实例。
fn delete_legacy_run_value() -> Result<()> {
    let key = match winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
        .open_subkey_with_flags(RUN_KEY, winreg::enums::KEY_SET_VALUE)
    {
        Ok(k) => k,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(io_err("open HKCU Run key")(e)),
    };
    match key.delete_value(RUN_VALUE) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(io_err("delete Run value")(e)),
    }
}

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

/// #1043：`SHGetKnownFolderPath`。读不到（极少见：漫游配置坏了、服务账户）
/// 返回 `None`，调用方自己决定怎么兜底，这里不编路径。
fn known_folder(id: &windows::core::GUID) -> Option<PathBuf> {
    use windows::Win32::System::Com::CoTaskMemFree;
    use windows::Win32::UI::Shell::{SHGetKnownFolderPath, KF_FLAG_DEFAULT};
    // SAFETY: id 指向 'static GUID；htoken = None 表示当前用户。成功时返回的
    // 缓冲区归调用方，读完立刻用 CoTaskMemFree 释放。
    let raw = unsafe { SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None) }.ok()?;
    // SAFETY: raw 是系统刚分配的、以 NUL 结尾的 UTF-16 串。
    let text = unsafe { raw.to_string() };
    // SAFETY: raw 由 SHGetKnownFolderPath 分配，只释放这一次。
    unsafe { CoTaskMemFree(Some(raw.0 as *const core::ffi::c_void)) };
    text.ok().filter(|t| !t.is_empty()).map(PathBuf::from)
}

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

/// IDX-08 (#1010): Windows-only file-name policy for new ingest paths.
///
/// Input is the last path component after core's traversal cleanup (no `/` or
/// `\` should remain, but they are replaced anyway). Rules, per Microsoft's
/// naming rules:
/// - `< > : " / \ | ? *` and ASCII control characters 0x00-0x1F → `_`;
/// - trailing `.` and spaces are not legal on Windows → strip them;
/// - empty / `.` / `..` → `unnamed.bin` (core normally handles these first);
/// - reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`,
///   `LPT1`-`LPT9`, case-insensitive, with or without an extension) get a `_`
///   prefix. Case is preserved, so `con.jpg` → `_con.jpg`, not `_CON.jpg`.
///
/// Deliberately **no length truncation**: the 255-character limit is a separate
/// concern and would need its own rule for extension-preserving truncation.
/// No case folding: Windows is case-insensitive, but folding would change
/// readable names and is not needed for this bug.
fn sanitize_windows_file_name(name: &str) -> String {
    let mut cleaned = String::with_capacity(name.len());
    for c in name.chars() {
        let illegal =
            matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || (c as u32) < 0x20;
        cleaned.push(if illegal { '_' } else { c });
    }
    // Windows trims trailing dots and spaces; a name like `photo.jpg.` is not
    // the same file as `photo.jpg`, and `create_new` rejects it.
    while cleaned.ends_with('.') || cleaned.ends_with(' ') {
        cleaned.pop();
    }
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        return "unnamed.bin".into();
    }
    // Reserved-name matching is on the base name before the first dot, and
    // Windows ignores trailing spaces/dots in that base. `CON.jpg` and
    // `CON.tar.gz` are both reserved.
    let base = cleaned
        .split('.')
        .next()
        .unwrap_or_default()
        .trim_end_matches([' ', '.']);
    if is_windows_reserved_name(base) {
        cleaned.insert(0, '_');
    }
    cleaned
}

fn is_windows_reserved_name(base: &str) -> bool {
    let upper = base.to_ascii_uppercase();
    if matches!(upper.as_str(), "CON" | "PRN" | "AUX" | "NUL") {
        return true;
    }
    // COM1-COM9 / LPT1-LPT9. COM10 is legal; COM0 is not a reserved name.
    let bytes = upper.as_bytes();
    bytes.len() == 4
        && (upper.starts_with("COM") || upper.starts_with("LPT"))
        && bytes[3].is_ascii_digit()
        && bytes[3] != b'0'
}

impl PlatformAdapter for WindowsAdapter {
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

    // ── QA-09 迁移（#211）桌面壳批次 ───────────────────────────────
    fn platform_name(&self) -> &'static str {
        "windows"
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

    /// #1043（B10）：Known Folder `FOLDERID_Profile`（不读 `USERPROFILE`）。
    fn home_dir(&self) -> Option<PathBuf> {
        known_folder(&windows::Win32::UI::Shell::FOLDERID_Profile)
    }

    /// #1043（B10）：Known Folder `FOLDERID_Pictures`——用户在资源管理器里把
    /// 「图片」搬到 D 盘的话，这里给的就是 D 盘那个，而不是 `%USERPROFILE%\Pictures`。
    fn pictures_dir(&self) -> Option<PathBuf> {
        known_folder(&windows::Win32::UI::Shell::FOLDERID_Pictures)
    }

    /// IDX-08 (#1010)：Windows 的非法字符 / 保留名 / 结尾点空格规则。
    fn ingest_file_name_sanitizer(&self) -> Option<fn(&str) -> String> {
        Some(sanitize_windows_file_name)
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
    /// DAE-11 (#804)：`GetSystemPowerStatus` 的 `ACLineStatus`。不需要权限、
    /// 不起进程、与系统语言无关。判据见 [`ac_line_verdict`]。
    fn on_external_power(&self) -> Option<bool> {
        use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
        let mut status: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
        // SAFETY: status 是本栈上零初始化的结构体，调用期间有效。
        if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
            return None;
        }
        ac_line_verdict(status.ACLineStatus)
    }

    /// DAE-11 (#804)：`PowerSettingRegisterNotification(GUID_ACDC_POWER_SOURCE)`
    /// 回调式订阅——系统在登记时先推一次当前状态，之后每次插拔再推，**没有轮询**。
    /// 用 `DEVICE_NOTIFY_CALLBACK` 而不是窗口消息：daemon 没有窗口。
    ///
    /// 回调存在进程级静态槽里，而不是把指针塞进 Context：退订之后系统还有没有
    /// 在途回调，文档没担保；静态槽 + 锁保证退订后的迟到回调只会看到空槽，
    /// 不会碰到已释放的内存。代价是同一时刻只能有一个订阅者（daemon 只要一个），
    /// 第二个直接返回 `None`。
    fn watch_external_power(
        &self,
        on_change: Box<dyn Fn(Option<bool>) + Send + Sync>,
    ) -> Option<crate::PowerWatch> {
        use windows_sys::Win32::System::Power::{
            PowerSettingRegisterNotification, DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS,
        };
        use windows_sys::Win32::UI::WindowsAndMessaging::DEVICE_NOTIFY_CALLBACK;

        {
            let mut slot = POWER_CALLBACK
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if slot.is_some() {
                return None;
            }
            // 先放回调再登记：登记那一刻系统就会推第一次。
            *slot = Some(on_change);
        }
        // 放在堆上、随 guard 活着：文档没说系统会不会在登记后继续引用它。
        let params = Box::new(DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
            Callback: Some(power_source_changed),
            Context: std::ptr::null_mut(),
        });
        let mut handle: *mut std::ffi::c_void = std::ptr::null_mut();
        // SAFETY: GUID 是 'static 常量；params 在 guard 存活期间有效；handle 是
        // 本栈上的出参。
        let err = unsafe {
            PowerSettingRegisterNotification(
                &GUID_ACDC_POWER_SOURCE,
                DEVICE_NOTIFY_CALLBACK,
                std::ptr::from_ref(&*params).cast_mut().cast(),
                &mut handle,
            )
        };
        if err != 0 {
            *POWER_CALLBACK
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
            return None;
        }
        Some(crate::PowerWatch::new(PowerNotifyGuard {
            handle,
            _params: params,
        }))
    }

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

    /// DESK-58 (#875)：与 `daemon.log` 同目录、分开放——`daemon.log` 是
    /// tracing 的完整运行日志，这份只装 tracing 接不住的东西（文件日志之前的
    /// 报错、`main` 返回的 `Err`、panic），尾行就是「为什么没起来」。
    fn startup_stderr_file(&self, data_dir: &Path) -> Option<PathBuf> {
        Some(data_dir.join("logs").join("daemon.err"))
    }

    /// DESK-58 (#875)：Run 键（登录时 explorer 拉起）和壳的一次性 spawn 都把
    /// stderr 给成空——前者是 GUI 子系统进程没有句柄，后者是 `Stdio::null()`
    /// 的 `NUL`。两条路都由 daemon 自己接住，不靠各个拉起方分别重定向
    /// （拉起方有好几个，登录那条我们根本插不上手）。
    ///
    /// Rust 的 `eprintln!` 与 panic 输出每次写都现取 `GetStdHandle`，所以
    /// `SetStdHandle` 之后的所有 stderr 都进文件。
    ///
    /// 先截断、再以**追加**方式持有：同时有第二个实例起来（自愈与登录撞车）
    /// 把文件截断时，本进程之后的写入落在新文件尾，而不是旧偏移处留一段空洞。
    fn capture_unattached_stderr(&self, data_dir: &Path) -> crate::Applied {
        use std::os::windows::io::{FromRawHandle as _, IntoRawHandle as _};
        use windows_sys::Win32::System::Console::{SetStdHandle, STD_ERROR_HANDLE};

        if !stderr_needs_capture(classify_own_stderr()) {
            return crate::Applied::NotApplicable;
        }
        let Some(path) = self.startup_stderr_file(data_dir) else {
            return crate::Applied::NotApplicable;
        };
        if let Some(dir) = path.parent() {
            if std::fs::create_dir_all(dir).is_err() {
                return crate::Applied::Unsupported;
            }
        }
        if std::fs::File::create(&path).is_err() {
            return crate::Applied::Unsupported;
        }
        let Ok(file) = std::fs::OpenOptions::new().append(true).open(&path) else {
            return crate::Applied::Unsupported;
        };
        let handle = file.into_raw_handle();
        // SAFETY: handle 是刚打开、所有权已交出的文件句柄；交给 SetStdHandle
        // 后由进程标准错误持有，进程退出时由系统回收。
        if unsafe { SetStdHandle(STD_ERROR_HANDLE, handle as _) } == 0 {
            // SAFETY: 没交出去，收回所有权关掉。
            drop(unsafe { std::fs::File::from_raw_handle(handle) });
            return crate::Applied::Unsupported;
        }
        crate::Applied::Done
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

impl HostingAdapter for WindowsAdapter {
    /// DESK-65 (#957)：登记计划任务并立刻运行它（= `launchctl bootstrap` +
    /// `RunAtLoad`）。向导紧接着就要连上 daemon，所以登记完就跑；已经在跑时
    /// `IgnoreNew` 让这次运行什么都不多拉。顺手删掉老版本的 Run 值（迁移）。
    fn install_autostart(&self, exec: &Path) -> Result<()> {
        use windows::core::BSTR;
        use windows::Win32::System::TaskScheduler::{
            TASK_CREATE_OR_UPDATE, TASK_LOGON_INTERACTIVE_TOKEN,
        };
        use windows::Win32::System::Variant::VARIANT;

        let xml = task_xml(exec, &current_user()?);
        with_task_folder("register scheduled task", move |folder| {
            let none = VARIANT::default();
            // SAFETY: folder 是有效的 COM 接口；参数都在调用期间有效。
            unsafe {
                let task = folder.RegisterTask(
                    &BSTR::from(TASK_NAME),
                    &BSTR::from(xml.as_str()),
                    TASK_CREATE_OR_UPDATE.0,
                    &none,
                    &none,
                    TASK_LOGON_INTERACTIVE_TOKEN,
                    &none,
                )?;
                task.Run(&none)?;
            }
            Ok(())
        })?;
        delete_legacy_run_value()
    }

    /// 计划任务在，或者老版本的 Run 值还在（还没迁移）。
    fn autostart_installed(&self) -> Result<bool> {
        let task = with_task_folder("query scheduled task", |folder| {
            Ok(get_task(folder)?.is_some())
        })?;
        Ok(task || legacy_run_value()?.is_some())
    }

    /// 计划任务的执行路径。老版本的 Run 值一律算「读不出」：对账因此走
    /// `Repaired` ⇒ `install_autostart` 换成计划任务并删掉 Run 值（迁移只发生
    /// 在壳的对账里，那里先判了用户有没有停过服务）。
    fn autostart_registration(&self) -> Result<crate::AutostartRegistration> {
        use windows::core::{Interface as _, BSTR};
        use windows::Win32::System::TaskScheduler::IExecAction;

        let task = with_task_folder("read scheduled task", |folder| {
            let Some(task) = get_task(folder)? else {
                return Ok(None);
            };
            // SAFETY: task 是有效的 COM 接口；动作集合下标从 1 开始。
            let path = unsafe {
                task.Definition()?
                    .Actions()?
                    .get_Item(1)
                    .and_then(|a| a.cast::<IExecAction>())
                    .and_then(|exec| {
                        let mut p = BSTR::new();
                        exec.Path(&mut p).map(|()| p.to_string())
                    })
                    .ok()
            };
            Ok(Some(path))
        })?;
        Ok(match task {
            Some(Some(p)) if !p.trim().is_empty() => {
                crate::AutostartRegistration::At(PathBuf::from(p.trim()))
            }
            Some(_) => crate::AutostartRegistration::Unreadable,
            None if legacy_run_value()?.is_some() => crate::AutostartRegistration::Unreadable,
            None => crate::AutostartRegistration::Absent,
        })
    }

    /// DESK-60 (#877)：对账闸门——只认**安装程序登记的安装目录**里的 daemon。
    ///
    /// 依据是 NSIS 写的 `HKCU\…\Uninstall\P-Pass` 的 `InstallLocation`，而不是
    /// 硬编码 `%LOCALAPPDATA%\P-Pass`：用户在安装向导里改过目录也认得出；
    /// 解压到「下载」目录直接跑的、开发构建 `target\` 里的，都不在那里，
    /// 照旧拒绝（#604 的同一条风险：把登记改指向一次性路径）。
    fn autostart_reconcile_allowed(&self, expected: &Path) -> bool {
        // DESK-68 (#996)：与「能不能运行」同一条判据，规则只写一处。
        self.is_install_location(expected)
    }

    /// DESK-68 (#996)：只认 NSIS 登记的安装目录里的那份（判据同上面的对账闸门）。
    /// 注册表里没有安装记录 = 没装过 ⇒ 不是。
    fn is_install_location(&self, exe: &Path) -> bool {
        installed_location().is_some_and(|dir| is_in_install_dir(exe, &dir))
    }

    fn install_location_hint_key(&self) -> &'static str {
        "ui.install_location_required_win"
    }

    /// DESK-72 (#1012)：HKCU `Run` 值——Windows 上 GUI 程序登录自启的标准做法。
    /// 免管理员；出现在任务管理器「启动应用」里，用户可以自己关；没有崩溃复活，
    /// 托盘「退出」就是真退出（与 macOS 壳的 LaunchAgent 不挂 KeepAlive 同一语义）。
    fn register_shell_login_item(&self, exec: &Path) -> Result<()> {
        if !self.is_install_location(exec) {
            return Err(PlatformError::Failed {
                action: "register_shell_login_item outside the install location",
                detail: exec.display().to_string(),
            });
        }
        write_run_value(RUN_KEY, SHELL_RUN_VALUE, &shell_run_command(exec))
    }

    /// DESK-60 (#877)：卸载程序删掉登记（现在是计划任务，见 NSIS 钩子），配置
    /// 和照片库却保留——重装后「服务该在、登记没了」是这个平台上的常规路径，
    /// 壳要补登记。macOS 卸载就是拖进废纸篓，plist 不会被删，没有这条路径。
    fn autostart_restore_when_missing(&self) -> bool {
        true
    }

    /// DESK-65 (#957)：结束任务正在跑的实例，再删任务（= `launchctl bootout`），
    /// 老版本的 Run 值一并删掉。之后登录不再拉起、看门狗也不再拉。
    fn uninstall_autostart(&self) -> Result<()> {
        use windows::core::BSTR;
        with_task_folder("delete scheduled task", |folder| {
            let Some(task) = get_task(folder)? else {
                return Ok(());
            };
            stop_task_instances(&task)?;
            // SAFETY: folder 是有效的 COM 接口。
            unsafe { folder.DeleteTask(&BSTR::from(TASK_NAME), 0) }
        })?;
        delete_legacy_run_value()
    }

    fn service_mode(&self) -> ServiceMode {
        ServiceMode::ScheduledTask
    }

    /// 任务正在跑的实例的进程号。
    fn resident_daemon_pid(&self) -> Option<u32> {
        with_task_folder("query scheduled task", |folder| match get_task(folder)? {
            Some(task) => task_running_pid(&task),
            None => Ok(None),
        })
        .ok()
        .flatten()
    }

    /// DESK-65 (#957)：= `launchctl kickstart [-k]`。`kill_running` 时先结束在跑
    /// 的实例再运行任务（换版本）；否则在跑就不动（自愈）。
    fn restart_resident_daemon(&self, kill_running: bool) -> Result<crate::ResidentRestart> {
        use windows::Win32::Foundation::{E_FAIL, VARIANT_TRUE};
        use windows::Win32::System::Variant::VARIANT;

        with_task_folder("run scheduled task", move |folder| {
            let Some(task) = get_task(folder)? else {
                return Ok(crate::ResidentRestart::NotRegistered);
            };
            if kill_running {
                stop_task_instances(&task)?;
            } else if let Some(pid) = task_running_pid(&task)? {
                return Ok(crate::ResidentRestart::AlreadyRunning { pid });
            }
            // SAFETY: task 是有效的 COM 接口。
            unsafe {
                // NSIS 安装前会禁用任务（防止看门狗在复制文件时把服务拉起），
                // 安装后的钩子再启用；那一步没跑到时由这里补上。
                task.SetEnabled(VARIANT_TRUE)?;
                task.Run(&VARIANT::default())?;
            }
            for _ in 0..50 {
                if let Some(pid) = task_running_pid(&task)? {
                    return Ok(crate::ResidentRestart::Started { pid });
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            Err(windows::core::Error::new(
                E_FAIL,
                "计划任务已运行，但 5 秒内没有出现在跑的实例",
            ))
        })
    }

    /// Windows 的可执行文件带 `.exe`。与 [`crate::DAEMON_EXECUTABLE_STEM`]
    /// 的关系有单测钉着（`executable_name_is_the_stem_plus_exe`）——写成
    /// 字面量是因为 `const` 里没法做字符串拼接。
    fn daemon_executable_name(&self) -> &'static str {
        "ppf-daemon.exe"
    }

    /// DESK-52 (#787)：直接调系统 API 结束进程，**不再拉起 `taskkill.exe`**。
    /// taskkill 是 console 子系统程序，从 GUI 子系统的桌面壳里拉起它会闪黑窗
    /// （DESK-19 #168 那一类）；不启动外部程序，这一类问题就不存在。实现与
    /// 理由见 [`kill_processes_named`]。
    fn kill_daemon_process(&self) -> Result<crate::KillOutcome> {
        kill_processes_named(self.daemon_executable_name())
    }
}

/// Spawn `exec` detached, with no console window (equivalent to macOS's
/// `launchctl bootstrap` giving the daemon an immediate first run instead
/// of waiting for the next login). CREATE_NO_WINDOW keeps a bare console
/// app from flashing a black window when spawned from the desktop shell.
/// DESK-58 (#875)：本进程 stderr 此刻接在什么上。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StderrTarget {
    /// 没有句柄（GUI 子系统进程被 Run 键拉起时就是这样）。
    Missing,
    /// 字符设备但不是控制台——实际就是 `NUL`（`Stdio::null()`）。
    NullDevice,
    Console,
    Pipe,
    Disk,
    Unknown,
}

/// 只有「没人接」才改接。控制台 / 管道 / 磁盘文件都是有人刻意接的，
/// 改掉它们等于把终端前台或测试框架的输出偷走。
fn stderr_needs_capture(target: StderrTarget) -> bool {
    matches!(target, StderrTarget::Missing | StderrTarget::NullDevice)
}

fn classify_own_stderr() -> StderrTarget {
    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
    use windows_sys::Win32::Storage::FileSystem::{
        GetFileType, FILE_TYPE_CHAR, FILE_TYPE_DISK, FILE_TYPE_PIPE,
    };
    use windows_sys::Win32::System::Console::{GetConsoleMode, GetStdHandle, STD_ERROR_HANDLE};

    // SAFETY: 只查询，不接管句柄所有权。
    let handle = unsafe { GetStdHandle(STD_ERROR_HANDLE) };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return StderrTarget::Missing;
    }
    // SAFETY: 同上。
    match unsafe { GetFileType(handle) } {
        FILE_TYPE_DISK => StderrTarget::Disk,
        FILE_TYPE_PIPE => StderrTarget::Pipe,
        FILE_TYPE_CHAR => {
            let mut mode = 0u32;
            // SAFETY: 同上；mode 是本地出参。控制台句柄才会成功。
            if unsafe { GetConsoleMode(handle, &mut mode) } != 0 {
                StderrTarget::Console
            } else {
                StderrTarget::NullDevice
            }
        }
        _ => StderrTarget::Unknown,
    }
}

/// DAE-11 (#804)：`GUID_ACDC_POWER_SOURCE`（winnt.h），只订阅这一项，
/// 免得为一个常量多开一个 windows-sys feature。
const GUID_ACDC_POWER_SOURCE: windows_sys::core::GUID =
    windows_sys::core::GUID::from_u128(0x5d3e9a59_e9d5_4b00_a6bd_ff34ff516548);

type PowerCallback = Box<dyn Fn(Option<bool>) + Send + Sync>;

/// [`WindowsAdapter::watch_external_power`] 的回调槽（为什么是静态的见那里）。
static POWER_CALLBACK: std::sync::Mutex<Option<PowerCallback>> = std::sync::Mutex::new(None);

/// 退订句柄：先退订，再清空回调槽。
struct PowerNotifyGuard {
    /// 登记函数给出的是指针，退订函数收的是 `isize`（windows-sys 的两处声明
    /// 不一致，同一个值），退订时再转。
    handle: *mut std::ffi::c_void,
    _params: Box<windows_sys::Win32::System::Power::DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS>,
}

// SAFETY: handle 只是系统给的不透明句柄，退订可以在任意线程上做；params 只在
// 登记时被系统读取，本进程不再访问。
unsafe impl Send for PowerNotifyGuard {}

impl Drop for PowerNotifyGuard {
    fn drop(&mut self) {
        // SAFETY: handle 来自成功的 PowerSettingRegisterNotification，只退订一次。
        unsafe {
            windows_sys::Win32::System::Power::PowerSettingUnregisterNotification(
                self.handle as windows_sys::Win32::System::Power::HPOWERNOTIFY,
            );
        }
        *POWER_CALLBACK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    }
}

/// 系统线程上的回调：解析 `POWERBROADCAST_SETTING`，交给登记的闭包。
unsafe extern "system" fn power_source_changed(
    _context: *const std::ffi::c_void,
    kind: u32,
    setting: *const std::ffi::c_void,
) -> u32 {
    use windows_sys::Win32::System::Power::POWERBROADCAST_SETTING;
    use windows_sys::Win32::UI::WindowsAndMessaging::PBT_POWERSETTINGCHANGE;
    if kind != PBT_POWERSETTINGCHANGE || setting.is_null() {
        return 0;
    }
    let setting = setting.cast::<POWERBROADCAST_SETTING>();
    // SAFETY: 系统保证 setting 指向一个完整的 POWERBROADCAST_SETTING，Data 后面
    // 跟着 DataLength 个字节；只订阅了 ACDC 一项，它的数据是一个 DWORD。
    let raw = unsafe {
        if (*setting).DataLength < 4 {
            return 0;
        }
        std::ptr::read_unaligned(std::ptr::addr_of!((*setting).Data).cast::<u32>())
    };
    let verdict = acdc_verdict(raw);
    let slot = POWER_CALLBACK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(f) = slot.as_ref() {
        // panic 不能穿过 extern "system" 边界（会直接 abort 整个 daemon）。
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(verdict)));
    }
    0
}

/// DAE-11 (#804)：`GUID_ACDC_POWER_SOURCE` 推来的值 → 是否插电。
///
/// 文档值（`SYSTEM_POWER_CONDITION`）：0 = PoAc 插电，1 = PoDc 电池，
/// 2 = PoHot 短时电源（UPS 之类）。UPS 顶着的时候按「没插电」算——要省着用。
/// 其余值不知道。
pub fn acdc_verdict(power_condition: u32) -> Option<bool> {
    match power_condition {
        0 => Some(true),
        1 | 2 => Some(false),
        _ => None,
    }
}

/// DAE-11 (#804)：`SYSTEM_POWER_STATUS.ACLineStatus` → 是否插电。
///
/// 文档值：0 = 用电池，1 = 接着外部电源，255 = 未知。没有电池的台式机报 1。
/// 文档外的值一律当未知——**不知道就说不知道**，交给调用方定策略。
/// 纯函数：真实读数在 CI 的虚拟机上不可控，判据本身可以在任何地方锁住。
pub fn ac_line_verdict(ac_line_status: u8) -> Option<bool> {
    match ac_line_status {
        0 => Some(false),
        1 => Some(true),
        _ => None,
    }
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

/// #778：给 `dir` 加一条**拒绝当前用户新建文件 / 子文件夹**的 ACE，返回原来的
/// DACL（按字节拷出），供 [`restore_dacl`] 还原。只给 `test_support` 用。
///
/// 为什么是「拒绝当前用户」：Windows 先按顺序看拒绝 ACE，命中就拒绝，后面的允许
/// （含 Administrators 组、所有者）都救不回来。
///
/// ⚠️ **新建子文件夹可能拦不住**（PR #822 的 CI 实测，与 PR #776 的 icacls 现象
/// 一致）：`CreateDirectoryW` 内部以备份意图打开，持有备份 / 还原特权的进程（提权
/// 的 CI runner）建文件夹时绕过 ACL；建文件不带这个意图，照样被拦。所以这条 ACE
/// **可继承**（`SUB_CONTAINERS_AND_OBJECTS_INHERIT`）：就算子文件夹建成了，它也
/// 继承这条拒绝，里面照样落不下文件——这正是「照片落不进来」的含义，也贴近现实里
/// 权限向下继承的不可写文件夹。判据见 `test_support::nothing_can_land_in`。
#[cfg(feature = "test-support")]
pub(crate) fn deny_entry_creation(dir: &Path) -> std::io::Result<Vec<u8>> {
    use std::os::windows::ffi::OsStrExt as _;
    use windows_sys::Win32::Foundation::{LocalFree, ERROR_SUCCESS};
    use windows_sys::Win32::Security::Authorization::{
        GetNamedSecurityInfoW, SetEntriesInAclW, SetNamedSecurityInfoW, DENY_ACCESS,
        EXPLICIT_ACCESS_W, NO_MULTIPLE_TRUSTEE, SE_FILE_OBJECT, TRUSTEE_IS_SID, TRUSTEE_IS_USER,
        TRUSTEE_W,
    };
    use windows_sys::Win32::Security::{
        ACL, DACL_SECURITY_INFORMATION, SUB_CONTAINERS_AND_OBJECTS_INHERIT,
    };
    use windows_sys::Win32::Storage::FileSystem::{FILE_ADD_FILE, FILE_ADD_SUBDIRECTORY};

    let os = |rc: u32| std::io::Error::from_raw_os_error(rc as i32);
    let wide: Vec<u16> = dir
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();

    let mut old: *mut ACL = std::ptr::null_mut();
    let mut sd = std::ptr::null_mut();
    // SAFETY: wide 是 NUL 结尾的宽字符串；只要 DACL；sd 由系统 LocalAlloc，下面释放，
    // old 指向 sd 内部。
    let rc = unsafe {
        GetNamedSecurityInfoW(
            wide.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut old,
            std::ptr::null_mut(),
            &mut sd,
        )
    };
    if rc != ERROR_SUCCESS {
        return Err(os(rc));
    }
    let original = if old.is_null() {
        Vec::new()
    } else {
        // SAFETY: old 指向 sd 里一个合法 ACL，AclSize 是它的总字节数。
        let size = unsafe { (*old).AclSize } as usize;
        // SAFETY: 同上。
        unsafe { std::slice::from_raw_parts(old.cast::<u8>(), size) }.to_vec()
    };

    let mut sid = current_user_sid().map_err(std::io::Error::other)?;
    let deny = EXPLICIT_ACCESS_W {
        grfAccessPermissions: FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY,
        grfAccessMode: DENY_ACCESS,
        grfInheritance: SUB_CONTAINERS_AND_OBJECTS_INHERIT,
        Trustee: TRUSTEE_W {
            pMultipleTrustee: std::ptr::null_mut(),
            MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
            TrusteeForm: TRUSTEE_IS_SID,
            TrusteeType: TRUSTEE_IS_USER,
            ptstrName: sid.as_mut_ptr().cast(),
        },
    };
    let mut new: *mut ACL = std::ptr::null_mut();
    // SAFETY: deny 与它指向的 sid 在调用期间存活；old 仍在 sd 里有效；
    // SetEntriesInAclW 把拒绝 ACE 按规范顺序排在前面，new 由它 LocalAlloc。
    let rc = unsafe { SetEntriesInAclW(1, &deny, old, &mut new) };
    // SAFETY: sd 来自 GetNamedSecurityInfoW，old 此后不再使用。
    unsafe { LocalFree(sd) };
    if rc != ERROR_SUCCESS {
        return Err(os(rc));
    }
    // SAFETY: 只改 DACL；new 是上面建好的合法 ACL。
    let rc = unsafe {
        SetNamedSecurityInfoW(
            wide.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            new,
            std::ptr::null(),
        )
    };
    // SAFETY: new 由 SetEntriesInAclW 分配，此后不再使用。
    unsafe { LocalFree(new.cast()) };
    if rc != ERROR_SUCCESS {
        return Err(os(rc));
    }
    Ok(original)
}

/// #778：把 [`deny_entry_creation`] 返回的原 DACL 写回 `dir`。
#[cfg(feature = "test-support")]
pub(crate) fn restore_dacl(dir: &Path, original: &[u8]) {
    use std::os::windows::ffi::OsStrExt as _;
    use windows_sys::Win32::Security::Authorization::{SetNamedSecurityInfoW, SE_FILE_OBJECT};
    use windows_sys::Win32::Security::{ACL, DACL_SECURITY_INFORMATION};

    let wide: Vec<u16> = dir
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let acl: *const ACL = if original.is_empty() {
        std::ptr::null()
    } else {
        original.as_ptr().cast()
    };
    // SAFETY: original 是一个完整 ACL 的字节拷贝（或空 = 原本就没有 DACL），
    // 调用期间存活；只改 DACL。尽力而为：失败时测试的 tempdir 清理会报出来。
    unsafe {
        SetNamedSecurityInfoW(
            wide.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            acl,
            std::ptr::null(),
        )
    };
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

/// DESK-52 (#787)：TerminateProcess 给被杀进程的退出码。与 `taskkill /F`
/// 一致用 1——非零，表示「不是自己正常退出的」。
const KILLED_EXIT_CODE: u32 = 1;

/// 等被杀进程真正退出的上限。TerminateProcess 只是**发起**终止、立即返回；
/// 调用方紧接着可能就去拉新的 daemon（DESK-25 #208 的事故形状），所以必须
/// 等句柄变成 signaled 才算杀掉。
const KILL_WAIT_MS: u32 = 5_000;

/// 一个匹配进程的处置结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessKill {
    /// 进程在，已终止并确认退出。
    Terminated,
    /// 快照里有它，但动手时已经不在了（快照与 OpenProcess 之间自己退了）。
    AlreadyGone,
    /// 没杀掉：权限不足、被安全软件拦、超时未退出。
    Failed(String),
}

/// 把每个匹配进程的处置结果汇总成 [`crate::KillOutcome`]。
///
/// 抽成纯函数，因为这条判据**有过事故**：DESK-25 (#208) 之前「没杀掉」被
/// 当成杀成功，紧接着就去 spawn 第二个 daemon。所以：
/// - 一个都没有 / 全都已经不在 ⇒ `NotRunning`（正常结果，不是错误）；
/// - **任何一个没杀掉 ⇒ `Err`**，哪怕别的杀掉了——还有活着的就不能报成功；
/// - 其余 ⇒ `Killed`。
pub fn kill_verdict(results: &[ProcessKill]) -> Result<crate::KillOutcome> {
    let failures: Vec<&str> = results
        .iter()
        .filter_map(|r| match r {
            ProcessKill::Failed(why) => Some(why.as_str()),
            _ => None,
        })
        .collect();
    if !failures.is_empty() {
        return Err(PlatformError::Failed {
            action: "kill_daemon_process",
            detail: failures.join("; "),
        });
    }
    if results.contains(&ProcessKill::Terminated) {
        Ok(crate::KillOutcome::Killed)
    } else {
        Ok(crate::KillOutcome::NotRunning)
    }
}

/// DESK-52 (#787)：结束**当前登录会话里**所有映像名为 `exe_name` 的进程。
///
/// 为什么不再用 `taskkill /F /IM`：
/// 1. 它是 console 程序，从桌面壳拉起会闪黑窗——这是 #787 的症状；
/// 2. 结论要靠解析它的退出码（128 = 没找到），判据依赖一个外部程序的约定；
/// 3. `/IM` 按名字杀**整台机器**上能杀的同名进程，不分会话。
///
/// 现在：进程快照 → 按映像名（不区分大小写）匹配 → 只留与本进程同一
/// 会话（session）的 → `OpenProcess` + `TerminateProcess` → 等它真的退出。
/// 只杀本会话的，是因为 daemon 由本用户的 Run key 拉起、跑在本会话里；
/// 别的会话（快速用户切换的另一个用户）的 daemon 不归我们管。
fn kill_processes_named(exe_name: &str) -> Result<crate::KillOutcome> {
    let results: Vec<ProcessKill> = processes_named_in_this_session(exe_name)?
        .into_iter()
        .map(terminate_and_wait)
        .collect();
    kill_verdict(&results)
}

/// 本会话里映像名为 `exe_name` 的进程 pid（不含本进程自己）。
fn processes_named_in_this_session(exe_name: &str) -> Result<Vec<u32>> {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
    use windows_sys::Win32::System::Threading::GetCurrentProcessId;

    fn session_of(pid: u32) -> Option<u32> {
        let mut session = 0u32;
        // SAFETY: session 是本栈上的 u32，调用期间有效。
        (unsafe { ProcessIdToSessionId(pid, &mut session) } != 0).then_some(session)
    }

    // SAFETY: 无前置条件；失败时返回 INVALID_HANDLE_VALUE。
    let me = unsafe { GetCurrentProcessId() };
    let my_session = session_of(me).ok_or_else(|| PlatformError::Failed {
        action: "kill_daemon_process",
        // SAFETY: 紧跟失败调用之后读取本线程的错误码。
        detail: format!("读不到本进程的会话号（Win32 错误 {}）", unsafe {
            GetLastError()
        }),
    })?;

    // SAFETY: 参数是常量；返回值在下面判空并在函数末尾关闭。
    let snap = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snap == INVALID_HANDLE_VALUE {
        return Err(PlatformError::Failed {
            action: "kill_daemon_process",
            // SAFETY: 紧跟失败调用之后读取本线程的错误码。
            detail: format!("进程快照失败（Win32 错误 {}）", unsafe {
                GetLastError()
            }),
        });
    }

    let mut pids = Vec::new();
    let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
    entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
    // SAFETY: snap 是有效快照句柄；entry 已零初始化并填好 dwSize。
    let mut more = unsafe { Process32FirstW(snap, &mut entry) } != 0;
    while more {
        let len = entry
            .szExeFile
            .iter()
            .position(|&c| c == 0)
            .unwrap_or(entry.szExeFile.len());
        let name = String::from_utf16_lossy(&entry.szExeFile[..len]);
        let pid = entry.th32ProcessID;
        // 读不到会话号的（别的用户的进程常见）不是我们的，跳过。
        if pid != me && name.eq_ignore_ascii_case(exe_name) && session_of(pid) == Some(my_session) {
            pids.push(pid);
        }
        // SAFETY: 同上。
        more = unsafe { Process32NextW(snap, &mut entry) } != 0;
    }
    // SAFETY: snap 是本函数打开的有效句柄，只关一次。
    unsafe { CloseHandle(snap) };
    Ok(pids)
}

/// 终止一个进程并等它真正退出（最长 [`KILL_WAIT_MS`]）。
fn terminate_and_wait(pid: u32) -> ProcessKill {
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_INVALID_PARAMETER, WAIT_OBJECT_0,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, TerminateProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
    };

    // SAFETY: 参数都是值；返回空句柄表示失败，下面判空。
    let h = unsafe { OpenProcess(PROCESS_TERMINATE | PROCESS_SYNCHRONIZE, 0, pid) };
    if h.is_null() {
        // SAFETY: 紧跟失败调用之后读取本线程的错误码。
        let code = unsafe { GetLastError() };
        // pid 已经不存在：快照之后它自己退了。
        if code == ERROR_INVALID_PARAMETER {
            return ProcessKill::AlreadyGone;
        }
        return ProcessKill::Failed(format!("pid {pid}：打不开进程（Win32 错误 {code}）"));
    }

    // SAFETY: h 是刚打开的有效句柄，带 PROCESS_TERMINATE。
    let result = if unsafe { TerminateProcess(h, KILLED_EXIT_CODE) } == 0 {
        // SAFETY: 紧跟失败调用之后读取本线程的错误码。
        let code = unsafe { GetLastError() };
        // 正在退出的进程会让 TerminateProcess 报拒绝访问——它已经在走了，
        // 看句柄是否已 signaled 来判断。
        // SAFETY: h 有效，带 PROCESS_SYNCHRONIZE。
        if unsafe { WaitForSingleObject(h, 0) } == WAIT_OBJECT_0 {
            ProcessKill::AlreadyGone
        } else {
            ProcessKill::Failed(format!(
                "pid {pid}：TerminateProcess 失败（Win32 错误 {code}）"
            ))
        }
    // SAFETY: 同上。
    } else if unsafe { WaitForSingleObject(h, KILL_WAIT_MS) } == WAIT_OBJECT_0 {
        ProcessKill::Terminated
    } else {
        ProcessKill::Failed(format!("pid {pid}：{KILL_WAIT_MS}ms 内没有退出"))
    };
    // SAFETY: h 是本函数打开的有效句柄，只关一次。
    unsafe { CloseHandle(h) };
    result
}

/// QA-09 迁移（#211）：这组用例原来住在
/// `apps/desktop/src-tauri/src/lib.rs`，随被测函数一起搬过来。
/// 判据一个字没改，只是换了地方——搬家途中丢掉判别力是本次迁移最大的风险。
#[cfg(test)]
mod b10_known_folder_tests {
    use super::*;

    /// #1043（B10）：家目录与「图片」目录走 Known Folder，真调系统 API。
    /// 默认配置下「图片」在家目录里；只断言绝对路径 + 名字非空，不假设盘符。
    #[test]
    fn known_folders_resolve_to_absolute_paths() {
        let a = WindowsAdapter::new();
        let home = a.home_dir().expect("FOLDERID_Profile");
        let pictures = a.pictures_dir().expect("FOLDERID_Pictures");
        assert!(home.is_absolute(), "{}", home.display());
        assert!(pictures.is_absolute(), "{}", pictures.display());
        assert_ne!(home, pictures);
    }
}

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

/// DESK-52 (#787)：结束 daemon 不再拉起外部程序。判据沿用 DESK-25 (#208)
/// 的口径：没在跑不是错误，没杀掉一定是错误。
/// DESK-68 (#996)：正式安装位置判据。
#[cfg(test)]
mod desk68_install_location_tests {
    use super::*;

    /// 临时目录里的程序（解压副本的典型位置）永远不是正式安装位置——
    /// 注册表有没有安装记录都成立，所以 CI 上也能跑。
    #[test]
    fn a_copy_in_the_temp_dir_is_never_the_install_location() {
        let exe = std::env::temp_dir()
            .join("P-Pass")
            .join("p-pass-desktop.exe");
        assert!(!WindowsAdapter.is_install_location(&exe));
        assert!(
            !WindowsAdapter.autostart_reconcile_allowed(&exe),
            "两处同一判据"
        );
    }

    /// 本机实证（E3）：装过 P-Pass 的机器上，安装目录里的那份就是正式位置。
    /// CI 上没装过，所以默认忽略；本机 `cargo test -- --ignored` 跑。
    #[test]
    #[ignore = "needs a real NSIS install on this machine"]
    fn the_installed_copy_is_the_install_location() {
        let dir = installed_location().expect("本机应已装过 P-Pass");
        let exe = dir.join("p-pass-desktop.exe");
        assert!(exe.is_file(), "{}", exe.display());
        assert!(WindowsAdapter.is_install_location(&exe));
        assert!(!WindowsAdapter.is_install_location(&dir.join("sub").join("p-pass-desktop.exe")));
    }
}

/// DESK-72 (#1012)：壳的登录项。
#[cfg(test)]
mod desk72_shell_login_item_tests {
    use super::*;

    /// 带空格的安装目录：命令行带引号，读回来还是原路径。
    #[test]
    fn the_run_command_quotes_the_path_and_reads_back() {
        let exe = Path::new(r"C:\Users\A B\AppData\Local\P-Pass\p-pass-desktop.exe");
        let cmd = shell_run_command(exe);
        assert_eq!(
            cmd,
            r#""C:\Users\A B\AppData\Local\P-Pass\p-pass-desktop.exe""#
        );
        assert_eq!(exec_from_run_value(&cmd).as_deref(), Some(exe));
    }

    /// 不能和 daemon 的老登记同名：迁移逻辑见到 `P-Pass` 就删。
    #[test]
    fn the_shell_value_never_collides_with_the_legacy_daemon_value() {
        assert_ne!(SHELL_RUN_VALUE, RUN_VALUE);
    }

    /// 解压副本不登记，也不碰 Run 键。
    #[test]
    fn a_copy_outside_the_install_location_is_refused() {
        let exe = std::env::temp_dir()
            .join("P-Pass")
            .join("p-pass-desktop.exe");
        assert!(WindowsAdapter.register_shell_login_item(&exe).is_err());
    }

    /// 幂等写：第二次内容一致不报错，内容变了跟着改。写在一次性的测试键下，
    /// 不碰真实的 Run 键。
    #[test]
    fn writing_the_run_value_is_idempotent_and_follows_a_new_path() {
        let key = format!(r"Software\P-Pass-test\desk72-{}", std::process::id());
        let hkcu = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER);
        let read = || -> String {
            hkcu.open_subkey(&key)
                .unwrap()
                .get_value(SHELL_RUN_VALUE)
                .unwrap()
        };

        write_run_value(&key, SHELL_RUN_VALUE, r#""C:\a\p-pass-desktop.exe""#).unwrap();
        write_run_value(&key, SHELL_RUN_VALUE, r#""C:\a\p-pass-desktop.exe""#).unwrap();
        assert_eq!(read(), r#""C:\a\p-pass-desktop.exe""#);
        write_run_value(&key, SHELL_RUN_VALUE, r#""C:\b\p-pass-desktop.exe""#).unwrap();
        assert_eq!(read(), r#""C:\b\p-pass-desktop.exe""#);

        hkcu.delete_subkey_all(&key).unwrap();
    }
}

/// DAE-11 (#804)：插电判据。
#[cfg(test)]
mod dae11_external_power_tests {
    use super::*;

    #[test]
    fn documented_ac_line_values_map_to_plugged_unplugged_unknown() {
        assert_eq!(ac_line_verdict(1), Some(true));
        assert_eq!(ac_line_verdict(0), Some(false));
        assert_eq!(ac_line_verdict(255), None);
    }

    /// 订阅推来的电源状态：插电 / 电池 / UPS / 文档外。
    #[test]
    fn acdc_power_conditions_map_to_plugged_unplugged_unknown() {
        assert_eq!(acdc_verdict(0), Some(true), "PoAc");
        assert_eq!(acdc_verdict(1), Some(false), "PoDc");
        assert_eq!(acdc_verdict(2), Some(false), "PoHot（UPS）按没插电算");
        assert_eq!(acdc_verdict(3), None);
        assert_eq!(acdc_verdict(u32::MAX), None);
    }

    /// 真登记一次：系统登记时就推当前状态，回调必须在短时间内到达，且与
    /// `GetSystemPowerStatus` 的快照一致；第二个订阅者被拒；退订后能重新登记。
    #[test]
    fn watch_reports_current_state_and_unsubscribes_on_drop() {
        use std::sync::mpsc;
        use std::time::Duration;
        let a = WindowsAdapter;
        let (tx, rx) = mpsc::channel();
        let tx = std::sync::Mutex::new(tx);
        let watch = a
            .watch_external_power(Box::new(move |v| {
                let _ = tx.lock().unwrap().send(v);
            }))
            .expect("登记电源通知");
        let first = rx
            .recv_timeout(Duration::from_secs(5))
            .expect("登记后系统应立即推一次当前状态");
        assert_eq!(first, a.on_external_power(), "订阅与快照口径一致");
        assert!(
            a.watch_external_power(Box::new(|_| {})).is_none(),
            "同一时刻只允许一个订阅者"
        );
        drop(watch);
        let again = a.watch_external_power(Box::new(|_| {}));
        assert!(again.is_some(), "退订后可以重新登记");
    }

    /// 文档外的值不许被猜成插电或用电池。
    #[test]
    fn undocumented_values_are_unknown() {
        for v in 2..=254u8 {
            assert_eq!(ac_line_verdict(v), None, "ACLineStatus={v}");
        }
    }

    /// 真调一次系统 API：不许 panic。CI 虚拟机上读数不可控（可能报 255），
    /// 所以只打印、不断言具体值；真机插拔的证据在 PR 里。
    #[test]
    fn real_call_does_not_panic() {
        use crate::PlatformAdapter as _;
        println!(
            "on_external_power = {:?}",
            WindowsAdapter::new().on_external_power()
        );
    }
}

#[cfg(test)]
mod desk52_kill_tests {
    use super::*;
    use crate::KillOutcome;

    /// 子进程模式：被 `kills_a_running_process_and_waits_for_it` 以改名后的
    /// 测试二进制拉起，挂着等被杀。正常跑测试时这个环境变量不存在，立刻返回。
    const PROBE_ENV: &str = "PPF_DESK52_PROBE";

    #[test]
    fn kill_probe_child() {
        if std::env::var_os(PROBE_ENV).is_some() {
            std::thread::sleep(std::time::Duration::from_secs(60));
        }
    }

    #[test]
    fn nothing_matched_is_not_running() {
        assert_eq!(kill_verdict(&[]).unwrap(), KillOutcome::NotRunning);
    }

    /// 快照里有、动手时已经自己退了 ⇒ 也是没在跑，不是错误。
    #[test]
    fn already_gone_is_not_running() {
        assert_eq!(
            kill_verdict(&[ProcessKill::AlreadyGone]).unwrap(),
            KillOutcome::NotRunning
        );
    }

    #[test]
    fn terminated_is_killed() {
        assert_eq!(
            kill_verdict(&[ProcessKill::AlreadyGone, ProcessKill::Terminated]).unwrap(),
            KillOutcome::Killed
        );
    }

    /// 杀掉一个、另一个没杀掉 ⇒ 必须是 Err。放松这条就回到 DESK-25 的原病：
    /// 还有活着的却报成功，调用方接着去拉第二个 daemon。
    #[test]
    fn any_failure_is_a_failure_even_if_others_were_killed() {
        let e = kill_verdict(&[
            ProcessKill::Terminated,
            ProcessKill::Failed("pid 42：拒绝访问".into()),
        ])
        .unwrap_err();
        assert!(e.to_string().contains("pid 42"), "{e}");
    }

    /// 真机：一个必然不存在的映像名 ⇒ NotRunning。
    #[test]
    fn real_missing_process_is_not_running() {
        assert_eq!(
            kill_processes_named("p-pass-no-such-process-zzz.exe").unwrap(),
            KillOutcome::NotRunning
        );
    }

    /// 真机：把测试二进制复制成一个独一无二的名字拉起来，按名字杀掉它。
    /// 验三件事：报 Killed；返回时它**已经**退出（不是还在退）；再杀一次
    /// 报 NotRunning。
    #[test]
    fn kills_a_running_process_and_waits_for_it() {
        let dir = tempfile::tempdir().unwrap();
        let name = format!("ppf-desk52-probe-{}.exe", std::process::id());
        let exe = dir.path().join(&name);
        std::fs::copy(std::env::current_exe().unwrap(), &exe).unwrap();
        let mut child = std::process::Command::new(&exe)
            .args([
                "--exact",
                "windows::desk52_kill_tests::kill_probe_child",
                "--nocapture",
            ])
            .env(PROBE_ENV, "1")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();

        // 等它出现在快照里，免得把「还没起来」测成 NotRunning。
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while processes_named_in_this_session(&name).unwrap().is_empty() {
            assert!(std::time::Instant::now() < deadline, "探针进程没起来");
            std::thread::sleep(std::time::Duration::from_millis(50));
        }

        assert_eq!(kill_processes_named(&name).unwrap(), KillOutcome::Killed);
        let status = child
            .try_wait()
            .unwrap()
            .expect("kill 返回时进程必须已经退出");
        assert_eq!(status.code(), Some(KILLED_EXIT_CODE as i32));
        assert_eq!(
            kill_processes_named(&name).unwrap(),
            KillOutcome::NotRunning
        );
    }

    /// Windows 的文件名就是基名加 `.exe`——两者漂开会让按名字杀进程打空。
    #[test]
    fn executable_name_is_the_stem_plus_exe() {
        use crate::HostingAdapter as _;
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

#[cfg(test)]
mod desk58_stderr_capture_tests {
    use super::*;

    /// DESK-58 (#875)：只改接「没人接」的两种；有人刻意接的一律不动——
    /// 改接控制台会让终端前台跑的 daemon 什么都不打，改接管道会偷走测试框架
    /// 的输出。
    #[test]
    fn only_a_missing_or_null_stderr_is_captured() {
        assert!(stderr_needs_capture(StderrTarget::Missing));
        assert!(stderr_needs_capture(StderrTarget::NullDevice));
        for kept in [
            StderrTarget::Console,
            StderrTarget::Pipe,
            StderrTarget::Disk,
            StderrTarget::Unknown,
        ] {
            assert!(!stderr_needs_capture(kept), "{kept:?} 不该被改接");
        }
    }

    #[test]
    fn the_startup_stderr_file_sits_next_to_the_daemon_log() {
        let dir = Path::new(r"C:\data");
        let a = WindowsAdapter::new();
        assert_eq!(
            a.startup_stderr_file(dir),
            Some(dir.join("logs").join("daemon.err"))
        );
        assert_eq!(
            a.startup_stderr_file(dir).unwrap().parent(),
            a.default_log_file(dir).unwrap().parent()
        );
    }
}

#[cfg(test)]
mod desk60_autostart_tests {
    use super::*;

    /// 老版本写的 Run 值有带引号、不带引号两种；带参数的引号形式只取路径；空值算读不出。
    #[test]
    fn run_values_written_by_older_versions_still_parse() {
        assert_eq!(
            exec_from_run_value(r"C:\a\ppf-daemon.exe").as_deref(),
            Some(Path::new(r"C:\a\ppf-daemon.exe"))
        );
        assert_eq!(
            exec_from_run_value(r#""C:\a b\ppf-daemon.exe" --flag"#).as_deref(),
            Some(Path::new(r"C:\a b\ppf-daemon.exe"))
        );
        assert_eq!(exec_from_run_value("  "), None);
        assert_eq!(exec_from_run_value("\"\""), None);
    }

    /// 闸门：只认安装目录里的直接子文件；大小写、结尾分隔符不算差别；
    /// 「下载」目录、开发构建、安装目录的子目录一律拒绝。
    #[test]
    fn only_the_installed_daemon_passes_the_gate() {
        let install = Path::new(r"C:\Users\x\AppData\Local\P-Pass");
        assert!(is_in_install_dir(
            Path::new(r"C:\Users\x\AppData\Local\P-Pass\ppf-daemon.exe"),
            install
        ));
        assert!(is_in_install_dir(
            Path::new(r"c:\users\X\appdata\local\p-pass\ppf-daemon.exe"),
            Path::new(r"C:\Users\x\AppData\Local\P-Pass\")
        ));
        for elsewhere in [
            r"C:\Users\x\Downloads\P-Pass\ppf-daemon.exe",
            r"C:\Users\x\personal\P-Pass\target\release\ppf-daemon.exe",
            r"C:\Users\x\AppData\Local\P-Pass\old\ppf-daemon.exe",
            r"C:\Users\x\AppData\Local\P-Pass-copy\ppf-daemon.exe",
        ] {
            assert!(
                !is_in_install_dir(Path::new(elsewhere), install),
                "{elsewhere}"
            );
        }
        assert!(!is_in_install_dir(
            Path::new(r"C:\ppf-daemon.exe"),
            Path::new("")
        ));
    }

    #[test]
    fn windows_restores_a_missing_registration() {
        assert!(WindowsAdapter::new().autostart_restore_when_missing());
    }
}

#[cfg(test)]
mod desk65_scheduled_task_tests {
    use super::*;

    fn element<'a>(xml: &'a str, tag: &str) -> Vec<&'a str> {
        let (open, close) = (format!("<{tag}>"), format!("</{tag}>"));
        xml.split(open.as_str())
            .skip(1)
            .filter_map(|rest| rest.split(close.as_str()).next())
            .collect()
    }

    /// 与 launchd 对齐的四件事都写在任务定义里：登录启动、每分钟看门狗（已在跑
    /// 就跳过）、正常优先级、电池供电照常跑且不限时。
    #[test]
    fn the_task_starts_at_logon_and_is_watched_every_minute() {
        let xml = task_xml(
            Path::new(r"C:\Users\x\AppData\Local\P-Pass\ppf-daemon.exe"),
            r"PC\x",
        );
        assert_eq!(element(&xml, "UserId"), [r"PC\x", r"PC\x"]);
        assert!(xml.contains("<LogonTrigger>"), "{xml}");
        assert_eq!(element(&xml, "Interval"), ["PT1M"]);
        assert_eq!(element(&xml, "StopAtDurationEnd"), ["false"]);
        assert_eq!(element(&xml, "MultipleInstancesPolicy"), ["IgnoreNew"]);
        assert_eq!(element(&xml, "Priority"), ["5"]);
        assert_eq!(element(&xml, "DisallowStartIfOnBatteries"), ["false"]);
        assert_eq!(element(&xml, "StopIfGoingOnBatteries"), ["false"]);
        assert_eq!(element(&xml, "ExecutionTimeLimit"), ["PT0S"]);
        assert_eq!(element(&xml, "LogonType"), ["InteractiveToken"]);
        assert_eq!(element(&xml, "RunLevel"), ["LeastPrivilege"]);
        assert_eq!(
            element(&xml, "Command"),
            [r"C:\Users\x\AppData\Local\P-Pass\ppf-daemon.exe"]
        );
    }

    /// 用户名、路径里的 XML 特殊字符要转义，否则任务定义注册不上。
    #[test]
    fn special_characters_in_the_user_and_path_are_escaped() {
        let xml = task_xml(Path::new(r"C:\Users\A&B\P-Pass\ppf-daemon.exe"), r"PC\A&B");
        assert_eq!(
            element(&xml, "Command"),
            [r"C:\Users\A&amp;B\P-Pass\ppf-daemon.exe"]
        );
        assert!(element(&xml, "UserId").iter().all(|u| *u == r"PC\A&amp;B"));
    }

    #[test]
    fn windows_has_a_service_manager() {
        let mode = WindowsAdapter::new().service_mode();
        assert_eq!(mode, ServiceMode::ScheduledTask);
        assert!(mode.has_service_manager());
    }
}

#[cfg(test)]
mod ingest_file_name_tests {
    use super::*;

    #[test]
    fn illegal_characters_become_underscores() {
        assert_eq!(sanitize_windows_file_name("a:b.jpg"), "a_b.jpg");
        assert_eq!(
            sanitize_windows_file_name("a<b>c?d*e|f\"g.jpg"),
            "a_b_c_d_e_f_g.jpg"
        );
        assert_eq!(sanitize_windows_file_name("a/b\\c.jpg"), "a_b_c.jpg");
        assert_eq!(
            sanitize_windows_file_name("a\u{1}b\u{1f}c.jpg"),
            "a_b_c.jpg"
        );
    }

    #[test]
    fn del_is_not_in_the_ascii_control_range_we_replace() {
        // Windows forbids 0x00-0x1F, not 0x7F. Keep the rule exact.
        assert_eq!(sanitize_windows_file_name("a\u{7f}b.jpg"), "a\u{7f}b.jpg");
    }

    #[test]
    fn reserved_names_get_underscore_prefix_case_insensitively() {
        for (input, expected) in [
            ("CON", "_CON"),
            ("con", "_con"),
            ("CON.jpg", "_CON.jpg"),
            ("con.tar.gz", "_con.tar.gz"),
            ("PRN", "_PRN"),
            ("AUX.txt", "_AUX.txt"),
            ("NUL", "_NUL"),
            ("NUL.txt", "_NUL.txt"),
            ("COM1", "_COM1"),
            ("com9.txt", "_com9.txt"),
            ("LPT1.log", "_LPT1.log"),
            // Windows ignores trailing spaces/dots when matching the base.
            ("CON .jpg", "_CON .jpg"),
        ] {
            assert_eq!(sanitize_windows_file_name(input), expected, "input={input}");
        }

        // Not reserved: COM0 / COM10 / names that merely start with a device
        // name.
        for legal in ["COM0.txt", "COM10.txt", "CONSOLE.txt", "LPT10.txt"] {
            assert_eq!(sanitize_windows_file_name(legal), legal);
        }
    }

    #[test]
    fn trailing_dots_and_spaces_are_stripped() {
        assert_eq!(sanitize_windows_file_name("photo.jpg."), "photo.jpg");
        assert_eq!(sanitize_windows_file_name("photo.jpg "), "photo.jpg");
        assert_eq!(sanitize_windows_file_name("photo.jpg. "), "photo.jpg");
        assert_eq!(sanitize_windows_file_name("..."), "unnamed.bin");
    }

    #[test]
    fn empty_and_dot_names_fall_back() {
        assert_eq!(sanitize_windows_file_name(""), "unnamed.bin");
        assert_eq!(sanitize_windows_file_name("."), "unnamed.bin");
        assert_eq!(sanitize_windows_file_name(".."), "unnamed.bin");
    }

    #[test]
    fn legal_names_are_unchanged() {
        for legal in [
            "IMG_1.jpg",
            "照片.jpg",
            "hello world.jpg",
            "a_b.jpg",
            "CONSOLE.jpg",
        ] {
            assert_eq!(sanitize_windows_file_name(legal), legal);
        }
    }
}
