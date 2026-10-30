//! #1167 / D5：Windows 上常驻 daemon 的本机 IPC——命名管道，按 **Windows 用户 SID** 认人。
//!
//! 和 macOS 的签名 socket（`local_peer.rs`）对称：没有令牌文件，三道门都由系统给出的
//! 身份把守，不靠「能读到某个文件」。
//!
//! 1. **管道 DACL（内核强制，第一道）**：只放白名单 SID，外加一条拒绝网络登录（`NU`）；
//!    `PIPE_REJECT_REMOTE_CLIENTS`（interprocess 默认不接受远程）；首个实例带
//!    `FILE_FLAG_FIRST_PIPE_INSTANCE`（interprocess 建首实例时自带），名字已被别人
//!    占了就建不出来——daemon 起不来，而不是和抢注者共用一个名字。
//! 2. **服务端核对客户端（第二道）**：`ImpersonateNamedPipeClient` → `OpenThreadToken`
//!    取 `TokenUser`。不按 PID 查：PID 在查询前可能已换了进程（interprocess `PeerCreds`
//!    文档里的竞态），模拟拿到的是**这条连接**的客户端令牌，没有这个窗口。
//!    模拟要求服务端先从管道读到数据（否则 ERROR_CANNOT_IMPERSONATE，实测），所以 daemon
//!    先读出第一行再认人（`peer_check_needs_first_message`）；认不过的那一行直接丢掉。
//! 3. **客户端核对服务端**：看**管道对象的属主 SID**（daemon 建管道时显式写进安全描述符，
//!    别的账户写不出这个属主），服务形态再要求服务端会话是 0（服务会话）。
//!    不用 `GetNamedPipeServerProcessId` → `OpenProcessToken`：普通用户打不开服务进程
//!    （2026-10-27 在 Win11 26200 上实测：中完整性用户对 LocalSystem / LocalService /
//!    NetworkService 的服务进程 `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` 一律
//!    ERROR_ACCESS_DENIED），按 PID 查身份在服务形态下根本走不通。
//!
//! ### 为什么还要第 3 道里的「会话 0」
//!
//! 主人对管道有 `GRGW`；命名管道把 `GENERIC_WRITE` 映射成含 `FILE_APPEND_DATA` 的
//! `FILE_GENERIC_WRITE`，而 `FILE_APPEND_DATA` 在管道上就是 `FILE_CREATE_PIPE_INSTANCE`。
//! 客户端（tokio / interprocess）打开管道一律请求 `GENERIC_WRITE`，不给这一位就连不上。
//! 所以主人名下的程序**能**给同一个管道多建一个实例、抢着 accept 下一个连接——同名管道
//! 的实例共用一份安全描述符，属主核对拦不住它；但它跑在主人的交互会话（≥1）里，进不了
//! 会话 0，「服务端会话必须是 0」把它挡在外面。计划任务形态下 daemon 本来就跑在主人名下，
//! 主人自己的程序与 daemon 同一主体（D5：按用户认），不需要这一条。
//!
//! ### 管道名
//!
//! 服务形态整台机器一份：`ppf-svc`。计划任务形态每个用户一份：`ppf-<用户 SID>`——两个用户
//! 同时登录时各连各的，不会抢同一个名字（#1167 第 6 条）。不用 `ppf-<NodeId 前 8 位>`：
//! NodeId 只在 daemon 手里（服务形态下在 ProgramData，主人读不到），以前是靠令牌文件把
//! 名字告诉壳；令牌文件去掉以后，名字必须是两边都能独立算出来的东西。

use std::ffi::c_void;
use std::io;
use std::os::windows::io::{AsRawHandle as _, RawHandle};

use interprocess::local_socket::{tokio::Listener, GenericNamespaced, ListenerOptions, ToNsName};
use interprocess::os::windows::local_socket::ListenerOptionsExt as _;
use interprocess::os::windows::security_descriptor::SecurityDescriptor;

use crate::local_peer::{PeerCheck, PeerRole, PeerUser};
use crate::windows_programdata::{self, ProgramDataStore};
use crate::{PlatformError, Result};

/// 服务形态的管道名（整台机器一份）。
pub const SERVICE_PIPE_NAME: &str = "ppf-svc";

/// `INTERACTIVE`（本机交互登录的用户，含远程桌面）。未认领状态下管道只对它开放。
const INTERACTIVE_SID: &str = "IU";

fn failed(action: &'static str, detail: impl Into<String>) -> PlatformError {
    PlatformError::Failed {
        action,
        detail: detail.into(),
    }
}

/// 常驻 daemon 由 SCM 托管吗。daemon 进程里看「自己是不是服务」；窗口程序里看
/// 「服务装没装」（per-machine 安装才有服务）。两边对同一台机器答案一致。
fn service_hosted() -> bool {
    crate::service_mode_active()
        || crate::windows_service::is_installed(crate::windows_service::SERVICE_NAME)
            .unwrap_or(false)
}

/// `NT SERVICE\P-Pass` 的 SID。由服务名派生、装好后不变，查一次就缓存。
fn service_sid() -> Result<String> {
    static SID: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    if let Some(s) = SID.get() {
        return Ok(s.clone());
    }
    let account = format!(r"NT SERVICE\{}", crate::windows_service::SERVICE_NAME);
    let sid = windows_programdata::account_sid_string(&account)?;
    Ok(SID.get_or_init(|| sid).clone())
}

/// 常驻 daemon 的管道名（daemon 与窗口程序各自算，结果相同）。
pub fn resident_pipe_name() -> Result<String> {
    if service_hosted() {
        Ok(SERVICE_PIPE_NAME.to_string())
    } else {
        Ok(format!(
            "ppf-{}",
            windows_programdata::current_user_sid_string()?
        ))
    }
}

// ── 主人（D3）：`%ProgramData%\P-Pass\owner` ─────────────────────────────────

/// 主人记录的位置。文件继承 ProgramData 目录的 DACL：只有服务账户与 Administrators
/// 能写（也只有它们能读——窗口程序不需要读它，管道 DACL 替它把关）。
pub fn owner_path() -> std::path::PathBuf {
    windows_programdata::service_root().join("owner")
}

/// 读主人 SID。`Ok(None)` 只代表文件确实不存在；读不出 / 内容不是合法 SID ⇒ `Err`。
pub fn read_owner_at(path: &std::path::Path) -> Result<Option<String>> {
    let store = ProgramDataStore::new(path, "主人");
    let Some(bytes) = store.read()? else {
        return Ok(None);
    };
    let text = String::from_utf8(bytes).map_err(|_| failed("read_owner", "主人记录不是 UTF-8"))?;
    let sid = text.trim();
    validate_sid(sid)?;
    Ok(Some(sid.to_string()))
}

/// 写主人 SID。已经有**另一个**主人时拒绝——换主人只能由管理员删掉整个
/// `%ProgramData%\P-Pass`（身份重置），不能被一次 IPC 调用改掉。
pub fn write_owner_at(path: &std::path::Path, sid: &str) -> Result<()> {
    validate_sid(sid)?;
    if let Some(existing) = read_owner_at(path)? {
        if existing == sid {
            return Ok(());
        }
        return Err(failed(
            "write_owner",
            format!("这台电脑的 P-Pass 已有主人 {existing}，不能改成 {sid}"),
        ));
    }
    ProgramDataStore::new(path, "主人").write(sid.as_bytes())
}

fn validate_sid(sid: &str) -> Result<()> {
    if !sid.starts_with("S-1-") {
        return Err(failed("validate_sid", format!("不是 SID：{sid}")));
    }
    let p = windows_programdata::sid_from_string(sid)?;
    // SAFETY: p 来自 sid_from_string。
    unsafe { windows_programdata::free_sid(p) };
    Ok(())
}

// ── 管道的访问策略 ─────────────────────────────────────────────────────────

/// daemon 这一侧：谁能连、连上来的人是什么角色。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PipePolicy {
    /// 服务形态、还没有主人：本机交互用户都能连（daemon 此时只开放配置方法）。
    ServiceUnclaimed { service: String },
    /// 服务形态、已有主人：只有主人与服务自己。
    ServiceClaimed { service: String, owner: String },
    /// 计划任务形态：daemon 跑在用户自己名下，只有这个用户。
    User { user: String },
}

impl PipePolicy {
    /// 按这台机器、这个进程的现状算出来（daemon 进程里调）。
    pub(crate) fn current() -> Result<Self> {
        if crate::service_mode_active() {
            let service = service_sid()?;
            Ok(match read_owner_at(&owner_path())? {
                Some(owner) => PipePolicy::ServiceClaimed { service, owner },
                None => PipePolicy::ServiceUnclaimed { service },
            })
        } else {
            Ok(PipePolicy::User {
                user: windows_programdata::current_user_sid_string()?,
            })
        }
    }

    /// 管道的安全描述符（SDDL）。
    ///
    /// - `O:` 显式写成 daemon 自己的 SID：客户端据此认出「这是 P-Pass 建的管道」。
    /// - `P`：受保护，不继承任何默认 ACE（默认管道 DACL 给 Everyone 读）。
    /// - 第一条拒绝网络登录（`NU`），与 `PIPE_REJECT_REMOTE_CLIENTS` 双保险。
    /// - daemon 自己 `GA`（要建后续实例）；客户端只有 `GRGW`。
    pub(crate) fn sddl(&self) -> String {
        match self {
            PipePolicy::ServiceUnclaimed { service } => format!(
                "O:{service}D:P(D;;GA;;;NU)(A;;GA;;;{service})(A;;GRGW;;;{INTERACTIVE_SID})"
            ),
            PipePolicy::ServiceClaimed { service, owner } => {
                format!("O:{service}D:P(D;;GA;;;NU)(A;;GA;;;{service})(A;;GRGW;;;{owner})")
            }
            PipePolicy::User { user } => format!("O:{user}D:P(D;;GA;;;NU)(A;;GA;;;{user})"),
        }
    }

    /// 服务端核对：连接方 SID → 角色。`allowed` 按调用方给的顺序认。
    pub(crate) fn classify_client(&self, sid: &str, allowed: &[PeerRole]) -> PeerCheck {
        let pick = |role: PeerRole| {
            if allowed.contains(&role) {
                PeerCheck::Verified(role)
            } else {
                PeerCheck::Rejected(format!("{sid} 不能以 {role:?} 身份连接"))
            }
        };
        match self {
            PipePolicy::ServiceUnclaimed { service } if sid == service => pick(PeerRole::Daemon),
            // 未认领：DACL 已把门限在本机交互用户，谁先完成向导谁成为主人（D3）。
            PipePolicy::ServiceUnclaimed { .. } => pick(PeerRole::Shell),
            PipePolicy::ServiceClaimed { service, .. } if sid == service => pick(PeerRole::Daemon),
            PipePolicy::ServiceClaimed { owner, .. } if sid == owner => pick(PeerRole::Shell),
            PipePolicy::ServiceClaimed { .. } => {
                PeerCheck::Rejected(format!("{sid} 不是这台电脑 P-Pass 的主人"))
            }
            // 同一个用户的程序（窗口程序、daemon 自己的单实例交接）都是这个用户：
            // 按用户认（D5），给窗口程序的权限。
            PipePolicy::User { user } if sid == user => {
                if allowed.contains(&PeerRole::Shell) {
                    PeerCheck::Verified(PeerRole::Shell)
                } else {
                    pick(PeerRole::Daemon)
                }
            }
            PipePolicy::User { user } => {
                PeerCheck::Rejected(format!("{sid} 不是运行 daemon 的用户 {user}"))
            }
        }
    }
}

/// 客户端这一侧：连上的管道应该是谁建的。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ServerExpectation {
    /// 管道属主必须是这个 SID。
    pub(crate) owner: String,
    /// 服务端必须在会话 0（服务会话）。
    pub(crate) session_zero: bool,
}

impl ServerExpectation {
    /// 窗口程序 / daemon 作为客户端时调。不读主人记录（窗口程序读不到 ProgramData）。
    pub(crate) fn current() -> Result<Self> {
        if service_hosted() {
            Ok(Self {
                owner: service_sid()?,
                session_zero: true,
            })
        } else {
            Ok(Self {
                owner: windows_programdata::current_user_sid_string()?,
                session_zero: false,
            })
        }
    }

    pub(crate) fn judge(&self, pipe_owner: &str, server_session: u32) -> PeerCheck {
        if pipe_owner != self.owner {
            return PeerCheck::Rejected(format!(
                "管道属主是 {pipe_owner}，不是 P-Pass 后台服务（应为 {}）——可能被别的程序抢注",
                self.owner
            ));
        }
        if self.session_zero && server_session != 0 {
            return PeerCheck::Rejected(format!(
                "服务端在会话 {server_session}，P-Pass 后台服务只在会话 0——可能被别的程序抢注"
            ));
        }
        PeerCheck::Verified(PeerRole::Daemon)
    }
}

// ── 系统调用 ─────────────────────────────────────────────────────────────────

/// 以 `sddl` 为安全描述符建 tokio 监听（首实例独占、拒绝远程由 interprocess 负责）。
pub(crate) fn bind_with_sddl(name: &str, sddl: &str) -> io::Result<Listener> {
    let wide = widestring::U16CString::from_str(sddl).map_err(io::Error::other)?;
    let sd = SecurityDescriptor::deserialize(&wide)?;
    let ns = name.to_ns_name::<GenericNamespaced>()?;
    ListenerOptions::new()
        .name(ns)
        .security_descriptor(sd)
        .create_tokio()
}

/// 常驻 daemon 的管道监听（策略按本进程现状算）。
pub fn bind_resident(name: &str) -> io::Result<Listener> {
    let policy = PipePolicy::current().map_err(io::Error::other)?;
    bind_with_sddl(name, &policy.sddl())
}

/// 服务端：按**这条连接**模拟客户端，取它的用户 SID。
///
/// 调用线程在模拟期间换了身份，所以无论成败都先 `RevertToSelf` 再返回；恢复失败
/// 就直接终止进程——带着别人的身份继续跑是绝不能接受的状态。
pub(crate) fn client_sid(handle: RawHandle) -> io::Result<String> {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::Security::{RevertToSelf, TOKEN_QUERY};
    use windows_sys::Win32::System::Pipes::ImpersonateNamedPipeClient;
    use windows_sys::Win32::System::Threading::{GetCurrentThread, OpenThreadToken};

    let h = handle as HANDLE;
    // SAFETY: h 是调用方持有的管道服务端句柄，调用期间有效。
    if unsafe { ImpersonateNamedPipeClient(h) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut token: HANDLE = std::ptr::null_mut();
    // OpenAsSelf = TRUE：按进程自己的身份做访问检查（客户端令牌通常只到标识级）。
    // SAFETY: GetCurrentThread 是伪句柄；token 是出参。
    let opened = unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) };
    let open_err = io::Error::last_os_error();
    // SAFETY: 无参数；失败意味着本线程仍顶着客户端身份。
    if unsafe { RevertToSelf() } == 0 {
        std::process::abort();
    }
    if opened == 0 {
        return Err(open_err);
    }
    let sid = windows_programdata::token_user_sid_string(token).map_err(io::Error::other);
    // SAFETY: token 是 OpenThreadToken 成功返回的真句柄。
    unsafe { CloseHandle(token) };
    sid
}

/// 客户端：管道对象的属主 SID（需要句柄上有 `READ_CONTROL`；`GENERIC_READ` 含它）。
pub(crate) fn pipe_owner_sid(handle: RawHandle) -> io::Result<String> {
    use windows_sys::Win32::Foundation::{LocalFree, ERROR_SUCCESS, HANDLE};
    use windows_sys::Win32::Security::Authorization::{GetSecurityInfo, SE_FILE_OBJECT};
    use windows_sys::Win32::Security::{OWNER_SECURITY_INFORMATION, PSID};

    let mut owner: PSID = std::ptr::null_mut();
    let mut sd: *mut c_void = std::ptr::null_mut();
    // SAFETY: handle 有效；成功时 sd 由 LocalAlloc 分配，owner 指向 sd 内部。
    let rc = unsafe {
        GetSecurityInfo(
            handle as HANDLE,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            &mut owner,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut sd,
        )
    };
    if rc != ERROR_SUCCESS {
        return Err(io::Error::from_raw_os_error(rc as i32));
    }
    let out = if owner.is_null() {
        Err(io::Error::other("管道没有属主"))
    } else {
        // SAFETY: owner 指向 sd 里的合法 SID。
        Ok(unsafe { windows_programdata::sid_to_string(owner) })
    };
    // SAFETY: sd 由 GetSecurityInfo 分配。
    unsafe { LocalFree(sd) };
    out
}

/// 客户端打开管道：只允许服务端在 Identification 级识别本客户端。
///
/// 打开方式与 interprocess 自己的客户端一致（`GENERIC_READ | GENERIC_WRITE`、可共享读写、
/// `FILE_FLAG_OVERLAPPED`），只多带 SQOS 标志；管道忙时等它空出来再试（与 interprocess 的
/// 无上限等待相同）。系统错误原样返回——拒绝访问仍是 `PermissionDenied`，调用方据此说话。
fn open_identification_only(name: &str) -> io::Result<std::os::windows::io::OwnedHandle> {
    use std::os::windows::io::FromRawHandle as _;
    use windows_sys::Win32::Foundation::{
        ERROR_PIPE_BUSY, GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_FLAG_OVERLAPPED, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
        SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
    };
    use windows_sys::Win32::System::Pipes::{WaitNamedPipeW, NMPWAIT_WAIT_FOREVER};

    let path: Vec<u16> = format!(r"\\.\pipe\{name}")
        .encode_utf16()
        .chain(Some(0))
        .collect();
    loop {
        // SAFETY: path 是 NUL 结尾的宽字符串；成功时返回的句柄归我们所有。
        let h = unsafe {
            CreateFileW(
                path.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                std::ptr::null_mut(),
            )
        };
        if h != INVALID_HANDLE_VALUE {
            // SAFETY: h 是 CreateFileW 刚返回的有效句柄，所有权交给 OwnedHandle。
            return Ok(unsafe { std::os::windows::io::OwnedHandle::from_raw_handle(h) });
        }
        let err = io::Error::last_os_error();
        if err.raw_os_error() != Some(ERROR_PIPE_BUSY as i32) {
            return Err(err);
        }
        // SAFETY: path 同上。
        if unsafe { WaitNamedPipeW(path.as_ptr(), NMPWAIT_WAIT_FOREVER) } == 0 {
            return Err(io::Error::last_os_error());
        }
    }
}

/// 同步客户端连接（Identification 级）。
pub(crate) fn connect_identification_sync(
    name: &str,
) -> io::Result<interprocess::local_socket::Stream> {
    let handle = open_identification_only(name)?;
    let pipe = interprocess::os::windows::named_pipe::local_socket::Stream::try_from(handle)
        .map_err(io::Error::from)?;
    Ok(interprocess::local_socket::Stream::from(pipe))
}

/// tokio 客户端连接（Identification 级）。打开句柄是阻塞调用（管道忙时要等），放阻塞线程池。
pub(crate) async fn connect_identification_tokio(
    name: &str,
) -> io::Result<interprocess::local_socket::tokio::Stream> {
    let name = name.to_string();
    let handle = tokio::task::spawn_blocking(move || open_identification_only(&name))
        .await
        .map_err(io::Error::other)??;
    let pipe = interprocess::os::windows::named_pipe::local_socket::tokio::Stream::try_from(handle)
        .map_err(io::Error::from)?;
    Ok(interprocess::local_socket::tokio::Stream::from(pipe))
}

/// 服务端：这条连接上客户端令牌的模拟级别（`SECURITY_IMPERSONATION_LEVEL`）。只读不改，
/// 与 [`client_sid`] 同样先模拟、再立刻恢复。用于核对客户端确实以 Identification 级连接。
#[cfg(test)]
pub(crate) fn client_impersonation_level(handle: RawHandle) -> io::Result<i32> {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::Security::{
        GetTokenInformation, RevertToSelf, TokenImpersonationLevel, TOKEN_QUERY,
    };
    use windows_sys::Win32::System::Pipes::ImpersonateNamedPipeClient;
    use windows_sys::Win32::System::Threading::{GetCurrentThread, OpenThreadToken};

    let h = handle as HANDLE;
    // SAFETY: 同 client_sid。
    if unsafe { ImpersonateNamedPipeClient(h) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut token: HANDLE = std::ptr::null_mut();
    let opened = unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) };
    let open_err = io::Error::last_os_error();
    if unsafe { RevertToSelf() } == 0 {
        std::process::abort();
    }
    if opened == 0 {
        return Err(open_err);
    }
    let mut level = 0i32;
    let mut len = 0u32;
    // SAFETY: token 有效；level 是 4 字节可写缓冲。
    let ok = unsafe {
        GetTokenInformation(
            token,
            TokenImpersonationLevel,
            (&mut level as *mut i32).cast(),
            std::mem::size_of::<i32>() as u32,
            &mut len,
        )
    };
    let err = io::Error::last_os_error();
    unsafe { CloseHandle(token) };
    if ok == 0 {
        return Err(err);
    }
    Ok(level)
}

// ── 接到 local_peer 的抽象上 ──────────────────────────────────────────────────

fn check_server_side(handle: RawHandle, allowed: &[PeerRole]) -> PeerCheck {
    let sid = match client_sid(handle) {
        Ok(s) => s,
        Err(e) => return PeerCheck::Rejected(format!("取不到客户端身份：{e}")),
    };
    match PipePolicy::current() {
        Ok(policy) => policy.classify_client(&sid, allowed),
        Err(e) => PeerCheck::Rejected(format!("读不出管道访问策略：{e}")),
    }
}

fn check_client_side(
    handle: RawHandle,
    session: io::Result<u32>,
    allowed: &[PeerRole],
) -> PeerCheck {
    if !allowed.contains(&PeerRole::Daemon) {
        return PeerCheck::Rejected("客户端只接受 daemon 作为服务端".into());
    }
    let owner = match pipe_owner_sid(handle) {
        Ok(o) => o,
        Err(e) => return PeerCheck::Rejected(format!("读不出管道属主：{e}")),
    };
    let session = match session {
        Ok(s) => s,
        Err(e) => return PeerCheck::Rejected(format!("读不出服务端会话：{e}")),
    };
    match ServerExpectation::current() {
        Ok(expect) => expect.judge(&owner, session),
        Err(e) => PeerCheck::Rejected(format!("算不出期望的服务端：{e}")),
    }
}

pub(crate) fn check_sync(
    s: &interprocess::local_socket::Stream,
    allowed: &[PeerRole],
) -> PeerCheck {
    #[allow(unreachable_patterns)]
    match s {
        interprocess::local_socket::Stream::NamedPipe(p) => {
            let inner = p.inner();
            let handle = inner.as_raw_handle();
            if inner.is_server() {
                check_server_side(handle, allowed)
            } else {
                check_client_side(handle, inner.server_session_id(), allowed)
            }
        }
        _ => PeerCheck::Rejected("不是命名管道".into()),
    }
}

pub(crate) fn check_tokio(
    s: &interprocess::local_socket::tokio::Stream,
    allowed: &[PeerRole],
) -> PeerCheck {
    #[allow(unreachable_patterns)]
    match s {
        interprocess::local_socket::tokio::Stream::NamedPipe(p) => {
            let inner = p.inner();
            let handle = inner.as_raw_handle();
            if inner.is_server() {
                check_server_side(handle, allowed)
            } else {
                check_client_side(handle, inner.server_session_id(), allowed)
            }
        }
        _ => PeerCheck::Rejected("不是命名管道".into()),
    }
}

pub(crate) fn peer_user_tokio(s: &interprocess::local_socket::tokio::Stream) -> Option<PeerUser> {
    #[allow(unreachable_patterns)]
    match s {
        interprocess::local_socket::tokio::Stream::NamedPipe(p) if p.inner().is_server() => {
            client_sid(p.inner().as_raw_handle()).ok().map(PeerUser)
        }
        _ => None,
    }
}

pub(crate) fn peer_user_sync(s: &interprocess::local_socket::Stream) -> Option<PeerUser> {
    #[allow(unreachable_patterns)]
    match s {
        interprocess::local_socket::Stream::NamedPipe(p) if p.inner().is_server() => {
            client_sid(p.inner().as_raw_handle()).ok().map(PeerUser)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use interprocess::local_socket::traits::tokio::{Listener as _, Stream as _};

    fn me() -> String {
        windows_programdata::current_user_sid_string().expect("current sid")
    }

    /// 一个这台机器上肯定没人用的域用户 SID（RID 随便取）。
    const STRANGER: &str = "S-1-5-21-1111111111-2222222222-3333333333-4242";
    const SERVICE: &str = "S-1-5-80-1-2-3-4-5";

    fn unique(tag: &str) -> String {
        format!("ppf-test-{tag}-{}-{}", std::process::id(), nanos())
    }

    fn nanos() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    }

    fn connect_name(name: &str) -> interprocess::local_socket::Name<'static> {
        name.to_string().to_ns_name::<GenericNamespaced>().unwrap()
    }

    // ── 纯策略（每条分支一个反证） ──

    #[test]
    fn claimed_service_pipe_admits_only_owner_and_service() {
        let p = PipePolicy::ServiceClaimed {
            service: SERVICE.into(),
            owner: me(),
        };
        let both = [PeerRole::Shell, PeerRole::Daemon];
        assert_eq!(
            p.classify_client(&me(), &both),
            PeerCheck::Verified(PeerRole::Shell)
        );
        assert_eq!(
            p.classify_client(SERVICE, &both),
            PeerCheck::Verified(PeerRole::Daemon)
        );
        assert!(matches!(
            p.classify_client(STRANGER, &both),
            PeerCheck::Rejected(_)
        ));
        let sddl = p.sddl();
        assert!(
            sddl.starts_with(&format!("O:{SERVICE}D:P(D;;GA;;;NU)")),
            "{sddl}"
        );
        assert!(sddl.contains(&format!("(A;;GRGW;;;{})", me())), "{sddl}");
        assert!(!sddl.contains(";IU)"), "认领后不许再对交互用户开放：{sddl}");
    }

    #[test]
    fn unclaimed_service_pipe_is_open_to_interactive_users_only() {
        let p = PipePolicy::ServiceUnclaimed {
            service: SERVICE.into(),
        };
        let both = [PeerRole::Shell, PeerRole::Daemon];
        assert_eq!(
            p.classify_client(STRANGER, &both),
            PeerCheck::Verified(PeerRole::Shell)
        );
        assert_eq!(
            p.classify_client(SERVICE, &both),
            PeerCheck::Verified(PeerRole::Daemon)
        );
        assert!(p.sddl().ends_with("(A;;GRGW;;;IU)"), "{}", p.sddl());
    }

    #[test]
    fn scheduled_task_pipe_admits_only_its_user() {
        let p = PipePolicy::User { user: me() };
        let both = [PeerRole::Shell, PeerRole::Daemon];
        assert_eq!(
            p.classify_client(&me(), &both),
            PeerCheck::Verified(PeerRole::Shell)
        );
        assert!(matches!(
            p.classify_client(STRANGER, &both),
            PeerCheck::Rejected(_)
        ));
    }

    #[test]
    fn client_rejects_a_pipe_not_owned_by_the_service_or_outside_session_zero() {
        let svc = ServerExpectation {
            owner: SERVICE.into(),
            session_zero: true,
        };
        assert_eq!(svc.judge(SERVICE, 0), PeerCheck::Verified(PeerRole::Daemon));
        assert!(
            matches!(svc.judge(&me(), 0), PeerCheck::Rejected(_)),
            "属主不对"
        );
        assert!(
            matches!(svc.judge(SERVICE, 1), PeerCheck::Rejected(_)),
            "会话不对"
        );
        let user = ServerExpectation {
            owner: me(),
            session_zero: false,
        };
        assert_eq!(user.judge(&me(), 1), PeerCheck::Verified(PeerRole::Daemon));
        assert!(matches!(user.judge(STRANGER, 1), PeerCheck::Rejected(_)));
    }

    // ── 真管道（内核与系统调用的真实行为） ──

    /// 判据「非白名单 SID 连管道被拒」的内核那一道：DACL 只放一个陌生 SID 时，
    /// 本用户连接得到 ERROR_ACCESS_DENIED。反证：DACL 放本用户就连得上。
    #[tokio::test]
    async fn the_kernel_refuses_a_sid_outside_the_pipe_dacl() {
        let denied = unique("deny");
        let _l =
            bind_with_sddl(&denied, &format!("O:{}D:P(A;;GA;;;{STRANGER})", me())).expect("bind");
        let err = interprocess::local_socket::tokio::Stream::connect(connect_name(&denied))
            .await
            .expect_err("不在 DACL 里的用户必须连不上");
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied, "{err:?}");

        let allowed = unique("allow");
        let _l2 = bind_with_sddl(&allowed, &PipePolicy::User { user: me() }.sddl()).expect("bind");
        interprocess::local_socket::tokio::Stream::connect(connect_name(&allowed))
            .await
            .expect("白名单用户必须连得上");
    }

    /// 判据「非 P-Pass 进程抢注同名管道」的首实例那一道：名字已被占时 daemon 建不出
    /// 监听（不会和抢注者共用名字）。反证：名字空着时建得出来（上一个测试）。
    #[tokio::test]
    async fn a_taken_name_cannot_be_bound_again() {
        let name = unique("first");
        let sddl = PipePolicy::User { user: me() }.sddl();
        let _squatter = bind_with_sddl(&name, &sddl).expect("first");
        assert!(
            bind_with_sddl(&name, &sddl).is_err(),
            "首实例标记必须让第二次建失败"
        );
    }

    /// 服务端模拟取到的就是连接方的真实 SID；按策略分类：白名单 ⇒ 通过，
    /// 不在白名单（策略里只有陌生 SID）⇒ 拒绝。
    #[tokio::test]
    async fn the_server_reads_the_clients_sid_by_impersonation() {
        let name = unique("imp");
        let listener =
            bind_with_sddl(&name, &PipePolicy::User { user: me() }.sddl()).expect("bind");
        let (client, server) = tokio::join!(
            interprocess::local_socket::tokio::Stream::connect(connect_name(&name)),
            listener.accept()
        );
        let (client, server) = (client.expect("connect"), server.expect("accept"));
        #[allow(irrefutable_let_patterns)]
        let interprocess::local_socket::tokio::Stream::NamedPipe(p) = &server;
        // 读到数据之前模拟必然失败（ERROR_CANNOT_IMPERSONATE）——这正是 daemon 要先读第一行的原因。
        let early = client_sid(p.inner().as_raw_handle()).expect_err("没读到数据前不能模拟");
        assert_eq!(early.raw_os_error(), Some(1368), "{early:?}");
        {
            use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
            (&client).write_all(b"x\n").await.expect("write");
            let mut buf = [0u8; 2];
            (&server).read_exact(&mut buf).await.expect("read");
        }
        let sid = client_sid(p.inner().as_raw_handle()).expect("impersonate");
        assert_eq!(sid, me());
        let both = [PeerRole::Shell, PeerRole::Daemon];
        assert_eq!(
            PipePolicy::User { user: me() }.classify_client(&sid, &both),
            PeerCheck::Verified(PeerRole::Shell)
        );
        assert!(matches!(
            PipePolicy::ServiceClaimed {
                service: SERVICE.into(),
                owner: STRANGER.into()
            }
            .classify_client(&sid, &both),
            PeerCheck::Rejected(_)
        ));
    }

    /// 客户端读到的管道属主就是建管道时 SDDL 里写的 `O:`；拿服务形态的期望去比 ⇒ 拒绝
    /// （本用户建的管道冒充不了服务）。反证：拿计划任务形态的期望（本用户）⇒ 通过。
    #[tokio::test]
    async fn the_client_reads_the_pipe_owner_and_spots_a_squatter() {
        let name = unique("owner");
        let listener =
            bind_with_sddl(&name, &PipePolicy::User { user: me() }.sddl()).expect("bind");
        let (client, _server) = tokio::join!(
            interprocess::local_socket::tokio::Stream::connect(connect_name(&name)),
            listener.accept()
        );
        let client = client.expect("connect");
        #[allow(irrefutable_let_patterns)]
        let interprocess::local_socket::tokio::Stream::NamedPipe(p) = &client;
        let owner = pipe_owner_sid(p.inner().as_raw_handle()).expect("owner");
        assert_eq!(owner, me());
        let session = p.inner().server_session_id().expect("session");
        assert!(matches!(
            ServerExpectation {
                owner: SERVICE.into(),
                session_zero: true
            }
            .judge(&owner, session),
            PeerCheck::Rejected(_)
        ));
        assert_eq!(
            ServerExpectation {
                owner: me(),
                session_zero: false
            }
            .judge(&owner, session),
            PeerCheck::Verified(PeerRole::Daemon)
        );
    }

    /// 客户端以 Identification 级连接：服务端拿到的客户端令牌级别是 `SecurityIdentification`，
    /// 仍能读出客户端 SID（认人不受影响）。反证：interprocess 默认连接（不带 SQOS）在同一
    /// 测试里得到的是 `SecurityImpersonation`——去掉 SQOS 标志，第一条断言就红。
    #[tokio::test]
    async fn pipe_client_connects_at_identification_level() {
        use windows_sys::Win32::Security::{SecurityIdentification, SecurityImpersonation};

        async fn served_level(
            name: &str,
            listener: &interprocess::local_socket::tokio::Listener,
            identification: bool,
        ) -> (i32, String) {
            let connect = async {
                if identification {
                    connect_identification_tokio(name).await
                } else {
                    interprocess::local_socket::tokio::Stream::connect(connect_name(name)).await
                }
            };
            let (client, server) = tokio::join!(connect, listener.accept());
            let (client, server) = (client.expect("connect"), server.expect("accept"));
            {
                use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
                (&client).write_all(b"x\n").await.expect("write");
                let mut buf = [0u8; 2];
                (&server).read_exact(&mut buf).await.expect("read");
            }
            #[allow(irrefutable_let_patterns)]
            let interprocess::local_socket::tokio::Stream::NamedPipe(p) = &server;
            let handle = p.inner().as_raw_handle();
            (
                client_impersonation_level(handle).expect("level"),
                client_sid(handle).expect("sid"),
            )
        }

        let name = unique("sqos");
        let listener =
            bind_with_sddl(&name, &PipePolicy::User { user: me() }.sddl()).expect("bind");
        let (level, sid) = served_level(&name, &listener, true).await;
        assert_eq!(
            level, SecurityIdentification,
            "壳的连接必须是 Identification 级"
        );
        assert_eq!(sid, me(), "Identification 级令牌仍要能认出客户端");
        let (level, _) = served_level(&name, &listener, false).await;
        assert_eq!(level, SecurityImpersonation, "反证：不带 SQOS 的默认连接");
    }

    /// 同步版本走同一个打开函数；连不存在的管道得到 NotFound（调用方据此说「服务没在跑」）。
    #[test]
    fn pipe_client_sync_connect_reports_missing_pipe_as_not_found() {
        let err = connect_identification_sync(&unique("missing")).expect_err("没有这个管道");
        assert_eq!(err.kind(), io::ErrorKind::NotFound, "{err:?}");
    }

    /// 主人记录：往返、同一主人重写幂等、换主人被拒、坏内容是 Err 不是「没有主人」。
    #[test]
    fn the_owner_record_is_write_once() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("owner");
        assert_eq!(read_owner_at(&path).unwrap(), None);
        write_owner_at(&path, &me()).unwrap();
        assert_eq!(read_owner_at(&path).unwrap(), Some(me()));
        write_owner_at(&path, &me()).expect("同一主人重写是幂等的");
        assert!(write_owner_at(&path, STRANGER).is_err(), "不许换主人");
        assert_eq!(read_owner_at(&path).unwrap(), Some(me()));
        std::fs::write(&path, b"not a sid").unwrap();
        assert!(read_owner_at(&path).is_err(), "坏内容必须是 Err");
    }
}
