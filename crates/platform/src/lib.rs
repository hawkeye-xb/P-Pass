//! Platform — PlatformAdapter trait + Windows/macOS implementations
//! (T-040, 架构 §4 原样实施).
//!
//! Architecture enforcement: this is the ONLY crate allowed to use
//! `#[cfg(windows)]` / `#[cfg(target_os = "macos")]` (rule B.2).
//!
//! The pure parser (`pmset` output → [`PowerHint`]) is a
//! platform-independent function so it is unit-tested everywhere;
//! only the syscall/process wrappers live behind cfg.

// DESK-33 (#325)：clippy.toml 禁止产品代码直接 `Command::new`；单元测试
// 里的子进程（拉起测试二进制自身等）不面向用户，统一放行。
#![cfg_attr(test, allow(clippy::disallowed_methods))]

use std::path::{Path, PathBuf};

// DESK-24 (#173)：数据目录搬家。整个模块**不在 cfg 里**——里面全是
// `rename` / `read_dir`，没有一行平台专属代码，三条 lane 都跑得到它的测试。
// 只有 Windows 有遗留位置要搬，那部分知识在 `windows.rs`。
//
// 那也正是这条 `allow` 的由来：**今天只有 `windows.rs` 调它**，所以在别的
// 平台上整个模块的函数都没有调用方，`clippy -D warnings` 会报 8 条
// `is never used`。本地 `just ci` 跑在 Windows 上看不见，远端 Linux lane 上
// 必红（PR #368 实测）。
//
// 不改成 `pub mod` 让它「有调用方」：那是拿扩大公开 API 去换一条 lint 闭嘴。
// 这个模块是平台内部的管道，不该被 daemon / 桌面壳绕过适配器直接调。
// 只在非 Windows 上放行，Windows 那边的死代码照样挡得住。
#[cfg_attr(not(windows), allow(dead_code))]
mod data_migration;

// 三个平台都编译并跑单测；只有 Windows 的更新路径会调用它。
#[cfg_attr(not(windows), allow(dead_code))]
mod pe_version;

// #1121：代码签名要求（安装更新前校验团队；#1115 的 IPC 对端校验共用要求串）。
mod code_signature;
// #1109：身份私钥存取端口（不在 cfg 里，daemon 的判定与单测三平台都跑）。
mod identity_key;
// D6 / brief 5.6：Windows Hello 挑战的一次性/过期/绑定校验（纯逻辑）。
mod hello_challenge;
pub use hello_challenge::{ChallengeStore, HelloError};
// #1115：本机 IPC 对端身份（macOS 按 audit token + 代码签名；其他平台明确「不支持」）。
mod local_peer;
// #1109：macOS 的身份私钥存放处——data protection 钥匙串。
#[cfg(target_os = "macos")]
mod keychain;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
mod macos_unmount;
#[cfg(target_os = "macos")]
mod sealed_version;
// QA-09 迁移（#211）：macOS 与 Linux 共享的 unix 实现。迁过来的分叉里有
// 3 处是 `#[cfg(unix)]`（同时覆盖两者），没有共享模块就得抄两遍。
mod signal;
#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
mod windows_unmount;
// #1151：应用内更新的大小 / 总时长上限（纯逻辑，三平台都跑单测）。
pub mod update_limits;
// §5.1 / #1238：服务形态「要不要运行」的开关文件（纯文件读写，三平台都跑单测）。
pub mod stop_switch;
// D1 / brief §5.1：SCM 服务托管（查询、起停、注册/删除、给主人授权）。
#[cfg(windows)]
pub mod windows_service;

// #1157：D4 / §5.2 的 ProgramData 正本存放与目录 ACL 基础件。
#[cfg(windows)]
pub mod windows_programdata;
#[cfg(windows)]
pub use windows_programdata::{ProgramDataDir, ProgramDataStore};
// #1167：常驻 daemon 的命名管道（按用户 SID 认人）与主人记录。
#[cfg(windows)]
pub mod windows_pipe;
// §5.3：照片库目录设为私有并授权给服务账户（壳在主人身份下设 DACL）。
#[cfg(windows)]
pub mod windows_photo_dir;
#[cfg(windows)]
pub use windows_photo_dir::{list_modify_sids, make_private_for_service, GrantOutcome};
// 服务令牌特权：白名单与核对口径（纯逻辑，三平台都跑单测）；读令牌只在 Windows。
pub mod service_privileges;
pub use service_privileges::{
    judge_service_privileges, ServicePrivilegeVerdict, FORBIDDEN_SERVICE_PRIVILEGES,
    SERVICE_PRIVILEGE_ALLOWLIST,
};
#[cfg(windows)]
pub mod windows_token;

/// 托管方（Windows SCM）要求本进程以「系统服务」方式运行。
///
/// `body` 在服务线程上执行并返回进程退出码。返回 `Ok(true)` = 走的是服务路径；
/// `Ok(false)` = 不是服务上下文（控制台、桌面壳 shell-out），照常往下跑。
/// 非 Windows 平台没有这个托管方，永远 `Ok(false)`。
/// 服务模式下的启动日志（Windows 写到 `%ProgramData%\P-Pass\logs\daemon-boot.log`）。
/// 别的平台是 no-op。
pub fn service_boot_log(msg: &str) {
    #[cfg(windows)]
    windows_service::boot_log(msg);
    #[cfg(not(windows))]
    let _ = msg;
}

pub fn run_as_service(body: impl FnOnce() -> i32 + Send + 'static) -> Result<bool> {
    #[cfg(windows)]
    {
        // D4 / brief §5.2：服务启动的第一件事是核对 %ProgramData%\P-Pass 的 ACL。
        // 不通过就拒绝启动（SCM 记 7000），绝不回退到用户目录、也不重建目录——
        // 目录只有提权的安装器能建，daemon 擅自重建就等于把 ACL 决定权交给
        // 一个可能已被篡改的环境。
        windows_service::run_service_dispatcher(move || {
            match windows_programdata::verify_service_root() {
                Ok(root) => {
                    service_boot_log(&format!("ProgramData 目录核对通过：{}", root.display()));
                }
                Err(e) => {
                    service_boot_log(&format!("启动失败：ProgramData 目录核对不通过：{e}"));
                    eprintln!("启动失败：ProgramData 目录核对不通过：{e}");
                    return 1;
                }
            }
            // 令牌特权核对（与目录核对同一模式）：安装器用 `sc privs` 收窄过特权，
            // 令牌里仍带禁止特权 = 收窄没生效，拒绝启动；白名单外的其余特权写日志。
            match windows_token::verify_service_token() {
                Ok(v) if v.unexpected.is_empty() => {
                    service_boot_log("服务令牌特权核对通过");
                }
                Ok(v) => {
                    service_boot_log(&format!(
                        "服务令牌特权核对通过，但带有白名单外的特权：{}",
                        v.unexpected.join(", ")
                    ));
                }
                Err(e) => {
                    service_boot_log(&format!("启动失败：{e}"));
                    eprintln!("启动失败：{e}");
                    return 1;
                }
            }
            body()
        })
    }
    #[cfg(not(windows))]
    {
        let _ = body;
        Ok(false)
    }
}

/// D4：本进程是否正被系统服务管理器当作服务托管（Windows SCM）。
///
/// 唯一的用途是让适配器把数据根从用户的 `%LOCALAPPDATA%` 切到
/// `%ProgramData%\P-Pass`——服务账户读不到交互用户的任何用户级路径。
/// 别的平台永远 `false`（它们没有这个「服务账户 ≠ 用户」的形态）。
/// #639：这次改名失败是不是因为新旧位置不在同一个卷上（unix `EXDEV`、Windows
/// `ERROR_NOT_SAME_DEVICE`）——是的话调用方改走「拷贝、核对、再改名」。
pub fn is_cross_volume_rename(e: &std::io::Error) -> bool {
    #[cfg(unix)]
    {
        e.raw_os_error() == Some(libc::EXDEV)
    }
    #[cfg(windows)]
    {
        e.raw_os_error() == Some(17) // ERROR_NOT_SAME_DEVICE
    }
}

/// #639：两个已存在的路径在不在同一个卷上（同卷搬迁是一次改名，不占新空间）。读不出来 ⇒ `None`。
pub fn same_volume(a: &Path, b: &Path) -> Option<bool> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        Some(std::fs::metadata(a).ok()?.dev() == std::fs::metadata(b).ok()?.dev())
    }
    #[cfg(windows)]
    {
        let va = windows_volume_root(a)?;
        let vb = windows_volume_root(b)?;
        Some(va.eq_ignore_ascii_case(&vb))
    }
}

#[cfg(windows)]
fn windows_volume_root(p: &Path) -> Option<String> {
    use std::os::windows::ffi::OsStrExt as _;
    use windows_sys::Win32::Storage::FileSystem::GetVolumePathNameW;
    let w: Vec<u16> = p
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let mut buf = [0u16; 1024];
    // SAFETY: w 以 0 结尾；buf 是可写缓冲，长度如实给出。
    let ok = unsafe { GetVolumePathNameW(w.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) };
    if ok == 0 {
        return None;
    }
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(String::from_utf16_lossy(&buf[..end]))
}

/// #639：`p` 在不在网络盘（SMB / NFS / AFP 等非本地卷）上。推出审批与根目录监听在网络盘上不可靠，
/// 照片库这一版不放上去。读不出来按「不是」——调用方另有空间与可写检查兜底。
pub fn is_network_volume(p: &Path) -> bool {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt as _;
        let Ok(c) = std::ffi::CString::new(p.as_os_str().as_bytes()) else {
            return false;
        };
        let mut st: libc::statfs = unsafe { std::mem::zeroed() };
        // SAFETY: c 是合法 C 字符串，st 可写。
        if unsafe { libc::statfs(c.as_ptr(), &mut st) } != 0 {
            return false;
        }
        (st.f_flags & libc::MNT_LOCAL as u32) == 0
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        use std::os::unix::ffi::OsStrExt as _;
        let Ok(c) = std::ffi::CString::new(p.as_os_str().as_bytes()) else {
            return false;
        };
        let mut st: libc::statfs = unsafe { std::mem::zeroed() };
        // SAFETY: c 是合法 C 字符串，st 可写。
        if unsafe { libc::statfs(c.as_ptr(), &mut st) } != 0 {
            return false;
        }
        // NFS、SMB、CIFS、SMB2（statfs(2) 的 f_type 魔数）。
        #[allow(clippy::unnecessary_cast)]
        let kind = st.f_type as i64;
        matches!(kind, 0x6969 | 0x517B | 0xFF53_4D42 | 0xFE53_4D42)
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt as _;
        use windows_sys::Win32::Storage::FileSystem::GetDriveTypeW;
        let Some(root) = windows_volume_root(p) else {
            return false;
        };
        let w: Vec<u16> = std::ffi::OsStr::new(&root)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        // SAFETY: w 以 0 结尾。DRIVE_REMOTE = 4。
        unsafe { GetDriveTypeW(w.as_ptr()) == 4 }
    }
}

/// Windows 上 [`copy_dir_contents`] 把文件链接拷成指向文件的内容（见它的 `/XJD` 说明）；
/// 核对拷贝结果时据此放宽。
pub const COPY_MAY_MATERIALIZE_FILE_LINKS: bool = cfg!(windows);

/// 让目录项（新建 / 改名）落到介质上。POSIX 要对目录 fsync；Windows 没有目录 fsync，
/// NTFS 的元数据由日志保证，直接返回。
pub fn sync_dir(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        std::fs::File::open(dir)?.sync_all()
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        Ok(())
    }
}

/// #639：把目录 `src` 里的全部内容拷进 `dst`（`dst` 不存在就建），用各平台自带、久经验证的工具，
/// 不手写递归：
/// - macOS：`ditto <src> <dst>`——保留符号链接、硬链接、扩展属性（含 Finder 标签）、ACL、资源分叉。
///   不加 `--noqtn` / `--noacl`：搬迁与在 Finder 里拖过去一样原样保留元数据（隔离标记对照片无害，
///   去掉反而改了用户的数据）；目标卷不支持 ACL 时 ditto 照常复制数据。
/// - Windows：`robocopy <src> <dst> /E /COPY:DAT /DCOPY:DAT /XJD /R:2 /W:1 /NP /NFL /NDL /NJH /NJS`
///   ——子目录含空目录、数据 + 属性 + 时间、目录时间、跳过目录 junction / 链接、被占用重试 2 次。
///   文件链接按指向文件的内容拷过去：不加 `/SL`，因为照搬链接要「建符号链接」特权，普通用户与服务账户
///   没有，robocopy 会对每个链接报 ERROR 1314 并整体失败；用 `/XJD` 而不是 `/XJ`（后者连文件链接一起跳过）。
///   不加 `/Z`：那是为网络传输设计的断点续传，本地盘之间明显更慢；中断后整次重跑时 robocopy 默认
///   跳过大小与时间都相同的文件，已能接着拷。长路径 robocopy 原生支持。退出码 0–7 成功，≥ 8 失败。
/// - 其它 unix：`cp -a <src>/. <dst>/`。
pub fn copy_dir_contents(src: &Path, dst: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dst)?;
    #[cfg(target_os = "macos")]
    let out = command("ditto").arg(src).arg(dst).output()?;
    #[cfg(windows)]
    let out = command("robocopy")
        .arg(src)
        .arg(dst)
        .args([
            "/E",
            "/COPY:DAT",
            "/DCOPY:DAT",
            "/XJD",
            "/R:2",
            "/W:1",
            "/NP",
            "/NFL",
            "/NDL",
            "/NJH",
            "/NJS",
        ])
        .output()?;
    #[cfg(all(unix, not(target_os = "macos")))]
    let out = command("cp")
        .arg("-a")
        .arg(src.join("."))
        .arg(format!("{}/", dst.display()))
        .output()?;
    let code = out.status.code();
    #[cfg(windows)]
    let ok = matches!(code, Some(0..=7));
    #[cfg(not(windows))]
    let ok = code == Some(0);
    if ok {
        Ok(())
    } else {
        Err(std::io::Error::other(format!(
            "复制工具失败（退出码 {code:?}）：{}",
            String::from_utf8_lossy(&out.stderr).trim()
        )))
    }
}

pub fn service_mode_active() -> bool {
    #[cfg(windows)]
    {
        windows_service::is_running_as_service()
    }
    #[cfg(not(windows))]
    {
        false
    }
}
// #287：只给测试用的建链能力。默认不编译，见该模块顶部说明。
#[cfg(feature = "test-support")]
pub mod test_support;

#[cfg(target_os = "macos")]
pub use code_signature::verify_app_bundle;
pub use code_signature::{
    code_requirement, newer_than_current, verify_update_package, UpdatePackageCheck, DAEMON_APP_ID,
    DESKTOP_APP_ID, DEVELOPER_TEAM_ID,
};
pub use data_migration::DataDirMigration;
pub use identity_key::{IdentityKeyHome, IdentityKeyStore, SecretBlobStore};
pub use local_peer::{
    bind_resident_pipe, connect_resident_pipe, connect_resident_pipe_tokio, local_peer_user,
    peer_check_needs_first_message, verify_local_peer, verify_local_peer_min_version,
    LocalPeerSource, PeerCheck, PeerRole, PeerUser,
};

/// #1115：常驻 daemon 的本机 IPC 形态（[`PlatformAdapter::resident_ipc`]）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResidentIpc {
    /// 命名空间端点（`ppf-<NodeId 前 8 位>`）+ 令牌文件。只剩测试沙盒与无桌面的
    /// headless 平台（Linux 服务器）在用；桌面平台的常驻 daemon 都不再写令牌文件。
    NamespacedWithToken,
    /// 这个路径上的 Unix 域套接字（父目录 0700），按对端代码签名认证，没有令牌。
    SignedSocket(std::path::PathBuf),
    /// #1167：Windows 命名管道（名字不带 `\\.\pipe\` 前缀），按 **Windows 用户 SID**
    /// 认人（D5：按用户认，不按程序认），没有令牌。管道由 [`bind_resident_pipe`] 建：
    /// DACL 只放白名单 SID、拒绝远程、首实例独占；连上后双方再按 SID 核对一次
    /// （[`verify_local_peer`]）。
    UserPipe(String),
}

/// #1167：常驻 daemon「服务谁」（主人模型，D3）。
///
/// 只有 Windows 服务形态有这回事：服务是整台机器一份，第一个完成首启向导的用户成为
/// 主人，之后管道只对主人开放。别的形态（macOS / 计划任务 / headless）daemon 本来就
/// 跑在用户自己名下，答 [`ResidentOwner::NotApplicable`]。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResidentOwner {
    /// 本形态没有主人模型。
    NotApplicable,
    /// 还没有主人：daemon 只能停在未配置状态，管道对本机交互用户开放、只答配置方法。
    Unclaimed,
    /// 已有主人（SID 字符串）。管道只对主人 + 服务自己开放。
    Claimed(String),
}
pub use signal::{stop_signal, StopRequest};

#[cfg(target_os = "macos")]
pub use macos::MacosAdapter;
#[cfg(windows)]
pub use windows::WindowsAdapter;

/// How the daemon stays resident on this platform (§4 对照表).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceMode {
    /// User-level autostart only: started at login, nothing restarts it
    /// after a crash, and nothing can be asked to (re)start it now.
    UserAutostart,
    /// LaunchAgent with KeepAlive (crash-restart built in).
    LaunchAgent,
    /// DESK-65 (#957)：每用户计划任务——登录触发 + 每分钟看门狗（已在跑就
    /// 跳过）。和 LaunchAgent 一样由系统托管：开机启动、崩溃拉起、按需
    /// 立即拉起、撤销登记后不再拉起。
    ScheduledTask,
    /// D1 / #1161：Windows 系统服务（SCM）——per-machine 安装、以虚拟服务账户
    /// `NT SERVICE\<服务名>` 运行、开机即起（不等登录）、失败自动重启。
    ///
    /// 与 [`ServiceMode::ScheduledTask`] 的区别不只是「谁拉起」：服务的身份是
    /// 服务账户（不是用户），身份私钥、配对白名单、库位置才能放进
    /// `%ProgramData%` 只给服务读。计划任务跑在用户会话里，做不到这一点。
    WindowsService,
}

impl ServiceMode {
    /// 常驻 daemon 是否由**系统的服务管理器**托管（launchd / 任务计划程序）。
    ///
    /// 桌面壳的业务流程（启动、停止、自愈、更新后恢复、重启服务）只看这一位，
    /// 不认具体是哪种机制——机制是平台的事（依赖倒置）。为 `true` 时平台必须
    /// 实现 [`PlatformAdapter::resident_daemon_pid`] 与
    /// [`PlatformAdapter::restart_resident_daemon`]。
    pub fn has_service_manager(self) -> bool {
        match self {
            ServiceMode::UserAutostart => false,
            ServiceMode::LaunchAgent | ServiceMode::ScheduledTask | ServiceMode::WindowsService => {
                true
            }
        }
    }

    /// 常驻 daemon 的身份是不是**服务账户**（不是登录用户）。
    ///
    /// 为 `true` 时身份私钥、配对白名单、库位置只给服务账户读，daemon 只能由服务管理器
    /// 以服务账户拉起；桌面壳**绝不能**以用户身份另起一份 daemon 兜底——那份读不到服务的
    /// 状态，还会抢注服务的 IPC 端点（#1161 / #1167）。其余形态 daemon 与用户同一身份，
    /// 服务管理器接不了手时一次性拉起仍是可用的退路。
    pub fn daemon_runs_as_service_account(self) -> bool {
        matches!(self, ServiceMode::WindowsService)
    }
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
///
/// NET-26 (#419)：guard 是 `Send` 的，可以在**任意线程**上 drop——daemon
/// 在 tokio 多线程 runtime 的一个 worker 上拿、在另一个 worker 上放。各平台
/// 实现必须保证这一点（Windows 的线程级执行状态因此由专属线程持有）。
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

// Compile-time proof of the `Send` contract documented on `AwakeGuard`.
const _: fn() = || {
    fn assert_send<T: Send>() {}
    assert_send::<AwakeGuard>();
};

/// DAE-11 (#804)：[`PlatformAdapter::watch_external_power`] 的订阅句柄，
/// drop 即退订。和 [`AwakeGuard`] 一样只靠 `Drop` 起作用，可在任意线程 drop。
pub struct PowerWatch {
    #[allow(dead_code)] // the handle's Drop is the whole point
    inner: Box<dyn Send>,
}

impl PowerWatch {
    /// 各平台实现把自己的退订 guard 装进来。`pub` 而不是 `pub(crate)`：只有
    /// 实现了订阅的平台才调它，`pub(crate)` 在其余平台上会被判成未使用代码。
    pub fn new(inner: impl Send + 'static) -> Self {
        Self {
            inner: Box::new(inner),
        }
    }
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

/// 内置 daemon 可执行文件的基名（不含平台扩展名）。
///
/// QA-09 迁移（#211）：迁移前这个字符串在桌面壳 `lib.rs` 里被
/// `if cfg!(windows) { "ppf-daemon.exe" } else { "ppf-daemon" }` **抄了三遍**。
pub const DAEMON_EXECUTABLE_STEM: &str = "ppf-daemon";

/// 杀 daemon 进程的结果。
///
/// QA-09 迁移（#211）：**「进程本来就没在跑」不是错误**，是一种正常结果。
/// 各系统表达它的方式不同（unix 的 `pkill` 用退出码 1；Windows 原来是
/// `taskkill` 的 128，DESK-52 #787 起改为进程快照里没有匹配项），而迁移前这条知识被抄散在三个调用点上，其中两处直接
/// `let _ = ...` 把结果丢了。DESK-25 (#208) 就是因为**另一处**没看退出码、
/// 把「没杀掉」当成杀成功、紧接着去 spawn 第二个 daemon 才出的事。
///
/// 收进这个枚举之后判据只有一份：真失败（权限不足、被杀软拦、参数错）
/// 才是 `Err`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KillOutcome {
    /// 进程在，已经杀掉了。
    Killed,
    /// 进程本来就没在跑。
    NotRunning,
}

/// DAE-05：卷容量水位（`free` 对齐 unix `statvfs` 的 `f_bavail` 语义）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VolumeStats {
    pub free: u64,
    pub total: u64,
}

/// #1043：电脑睡眠由谁负责（[`PlatformAdapter::sleep_owner`]）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SleepOwner {
    /// 由用户在系统里设置（macOS：向导请用户关掉「空闲自动睡眠」，可一键代改）。
    User,
    /// daemon 自动保持唤醒（Windows：DAE-11 插电时持有 AwakeGuard），向导只说明。
    Daemon,
}

impl SleepOwner {
    /// 下发给前端的取值（`platform_ux` 命令）。
    pub fn as_str(self) -> &'static str {
        match self {
            SleepOwner::User => "user",
            SleepOwner::Daemon => "daemon",
        }
    }
}

/// #1043：daemon 日志落在哪（[`PlatformAdapter::daemon_log_paths`]）。
///
/// 路径是「应该在哪」，不保证文件已存在——读的一方自己处理读不到。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DaemonLogPaths {
    /// daemon 自己写的运行日志（tracing；`PPF_LOG_FILE` 未设时）。`None` =
    /// 本平台不落盘。
    pub log_file: Option<PathBuf>,
    /// 启动早期 stderr 的落点（文件日志之前的报错、`main` 返回的 `Err`、panic），
    /// 尾行就是「为什么没起来」。
    pub stderr: Option<PathBuf>,
    /// 托管方接住的 stdout。
    pub stdout: Option<PathBuf>,
    /// `stdout`/`stderr` 是不是**服务管理器**接的（macOS launchd 的
    /// `StandardOutPath`/`StandardErrorPath`）：是 = 只有登记了常驻服务、由它
    /// 拉起的实例才写这两份；否 = daemon 自己接（Windows 的 `logs\daemon.err`，
    /// 见 [`PlatformAdapter::capture_unattached_stderr`]）。
    pub stdio_by_service_manager: bool,
}

/// DESK-16 (#165)：系统缩略图器产出的一帧，**未编码的 RGBA 像素**。
///
/// 为什么不返回「写好的 PNG 文件路径」：那样本 crate 就得带一个图像编码
/// 器，而编码能力已经在 `crates/media-codec`（`image` 依赖）里了。让本
/// crate 只做「调系统 API 取像素」这一件事，编码留给调用方 —— 分层更干净，
/// 也省掉一次落盘再读回。
///
/// `rgba` 的长度**必须**等于 `width * height * 4`；构造方负责保证，调用方
/// 可以据此直接喂给 `image::RgbaImage::from_raw`。
#[derive(Debug, Clone)]
pub struct SystemThumbnail {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
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

/// §5.3 / #1159：[`PlatformAdapter::grant_library_dir`] 的结果口径。
///
/// 与 [`Applied`] 同一个道理：`Ok(())` 会把「这台机器的卷根本没有 ACL、
/// 我们什么都没做」说成授权完成，而备份到那时才发现服务读不了目录。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryDirGrant {
    /// 本平台 / 本安装形态不做这件事：Linux（无桌面形态），旧的每用户计划任务
    /// （跑在用户会话里，与用户同一主体）。
    NotApplicable,
    /// 库目录已设为私有（已回读确认）：Windows 服务形态是受保护 DACL（主人、服务账户、
    /// SYSTEM、Administrators），macOS 是 `0700`。
    Granted,
    /// 卷本身没有权限可设（FAT / FAT32 / exFAT，macOS 上忽略所有权的卷），跳过、不提示。
    SkippedNoAcl { file_system: String },
}

/// 【DESK-42 #604】开机自启登记的对账结果。
///
/// 为什么不能只用 `bool`：`false` 会把「本来就没登记」和「登记正确、不用动」
/// 混成一件事——这正是本卡要修的缺陷形状（登记路径漂移后没人发现）。变体各自可断言，
/// 日志也能说清到底发生了什么。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutostartReconcile {
    /// 本来就没有登记：**不动**（纯新启动不得篡改用户的开机自启配置，DAE-03 ②）。
    NotRegistered,
    /// 已登记且指向期望路径：不动。
    Unchanged,
    /// 已登记但指向别处（换目录 / 更新 / 从临时或备份副本注册过）：已用期望路径重写。
    Rewritten,
    /// 【#726】登记条目在，但读不出目标路径（写了一半 / 被改坏）：已用期望路径重写。
    ///
    /// 与 `Rewritten` 分开：日志要能说清是「修好了一个坏文件」还是「改了一个旧路径」。
    Repaired,
    /// #1046：登记指向期望路径，但条目的其余内容不是本版本会写出的样子（例如
    /// macOS 老版本 plist 的日志落点还在 `~/Library/Logs`）：已按本版本重写。
    ///
    /// 这是「自启重新登记」的职责（S-11，原先由 daemon 接管时重装）：更新后由新壳
    /// 启动对账收敛到本版本的登记内容。只在内容真的不同时才写，一致后幂等。
    Refreshed,
    /// **闸门拦下**：当前可执行文件不在「稳定安装位置」（dmg 挂载点 / 下载目录 /
    /// App Translocation 随机路径 / 备份副本 …），一律不碰登记。
    ///
    /// 为什么单列一个变体：这是「我们**故意**没动」而不是「没有需要动的」——
    /// 静默跳过会让闸门失效时没人发现（外部评审 2026-10-01 在 PR #611 上拦下的
    /// 正是「不判位置就静默改名」这件事）。
    SkippedUnstableLocation,
}

/// 【#726】登记条目的三种状态。
///
/// 为什么不用 `Option<PathBuf>`：`None` 会把「没登记」和「登记文件坏了」混成一件事——
/// 前者不许动（DAE-03 ②），后者必须重写，否则每次开机服务都起不来、且不会自己好。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutostartRegistration {
    /// 没有登记条目（用户没开自启，或已关掉）。
    Absent,
    /// 有登记条目，但读不出目标路径。
    Unreadable,
    /// 登记指向这个可执行文件。
    At(std::path::PathBuf),
}

/// 【DESK-42 #604】对账决策（纯函数——各分支由单测钉死）。
///
/// 缺陷现场：登记被钉在 `~/P-Pass-Backups/<日期>/old-app/P-Pass.app/...`，
/// 而实际安装的 App 在 `/Applications`——没登记/指向自己/指向别处/读不出四种情形
/// 必须能被分开判定，否则「漂移」永远只是静默的旧值。
pub fn reconcile_decision(
    registered: &AutostartRegistration,
    expected: &std::path::Path,
) -> AutostartReconcile {
    match registered {
        AutostartRegistration::Absent => AutostartReconcile::NotRegistered,
        AutostartRegistration::Unreadable => AutostartReconcile::Repaired,
        AutostartRegistration::At(p) if p == expected => AutostartReconcile::Unchanged,
        AutostartRegistration::At(_) => AutostartReconcile::Rewritten,
    }
}

/// 「平台能力」端口（#1043 / S-9）：回答「在这个系统上怎么做」——数据目录、
/// 防休眠、通知、卷空间、日志落点、系统缩略图、壳的界面习惯等。
///
/// daemon 与其他核心 crate **只依赖这个 trait**（经 [`adapter`] 拿实现）。
/// 托管类能力（开机自启、服务管理器、结束进程、安装位置）在 [`HostingAdapter`]，
/// 只给桌面发行层用；门禁 G3 拦 `crates/` 引用它。两个 trait 的实现都留在本 crate。
/// #1118：[`PlatformAdapter::computer_name`] 的 POSIX 默认实现。
fn posix_hostname() -> Option<String> {
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        // SAFETY: 缓冲区在本栈上、长度如实传入；POSIX 允许截断时不带 NUL，所以末字节留作 NUL。
        let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len() - 1) };
        if rc != 0 {
            return None;
        }
        let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        clean_computer_name(&String::from_utf8_lossy(&buf[..end]))
    }
    #[cfg(not(unix))]
    {
        None
    }
}

/// #1118：系统给的名字去掉首尾空白，空串算读不到。
pub fn clean_computer_name(raw: &str) -> Option<String> {
    let t = raw.trim();
    (!t.is_empty()).then(|| t.to_owned())
}

pub trait PlatformAdapter: Send + Sync {
    // 电源（MVP 尽力而为）
    fn assert_awake(&self) -> Result<AwakeGuard>;
    /// 当前睡眠策略（给 macOS 向导第 2 步用）。**默认 `Unknown`**：Windows 向导
    /// 不展示睡眠策略（DAE-11 起由 daemon 的 AwakeGuard 自动保持唤醒），#1041 起
    /// Windows 不再实现，这里的默认值就是它的行为。
    fn power_hint(&self) -> PowerHint {
        PowerHint::Unknown
    }
    // 系统集成
    fn notify(&self, title: &str, body: &str);

    /// #1253：盯住照片库根目录**本身**——它被删除、改名 / 挪走，或所在的卷被卸载（拔盘、强制推出）时，
    /// 在后台线程里调用一次 `on_gone`。目录里的文件变化不算（那是目录监听的事）。
    ///
    /// 返回 `false` = 本平台没有这项能力（**默认**），调用方只能靠启动检查与删除前核对库标记兜底。
    /// macOS 用 kqueue `EVFILT_VNODE`（`NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE`），目录以 `O_EVTONLY`
    /// 打开——只为收事件，不算占用，不会挡住卷的推出。
    fn watch_library_root(&self, _root: &Path, _on_gone: Box<dyn FnOnce() + Send>) -> bool {
        false
    }

    /// #1260：用户推出照片库所在的卷之前先问我们。系统卸载之前在后台线程里调用 `prepare`
    /// （阻塞；调用方负责给它设上限），它返回后放行卸载——用来取消在途传输、等库盘上的文件
    /// 关掉，推出就不会「磁盘正在使用」。只放行、从不拒绝用户的推出。
    ///
    /// 返回 `false` = 本平台没有这项能力（**默认**）。macOS 用 DiskArbitration 卸载审批回调。
    fn approve_library_unmount(&self, _root: &Path, _prepare: Box<dyn Fn() + Send + Sync>) -> bool {
        false
    }
    /// 本平台**生效的**数据目录。
    ///
    /// DESK-24 (#173)：Windows 上这个值不是常量——`%APPDATA%`（Roaming）时代
    /// 的老目录只要还在，返回的就是它，搬完了才换成新位置。这样「搬迁失败」
    /// 退化成「保持原样」，而不是指着一个空目录（见 [`DataDirMigration`]）。
    /// 想真正换过去，调用方得先调 [`Self::migrate_legacy_data_dir`]。
    fn data_dir(&self) -> PathBuf;

    /// #1043（B6）：系统界面语言（BCP 47 风格的标签，如 `zh-Hans-CN`、`en-US`）。
    /// `None` = 读不到。
    ///
    /// 只回答「系统是什么语言」，不做「用不用中文」的判断——那是调用方（壳）
    /// 的事。macOS 读 NSLocale 的首选语言（`CFLocaleCopyPreferredLanguages`），
    /// Windows 读 `GetUserPreferredUILanguages` 的首个（界面语言，不是区域格式，#1056）。
    /// 默认实现按 POSIX 约定读 `LC_ALL` → `LC_MESSAGES` → `LANG`（无桌面的 Linux）；`C`/`POSIX` 算读不到。
    fn system_locale(&self) -> Option<String> {
        posix_env_locale(
            std::env::var("LC_ALL").ok().as_deref(),
            std::env::var("LC_MESSAGES").ok().as_deref(),
            std::env::var("LANG").ok().as_deref(),
        )
    }

    /// #1043（B10）：当前用户的家目录。`None` = 读不到（不编一个出来）。
    ///
    /// 用标准库的 `std::env::home_dir`：unix 先 `HOME` 再查 passwd，Windows 先
    /// `USERPROFILE` 再 `GetUserProfileDirectoryW`——与改前壳 / daemon 各自读
    /// `HOME`→`USERPROFILE` 的取值一致，测试用环境变量隔离家目录的做法照样
    /// 有效。壳与 daemon 不许自己读这些环境变量（门禁 G1）。
    fn home_dir(&self) -> Option<PathBuf> {
        std::env::home_dir().filter(|p| !p.as_os_str().is_empty())
    }

    /// #1118：这台电脑在系统里的名字（用户在系统设置里起的那个），配对时给手机当作
    /// 方便辨认的标签。`None` = 读不到。可能含用户真名：调用方不得写进日志。
    ///
    /// macOS 读「电脑名称」（`SCDynamicStoreCopyComputerName`），Windows 读计算机名
    /// （`GetComputerNameExW`）。默认实现是 POSIX `gethostname`（无桌面的 Linux）。
    fn computer_name(&self) -> Option<String> {
        posix_hostname()
    }

    /// #1043（B10）：当前用户的「图片」目录——新建照片库默认放在它下面。
    ///
    /// 默认实现 = 家目录下的 `Pictures`（macOS / 多数 Linux 桌面）；Windows 走
    /// Known Folder（`FOLDERID_Pictures`），用户把「图片」挪到别的盘也认得出。
    fn pictures_dir(&self) -> Option<PathBuf> {
        self.home_dir().map(|h| h.join("Pictures"))
    }

    /// IDX-08 (#1010)：入库落盘文件名的**平台策略**。
    ///
    /// core 先把手机传来的名字去掉路径、做路径穿越兜底（最后一段、`.`/`..`、
    /// 空名），再把**那一段**交给这里。返回的名字只负责「在当前文件系统上合法」；
    /// `None` = 本平台没有额外规则（macOS / Linux 保持现状）。
    ///
    /// 为什么是能力而不是 core 里的 `#[cfg]`：合法名字的规则是平台知识
    /// （Windows 的非法字符、保留名、结尾点/空格），按架构红线只能住在
    /// `crates/platform`。返回函数指针而不是 `String` 策略对象，是为了让
    /// core 的 `Ingestor` 保持 `Clone`/轻量，且不需要把平台依赖传进核心层。
    fn ingest_file_name_sanitizer(&self) -> Option<fn(&str) -> String> {
        None
    }

    /// DESK-24 (#173)：把遗留位置的数据搬到 [`Self::data_dir`] 现在该在的地方。
    ///
    /// **在任何人读 data dir 之前调一次**，进程生命周期里一次就够。daemon 那边
    /// 还得排在日志初始化**之前**——日志文件路径本身就是从 data dir 算出来的。
    ///
    /// 不返回 `Result`：搬迁失败不得导致启动失败（卡面第 2 条），所以类型上
    /// 就没给出「炸掉」这个选项，失败表达成 [`DataDirMigration::Deferred`]。
    ///
    /// 默认实现 = 本平台**没有遗留位置这回事**（macOS 的 Application Support、
    /// Linux 的 XDG 目录当初就选对了）。这不是缺口。
    fn migrate_legacy_data_dir(&self) -> DataDirMigration {
        DataDirMigration::NothingToDo
    }
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

    /// DAE-11 (#804)：电脑此刻是否接着外部电源（插电）。
    ///
    /// 用途：daemon 运行且插电时一直持有「别因空闲而睡」的声明，拔电就释放、
    /// 照常睡（验收人 2026-10-10 拍板，只管插电）。没有电池的台式机算插电。
    ///
    /// `None` = 不知道（本平台没实现，或系统答不出来）。**不许**把不知道编成
    /// `Some(..)`：插电与否决定要不要阻止睡眠，猜错哪边都是用户可见的后果，
    /// 怎么处理「不知道」由调用方（daemon）定。默认实现是 `None`，与
    /// [`Self::installed_bundle_version`] 同一口径。
    fn on_external_power(&self) -> Option<bool> {
        None
    }

    /// DAE-11 (#804)：订阅「插电 / 用电池」的变化，**事件驱动，不轮询**。
    ///
    /// 登记成功后先以当前状态回调一次，之后每次电源切换再回调；入参口径同
    /// [`Self::on_external_power`]（`None` = 不知道）。回调在系统线程上跑，
    /// 必须快进快出。返回的 [`PowerWatch`] drop 即退订。
    ///
    /// 返回 `None` = 本平台不支持订阅（默认实现）。调用方据此**不做**常驻
    /// 保持唤醒——只拿一次快照的话，拔电后没人知道，会一直挡着睡眠耗电池。
    fn watch_external_power(
        &self,
        on_change: Box<dyn Fn(Option<bool>) + Send + Sync>,
    ) -> Option<PowerWatch> {
        let _ = on_change;
        None
    }

    /// #1043：daemon 日志的**全部落点**，一处回答（合并了原先的
    /// `default_log_file` 与 `startup_stderr_file`）。daemon 写、壳读（向导报
    /// 启动失败、诊断包、一次性 spawn 接 stdio）用的是这同一个函数，壳不再
    /// 读 launchd plist 反推路径。
    ///
    /// 入参是**生效的** data dir（由调用方解析 env / 平台约定后给出），
    /// 因为一次性 daemon 靠 `PPF_DATA_DIR` 做隔离，日志不跟着走就会污染
    /// 真实日志文件。
    ///
    /// 默认实现：`log_file` = `<data_dir>/logs/daemon.log`（macOS 与 Windows
    /// 同构，轮转出 `daemon.log.1`），没有托管方接的 stdio。
    /// - DEVLOG-02：Windows 必须有 `log_file`——计划任务没有任何
    ///   重定向能力，release 又不再分配控制台，不落盘就等于没有日志。
    /// - DIAG-B1：macOS 也要有——桌面壳有好几条一次性 spawn 路径把 stdio 接到
    ///   `/dev/null`，只靠 launchd 的 `StandardErrorPath` 时 0.6.0 的日志整段丢失。
    /// - 不落盘的平台（无桌面托管的 Linux）覆盖成 `log_file: None`。
    fn daemon_log_paths(&self, data_dir: &std::path::Path) -> DaemonLogPaths {
        DaemonLogPaths {
            log_file: Some(data_dir.join("logs").join("daemon.log")),
            ..DaemonLogPaths::default()
        }
    }

    /// 诊断导出脱敏时要原样保留的平台特有文件名（小写比较）。
    ///
    /// 脱敏器默认把未知文件名打码成 `<file>.ext`；平台自己的托管文件
    /// （如 macOS 的 LaunchAgent plist）名字固定、不含用户信息，排障要看，
    /// 由平台层声明，脱敏器不写死平台知识（#1011）。默认无。
    fn redaction_safe_file_names(&self) -> Vec<String> {
        Vec::new()
    }

    /// DIAG-B1：写 [`DaemonLogPaths::log_file`] 时是否**同时**照旧写
    /// stderr。macOS 为 true：launchd 托管时 stderr 是 `.err`，桌面向导读它的最后
    /// 一行报启动失败（DESK-09）。默认 false（Windows release 没有控制台可写）。
    fn default_log_tees_stderr(&self) -> bool {
        false
    }

    /// DESK-58 (#875)：本进程的 stderr **没人接**时，把它改接到
    /// [`DaemonLogPaths::stderr`]（每次启动截断重写）。
    ///
    /// 「没人接」只指：没有 stderr 句柄，或者接的是空设备（`NUL`）。控制台、
    /// 管道、磁盘文件都是有人**刻意**接的（终端前台、测试框架、手工重定向），
    /// 一律不动。默认实现 `NotApplicable`：别的平台由托管方负责 stderr。
    fn capture_unattached_stderr(&self, data_dir: &std::path::Path) -> Applied {
        let _ = data_dir;
        Applied::NotApplicable
    }

    /// #1109：daemon 身份私钥放在哪。默认 [`IdentityKeyHome::DataDirFile`]
    /// （数据目录里的 `.ppf/identity.key`，Windows / Linux 维持现状）；macOS
    /// 返回 data protection 钥匙串。
    fn identity_key_home(&self) -> IdentityKeyHome {
        IdentityKeyHome::DataDirFile
    }

    /// #1115：常驻 daemon 的本机 IPC 端点与认证方式。默认（Windows / Linux）是命名空间
    /// 端点 + 每次启动随机令牌（令牌文件在数据目录）；macOS 是仅本用户可访问目录里的
    /// Unix 域套接字，按对端代码签名认人，没有令牌。
    fn resident_ipc(&self) -> ResidentIpc {
        ResidentIpc::NamespacedWithToken
    }

    /// #1115：建一个只有本用户能进的目录（放 socket / 令牌用）。已存在则核对属主并收紧
    /// 权限，属主不是本用户就报错。默认实现：只建目录（Windows 的权限模型另议）。
    fn prepare_private_dir(&self, path: &std::path::Path) -> Result<()> {
        std::fs::create_dir_all(path).map_err(|source| PlatformError::Io {
            action: "prepare_private_dir",
            source,
        })
    }

    /// #1115：配对记录（设备白名单）正本放在哪。`None`（默认，Windows / Linux）
    /// = 库本身就是正本；macOS 返回钥匙串条目（与身份私钥同一访问组）。
    fn pairing_store(&self) -> Option<Box<dyn SecretBlobStore>> {
        None
    }

    /// #1115：照片库位置的正本放在哪。`None`（默认，Windows / Linux）= 平台 config.toml
    /// 就是正本；macOS 返回钥匙串条目——config.toml 谁都能改，库位置只认签名 daemon 写进
    /// 钥匙串的值，config.toml 那份只给人看。
    fn library_store(&self) -> Option<Box<dyn SecretBlobStore>> {
        None
    }

    /// #1238：daemon 写好 config.toml 之后，让窗口程序（交互用户）能**只读**它。
    ///
    /// 服务形态下 config.toml 在 `%ProgramData%\P-Pass`，目录私有，窗口程序读不到——判断不出
    /// 「配过没有」、找不到照片库，服务一停就被打回首启向导。文件里只有库位置（给人看的
    /// 副本，正本在 `library_store`）、监听地址、中继地址，没有秘密；写仍只有服务与管理员。
    /// 别的形态窗口程序与 daemon 是同一用户，`NotApplicable`。
    fn share_config_read(&self, config_file: &std::path::Path) -> Result<Applied> {
        let _ = config_file;
        Ok(Applied::NotApplicable)
    }

    /// §5.3 / #1159：把主人选的照片库目录设为**只有主人能访问**，并让常驻 daemon 能读写。
    ///
    /// 首次设置与换位置走这同一个入口，在把库位置交给 daemon **之前**由窗口程序以主人身份调。
    /// Windows 服务模式（D1）下 daemon 以 `NT SERVICE\P-Pass` 运行，和选目录的用户不是同一个
    /// 安全主体：受保护 DACL 只含主人、服务账户、SYSTEM、Administrators（服务账户自己没有
    /// 该目录的 `WRITE_DAC`，只能在主人身份下设）。macOS 的 daemon 与用户同一主体：库根目录
    /// `0700`。目录不存在时先建出来。
    ///
    /// 幂等。失败 = `Err`，调用方不得继续把这个目录交给 daemon。
    fn grant_library_dir(&self, dir: &std::path::Path) -> Result<LibraryDirGrant> {
        let _ = dir;
        Ok(LibraryDirGrant::NotApplicable)
    }

    /// §5.1 / #1161：「用户希望这个服务运行吗」。
    ///
    /// `Some(false)` = 用户在 App 里停过服务：daemon 启动后应当**直接成功退出**
    /// （服务管理器看到「正常停止」，不会重启）。`Some(true)` / `None` = 正常运行。
    /// 其他平台没有这个形态（macOS 的 stop 会把 launchd 作业 disable 掉）。
    fn service_wanted_state(&self) -> Option<bool> {
        None
    }

    /// #1167：常驻 daemon 的主人（见 [`ResidentOwner`]）。读不出来（文件在但读失败、
    /// 内容不是 SID）一律 `Err`——daemon 据此拒绝启动，不把「读不到」当成「没有主人」
    /// 而重新开放认领。
    fn resident_owner(&self) -> Result<ResidentOwner> {
        Ok(ResidentOwner::NotApplicable)
    }

    /// #1167：把这个连接方记成主人（首启向导写好库位置的那一刻调）。只有服务形态写盘
    /// （`%ProgramData%\P-Pass\owner`）；别的形态 `NotApplicable`。`peer` 为 `None`
    /// （拿不到连接方身份）在服务形态下是错误，绝不写一个空主人。
    fn claim_resident_owner(&self, peer: Option<&PeerUser>) -> Result<Applied> {
        let _ = peer;
        Ok(Applied::NotApplicable)
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
    /// 要走系统的授权弹窗（macOS 是 Touch ID/密码；Windows 的 UAC 实现随
    /// #1041 删除，Windows 向导不再提供这个入口），所以
    /// `Err(PlatformError::Cancelled)` 是**正常路径之一**，调用方必须把它和
    /// 真失败分开呈现。
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

    /// DESK-16 (#165)：向系统自带的缩略图器要一帧视频首帧。
    ///
    /// 这是回退链 `ffmpeg → 系统兜底` 里「系统兜底」那一环在**本 crate** 的
    /// 落点。两个平台的形态不对称，原因是系统能力不对称：
    ///
    /// - **macOS** 有 `/usr/bin/qlmanage` 这个 CLI，所以 `media-codec` 自己
    ///   探测那个固定路径就够了（`quicklook.rs`），**不经过本方法** —— 探测
    ///   一个 unix 路径不需要 cfg，那是它能待在 media-codec 里的原因。
    /// - **Windows** 没有对等的 CLI，只能走 COM（`IShellItemImageFactory`）。
    ///   COM 调用必然带 `#[cfg(windows)]`，而红线 B.2 要求平台 cfg 只许待在
    ///   本 crate —— 所以 Windows 那半必须从这里出去。
    ///
    /// `Ok(None)` = **本平台没有实现**（不是「这个文件没有缩略图」）。
    /// 真取不到缩略图返回 `Err`，让调用方能把「平台不支持」与「这个文件
    /// 失败了」分开 —— 混成一个 `None` 就又回到「静默降级说不清原因」。
    ///
    /// `max_px` 是最长边的**上界**，实现方不许放大（与 `qlmanage -s` 同义）。
    fn system_video_thumbnail(
        &self,
        src: &std::path::Path,
        max_px: u32,
    ) -> Result<Option<SystemThumbnail>> {
        let _ = (src, max_px);
        Ok(None)
    }

    // ── QA-09 迁移（#211）桌面壳批次 ─────────────────────────────
    //
    // 以下能力此前以 `#[cfg]` / `cfg!()` 的形式散在
    // `apps/desktop/src-tauri/src/lib.rs` 里（18 处）。搬过来之后调用点
    // 一个 cfg 不留，`tools/arch-check.sh` 对那个文件的整文件豁免因此
    // 可以删掉——那是本卡的销号条件。（#1043 起其中 `daemon_executable_name`、
    // 结束 daemon 进程两项归 [`HostingAdapter`]。）

    /// 这个系统的名字，喂给前端 `wizard_state` 的 json。
    ///
    /// **没有默认实现**：每个系统都有名字，编一个默认值只会在某天悄悄
    /// 把平台标错，而前端拿它决定显示哪套文案。
    fn platform_name(&self) -> &'static str;

    /// 这个系统「电源与睡眠」设置页的 URI；`None` = 没有可直接跳转的页面。
    ///
    /// 只给 URI，**不给「怎么打开」**。理由：
    ///
    /// 1. 本 crate 是 **daemon 也在用**的，而 daemon 不是 Tauri 应用——
    ///    把 `tauri_plugin_opener` 引进来是错的方向。
    /// 2. 另一条路是在这里手写 `ShellExecuteW`，那等于把 DESK-19 (#168)
    ///    刚修好的「不闪黑窗」用手写代码重做一遍，**有回归风险、换不来
    ///    任何好处**。opener 插件的候选命令条条带 `CREATE_NO_WINDOW`。
    ///
    /// 真正属于平台知识的是「这个系统的电源设置在哪」，不是「怎么打开一个
    /// URI」。后者是桌面壳（Tauri 层）的事。
    fn power_settings_uri(&self) -> Option<&'static str> {
        None
    }

    /// 托盘图标是不是「模板图标」（单色、随系统深浅色自动反色）。
    ///
    /// 这是 macOS 的习惯，所以默认 `false`——**默认值取的是多数派行为，
    /// 不是「不知道」**。命名上刻意不叫 `is_macos()`：那只是把 cfg 挪了个
    /// 地方，没有说出为什么要分叉。
    fn tray_icon_is_template(&self) -> bool {
        false
    }

    /// #1043：系统错误码 `code`（`std::io::Error::raw_os_error`）是不是「文件被
    /// 别的进程占着」——更新装不上时据此给用户一句能照做的话，而不是系统原文。
    ///
    /// 只回答系统错误码的含义，不匹配任何语言的错误文案。默认 `false`：只有
    /// Windows 有「文件被占用就不能覆盖」这回事。
    fn is_file_in_use_os_error(&self, code: i32) -> bool {
        let _ = code;
        false
    }

    /// #1043：关窗（藏到托盘）时要不要提示一次「还在后台运行」。
    ///
    /// 默认 `true`：Windows 用户普遍以为点 X 就是退出（#303），Linux 的 GNOME
    /// 默认没有托盘、不提示的话 App 关窗后就像「消失」了。macOS 覆盖成
    /// `false`——点红灯不退出在那儿是常态（#303 验收标准 3）。
    fn close_to_tray_hint(&self) -> bool {
        true
    }

    /// #1043：窗口标题栏是不是透明 Overlay（前端要自己放拖拽命中区）。
    /// `titleBarStyle: "Overlay"` 只在 macOS 生效，默认 `false` = 系统原生标题栏。
    fn overlay_titlebar(&self) -> bool {
        false
    }

    /// #1043：电脑睡眠由谁负责，决定首启向导第 2 步怎么讲、用哪份向导视图。
    ///
    /// `None` = 本平台没有桌面向导（Linux，#752）。默认 `None`。
    fn sleep_owner(&self) -> Option<SleepOwner> {
        None
    }

    /// 托盘左键是出菜单（macOS 习惯）还是开窗口（Windows / Linux 习惯）。
    ///
    /// DESK-18 (#167)：Windows 上左键出菜单与系统习惯相反。
    fn tray_shows_menu_on_left_click(&self) -> bool {
        false
    }
}

/// 「托管」端口（#1043 / S-9）：进程怎么被拉起、守护、开机自启，以及壳怎么被
/// 系统重启。只给桌面发行层（`apps/desktop`）用，经 [`hosting`] 拿实现；
/// 核心 crate 不许依赖（门禁 G3，见 `tools/arch-check.sh`）。
pub trait HostingAdapter: Send + Sync {
    /// #1167：安装器写、窗口程序读的标记文件（`update-failed`）放在哪个目录。
    ///
    /// 默认 = 数据目录（安装器与窗口程序是同一个用户）。Windows 服务形态的安装器是
    /// **提权进程**，换一个管理员来装，它的 `%LOCALAPPDATA%` 就是那个管理员的——所以那里
    /// 改放 `%ProgramData%\P-Pass\`（安装器给这个文件单独授交互用户读/删）。
    fn installer_marker_dir(&self) -> PathBuf {
        crate::adapter().data_dir()
    }

    /// #1238：daemon 的 config.toml 在哪个目录——窗口程序判断「配过没有」、读库位置只认这里。
    ///
    /// 默认 = 数据目录（窗口程序与 daemon 同一用户）。Windows 服务形态是 `%ProgramData%\P-Pass`
    /// （daemon 以服务账户运行，数据目录与窗口程序的不是同一个）。
    fn daemon_config_dir(&self) -> PathBuf {
        crate::adapter().data_dir()
    }

    /// #1238：「用户希望服务运行吗」的开关文件（[`crate::stop_switch`]）。`None` = 本形态没有
    /// 这个开关，「用户停过」记在窗口程序自己的数据目录里。
    fn service_stop_switch(&self) -> Option<PathBuf> {
        None
    }

    // 生命周期
    fn install_autostart(&self, exec: &std::path::Path) -> Result<()>;
    fn autostart_installed(&self) -> Result<bool>;
    fn uninstall_autostart(&self) -> Result<()>;

    /// 【DESK-42 #604 / #726】登记条目的状态：没登记、读不出、指向哪个可执行文件。
    ///
    /// 「指向哪里」与「是否读得出」是同一份信息，只有这一个入口（#1043 合并了
    /// 原先只给路径的 `autostart_registered_exec`）。默认实现 = 本平台没有登记
    /// 这回事，一律 `Absent`；能读登记的平台覆盖它。
    fn autostart_registration(&self) -> Result<AutostartRegistration> {
        Ok(AutostartRegistration::Absent)
    }

    /// #1046：登记已指向 `expected` 时，条目的**其余内容**是不是本版本
    /// [`Self::install_autostart`] 会写出的样子（macOS：plist 全文，含日志落点）。
    /// `false` ⇒ 对账按本版本重写（[`AutostartReconcile::Refreshed`]）。
    ///
    /// 默认 `true`：本平台的登记只有「指向哪个可执行文件」这一项信息。
    fn autostart_registration_current(&self, expected: &std::path::Path) -> Result<bool> {
        let _ = expected;
        Ok(true)
    }

    /// 【DESK-42 #604】对账**闸门**：本平台是否允许用 `expected` 改写开机自启登记。
    ///
    /// 默认 `false` = **保守拒绝**：平台必须显式声明哪些位置算「稳定安装位置」，
    /// 没声明就不许动用户的登记。真机风险（外部评审 2026-10-01 拦停）：dmg 挂载点、
    /// 「下载」目录、macOS App Translocation 随机路径都是一次性路径，把登记改指到
    /// 那里 → 下次开机 launchd 拉起一个已消失的可执行文件，服务静默起不来。
    fn autostart_reconcile_allowed(&self, _expected: &std::path::Path) -> bool {
        false
    }

    /// DESK-68 (#996)：这个程序文件是不是在本平台的**正式安装位置**。
    ///
    /// 发布版不在正式位置就不许运行（桌面壳启动时拦），也不许写开机自启登记
    /// （daemon 升级接管时拦）——登记一旦指向解压副本、备份副本，以后每次开机
    /// 都跑那个旧程序，新版接不了岗（#604 真机事故）。入口守住，所有写登记的
    /// 地方自然只会写正式路径。
    ///
    /// 默认 `true`：没实现的平台保持现状，由各平台线自己覆盖（macOS 见 #998）。
    fn is_install_location(&self, exe: &std::path::Path) -> bool {
        let _ = exe;
        true
    }

    /// DESK-68 (#996)：不在正式安装位置时，告诉用户该怎么办的文案 key
    /// （`assets/i18n`）。怎么「正式安装」是平台知识：Windows 是跑安装程序，
    /// macOS 是拖进「应用程序」。
    fn install_location_hint_key(&self) -> &'static str {
        "ui.install_location_required"
    }

    /// DESK-60 (#877)：对账结果是「未登记」时，本平台是否允许壳**补登记**
    /// （壳另外还要确认：配置过、且用户没有主动停服务）。
    ///
    /// 默认 `false`：「未登记」历来可能就是用户停过服务（DAE-03 ②：纯新启动
    /// 不许顺手装）。只有「登记会被系统流程删掉、而用户意图没变」的平台才
    /// 打开——Windows 的卸载会删 Run 值但保留配置和照片库。
    fn autostart_restore_when_missing(&self) -> bool {
        false
    }

    /// 【DESK-42 #604】开机自启登记对账：登记存在但指向别处或读不出 → 用 `expected`
    /// 重写（幂等）；未登记 → 不动；一致 → 不动；**位置不稳定 → 闸门拦下，不碰**。
    ///
    /// 由启动路径调用一次即可自愈「换目录 / 更新后路径漂移」的历史登记。
    /// ⚠️ 闸门在**读登记之前**判定：不稳定的位置连读都不读，避免任何后续分支
    /// 有机会写。
    fn reconcile_autostart(&self, expected: &std::path::Path) -> Result<AutostartReconcile> {
        if !self.autostart_reconcile_allowed(expected) {
            return Ok(AutostartReconcile::SkippedUnstableLocation);
        }
        let registered = self.autostart_registration()?;
        let mut action = reconcile_decision(&registered, expected);
        // #1046：指向对了还不够——内容也要是本版本写出的样子（日志落点等）。
        if action == AutostartReconcile::Unchanged
            && !self.autostart_registration_current(expected)?
        {
            action = AutostartReconcile::Refreshed;
        }
        if matches!(
            action,
            AutostartReconcile::Rewritten
                | AutostartReconcile::Repaired
                | AutostartReconcile::Refreshed
        ) {
            self.install_autostart(expected)?;
        }
        Ok(action)
    }

    fn service_mode(&self) -> ServiceMode;

    /// 内置 daemon 可执行文件的文件名。
    ///
    /// 默认是不带扩展名的 [`DAEMON_EXECUTABLE_STEM`]——这对除 Windows 外的
    /// 每个系统都成立，所以它是个诚实的默认值，不是猜的。
    fn daemon_executable_name(&self) -> &'static str {
        DAEMON_EXECUTABLE_STEM
    }

    /// 内置 daemon 可执行文件的位置，按桌面壳自己的可执行文件推出来。
    ///
    /// 默认是壳的同目录（Windows / Linux 的 sidecar）。macOS 的 daemon 是嵌套
    /// helper App（#1110），见 macOS 实现。壳里所有「找内置 daemon」的地方都走
    /// 这一个函数，布局只在平台层写一次。路径形状不对（没有父目录）= `None`。
    fn bundled_daemon_path(&self, shell_exe: &std::path::Path) -> Option<std::path::PathBuf> {
        Some(shell_exe.parent()?.join(self.daemon_executable_name()))
    }

    /// 结束正在跑的内置 daemon 进程（B7，#1043：两平台同一套语义）。
    ///
    /// - `exe`：内置 daemon 可执行文件的路径（壳旁边那个 sidecar）。**只认这个
    ///   路径**上跑的进程——不按命令行、不按文件名匹配，所以命令行里恰好含
    ///   `ppf-daemon` 的别的进程、别处的同名副本都不会被误杀。
    /// - `pid_hint`：daemon 经 IPC 自报的 pid（读不到给 `None`）。优先结束它，
    ///   但先核对它的可执行文件**名**与 `exe` 相同（pid 会被复用）；不核对目录
    ///   ——应答 IPC 的 daemon 跑在别处（开发构建、解压副本）时改前也停得掉。
    ///   之后照样按完整路径枚举兜底（daemon 挂死、IPC 不通时靠这条）。
    /// - 只动本用户 / 本会话的进程。结束方式沿用各平台改前的做法（unix 发
    ///   SIGTERM 不等；Windows `TerminateProcess` 并等它退出）——macOS 上
    ///   launchd 的 `KeepAlive{SuccessfulExit=false}` 靠「非正常退出」决定要不要
    ///   重拉，「重启服务」那条路依赖这一点，所以这里不走 daemon 的 `step_down`
    ///   （exit 0）。
    ///
    /// **没有默认实现**：三个系统都做得到这件事，编一个「不支持」的默认值
    /// 等于给将来的实现留一条静默什么都不做的路。
    ///
    /// 「进程本来就没在跑」返回 [`KillOutcome::NotRunning`]，**不是 `Err`**。
    /// 真失败（权限不足、被杀软拦）才是 `Err`——判据见各平台实现。
    fn stop_daemon(&self, exe: &std::path::Path, pid_hint: Option<u32>) -> Result<KillOutcome>;

    // ── UPD-06 (#616)：让**系统**负责"重启桌面壳" ─────────────────────
    //
    // 背景：更新装完磁盘上已是新版，但正在跑的壳仍是旧版，而**壳不能原地
    // 换代码**。0.7.5 的解法是壳自己重启（spawn 自己 + exit，今天是 `relaunch_shell` 的退化路径），
    // 那要在被替换的进程里自证没竞态（托盘常驻 + single-instance）。
    //
    // 更好的一层：把"杀 + 拉"交给系统的服务管理器（macOS = launchd），
    // **杀和拉都不在壳里发生**，single-instance 竞态在架构上消失，而且
    // 系统会告诉我们新实例的 pid（可验证）。
    //
    // ⚠️ 登记 ≠ 守卫：壳的登记**只解决"系统知道怎么启动它"**，因此**绝不挂
    // KeepAlive** —— 挂上 KeepAlive 用户就再也退不掉 App（托盘「退出 App」
    // 会被立刻复活）。守卫（崩溃自恢复）是 daemon 那一侧的事。
    // 壳是**登录项**（`RunAtLoad=true`，2026-10-02 验收人拍板）：登录时由 launchd
    // 拉起常驻托盘 —— 目的就是让"启动/重启壳"归系统管，而不是让进程自己换自己。
    // 没有 KeepAlive ⇒ 用户仍可完全退出，只是下次登录会再起来。

    /// 本平台给"桌面壳"用的服务标签（`None` = 本平台没有这个能力，调用方
    /// 降级回壳自己重启 / 显式重启）。
    fn shell_agent_label(&self) -> Option<&'static str> {
        None
    }

    /// **本进程是不是服务管理器自己拉起来的那一份**（macOS = launchd 设的
    /// `XPC_SERVICE_NAME` 等于我们的壳 label）。
    ///
    /// 为什么这条判据不可省（2026-10-02 读手册 + 推演所得）：
    /// `kickstart -k` 的 "kill the running instance" 只能杀掉**服务管理器自己
    /// 启动的**那个进程。用户从访达/Dock 直接打开的壳，launchd 手里没有它的
    /// pid ⇒ `-k` 无物可杀 ⇒ kickstart 只会**再拉起第二个实例**；而壳装了
    /// single-instance，第二个实例会把焦点交回旧壳后自杀 ⇒ 用户点"重启"什么
    /// 都没发生（比不重启更糟：看起来像坏掉）。
    ///
    /// 所以：只有"我确实是 launchd 的那一份"时才走系统路径；否则走壳自己重启
    /// （`tauri::process::restart`，0.7.5 起就在用、已在真机跑过）。
    /// 让系统路径成为常态需要产品决定"壳是否由 launchd 拉起（登录项）"——
    /// 已挂在 #616 的 PR 描述里等拍板，不在本卡悄悄改。
    fn shell_agent_started_us(&self) -> bool {
        false
    }

    /// DESK-72 (#1012)：把**当前壳**登记成登录项（幂等）——用户登录后由系统拉起、
    /// 常驻托盘。壳启动时调用，每次都重写，覆盖安装后路径自然跟上。
    ///
    /// 与下面 `register_shell_agent` 的分工：这里只管"登录时启动"这一件事，不涉及
    /// kickstart 换壳。macOS 两件事共用同一份 LaunchAgent，直接委托；Windows 用
    /// HKCU `Run` 值（没有服务管理器，换壳由安装程序完成）。
    ///
    /// 实现必须拒绝非正式安装位置：登记指向解压副本 / 开发构建，以后每次登录
    /// 都跑那个副本（#604 同一条风险）。不许覆盖用户在系统里关掉的开关
    /// （macOS「登录项」、Windows「启动应用」）。
    ///
    /// 默认什么都不做：本平台没有登录项的概念。
    fn register_shell_login_item(&self, exec: &std::path::Path) -> Result<()> {
        let _ = exec;
        Ok(())
    }

    /// 把**当前壳**登记成"按需可启动"的服务（幂等）。
    ///
    /// 只在需要换壳前调用；**绝不 bootout 正在运行的实例**（那会当场把壳
    /// 杀掉，而不是"等需要时再重启"）。已登记且指向同一个可执行文件 = 无操作。
    fn register_shell_agent(&self, exec: &std::path::Path) -> Result<()> {
        let _ = exec;
        Err(PlatformError::Failed {
            action: "register_shell_agent",
            detail: "此平台没有服务管理器，壳由调用方自行重启".into(),
        })
    }

    /// 已登记的壳服务指向哪个可执行文件（`None` = 没登记）。
    /// 调用方**必须先比对这个路径**再 kickstart，否则可能拉起另一份副本。
    fn shell_agent_registered_exec(&self) -> Result<Option<std::path::PathBuf>> {
        Ok(None)
    }

    /// 让服务管理器**杀掉并重启**壳，返回新实例 pid。
    /// 调用方：`shell_agent_label().is_some()` 且登记路径 == 当前可执行文件时才用。
    fn kickstart_shell_agent(&self) -> Result<u32> {
        Err(PlatformError::Failed {
            action: "kickstart_shell_agent",
            detail: "此平台没有服务管理器".into(),
        })
    }

    /// 磁盘上**安装包**的版本（macOS = `defaults read <bundle>/Contents/Info.plist
    /// CFBundleShortVersionString`；`None` = 读不到或本平台没实现）。
    ///
    /// 用途（UPD-06 #616）：与"进程自己编译进去的版本"比对，就是"更新装完了、
    /// 但**运行中的这只壳/这个 daemon 还是旧版**"的**确定性判据**——可执行文件
    /// 在 `/Applications` 下跨更新路径不变，包在它下面被换掉，于是"读到的包版本
    /// ≠ 我的编译版本"只有一种解释：我是旧进程、磁盘已是新版。
    ///
    /// ⚠️ 读不到必须返回 `None`（= 不知道），**绝不许**降级成"版本不一致"：
    /// 那会让一切正常的机器也去做一次没必要的换壳/重启（读不到＝无从判断，
    /// fail-safe 的方向永远是"什么都不做"）。
    fn installed_bundle_version(&self) -> Option<String> {
        None
    }

    // ── #667 / #732：常驻 daemon 必须始终归服务管理器托管 ───────────────
    //
    // 2026-10-08 取证（#667 评论）：更新后在跑的内核是旧壳一次性 spawn 的，
    // launchd 手里没有它（`state = not running`）⇒ 它崩了 KeepAlive 不会拉；
    // 一次性 spawn 的 stdio 接 null，LaunchAgent 的 `.err` 里也没有它的记录。
    // 解法同 UPD-06 的思路：**杀和拉都交给服务管理器**，壳只发一句
    // "按磁盘上的文件（重新）拉起来"。

    /// 服务管理器眼里正在跑的常驻 daemon 的 pid（`None` = 没在跑 / 没登记 /
    /// 本平台没有服务管理器）。与 daemon 自报的 `status.pid` 比对，就是
    /// "在跑的这个内核归不归服务管理器管"的确定性判据。
    fn resident_daemon_pid(&self) -> Option<u32> {
        None
    }

    /// 让服务管理器按**磁盘上的文件**拉起常驻 daemon。
    ///
    /// `kill_running = true`：在跑的那个（服务管理器自己启动的）先被杀掉再拉
    /// ——换版本用；`false`：没在跑才拉、在跑就不动——自愈用。
    ///
    /// ⚠️ 只管得到**服务管理器自己启动的**实例。一次性 spawn 出来的野生实例
    /// 它杀不到；新拉起来的实例若与它同版本会按 DAE-01 退位（exit 0 不重拉）
    /// ⇒ 结果仍是野生实例在岗。所以调用方要先让野生实例退位，再调本方法。
    ///
    /// 返回 `NotRegistered` / `Unsupported` 时**什么都没做**，调用方退回
    /// 一次性 spawn（`ServiceMode::UserAutostart` 没有服务管理器语义）。
    fn restart_resident_daemon(&self, kill_running: bool) -> Result<ResidentRestart> {
        let _ = kill_running;
        Ok(ResidentRestart::Unsupported)
    }

    /// #1060：应用内更新替换文件前，让服务管理器那份常驻 daemon **停下且不被
    /// 自动重拉**（launchd KeepAlive / 计划任务看门狗都会把「仅仅被杀」的进程
    /// 几秒内用旧文件拉回来，等于没停）。
    ///
    /// 与 [`Self::uninstall_autostart`] 的区别：**登记保留**（plist / 计划任务
    /// 还在），也不写任何「用户停止」标记——它只是「为更新暂停」，不是用户的
    /// 停止意图；恢复走 [`Self::restart_resident_daemon`]`(false)`。
    ///
    /// 默认 `Unsupported`（没有服务管理器的平台）。
    fn pause_resident_daemon(&self) -> Result<ResidentPause> {
        Ok(ResidentPause::Unsupported)
    }
}

/// [`PlatformAdapter::restart_resident_daemon`] 的结论。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResidentRestart {
    /// 服务管理器已（重新）拉起，新实例 pid（`-p` 报出来的，可验证）。
    Started { pid: u32 },
    /// 没杀也没拉：`kill_running=false` 且它本来就在跑。
    AlreadyRunning { pid: u32 },
    /// 本机没有登记常驻服务（用户停过服务 / 首启向导没走完）——什么都没做。
    NotRegistered,
    /// 本平台没有服务管理器语义——什么都没做。
    Unsupported,
}

/// [`HostingAdapter::pause_resident_daemon`] 的结论。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResidentPause {
    /// 服务管理器那份已被卸下 / 停下且**不会被它自动重拉**；登记保留，
    /// [`HostingAdapter::restart_resident_daemon`] 可原样拉回。
    Paused,
    /// 本机没有登记常驻服务——什么都没做。
    NotRegistered,
    /// 本平台没有服务管理器语义——什么都没做。
    Unsupported,
    /// 本平台不需要壳来暂停：安装器在替换文件前自己停服务，成功/失败都由
    /// 安装器恢复（Windows 的 NSIS PREINSTALL / POSTINSTALL / `.onInstFailed`）。
    /// 壳不动任务、不杀进程；安装器没启动时服务也不会中断。
    NotApplicable,
}

/// Windows 的 `GetUserPreferredUILanguages` 返回 multi-sz（`a\0b\0\0`）的 UTF-16：
/// 取第一个非空条目；空缓冲 / 首项为空 / 非法 UTF-16 → `None`。
#[cfg(any(windows, test))]
pub(crate) fn first_multi_sz_entry(buf: &[u16]) -> Option<String> {
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16(&buf[..end])
        .ok()
        .filter(|t| !t.is_empty())
}

/// #1043（B6）：按 POSIX 优先级（`LC_ALL` > `LC_MESSAGES` > `LANG`）取语言环境，
/// 去掉编码与修饰（`zh_CN.UTF-8@x` → `zh-CN`）。空串、`C`、`POSIX` 都不是语言，
/// 算读不到。纯函数，三平台都测得到。
pub(crate) fn posix_env_locale(
    lc_all: Option<&str>,
    lc_messages: Option<&str>,
    lang: Option<&str>,
) -> Option<String> {
    let raw = [lc_all, lc_messages, lang]
        .into_iter()
        .flatten()
        .find(|v| !v.trim().is_empty())?;
    let tag = raw.split(['.', '@']).next().unwrap_or("").trim();
    if tag.is_empty() || tag == "C" || tag == "POSIX" {
        return None;
    }
    Some(tag.replace('_', "-"))
}

/// DESK-33 (#325) / DESK-54 (#814)：产品代码启动子进程的**唯一入口**。
///
/// 等价于 `std::process::Command::new(program)`，只多一件事：在 Windows 上
/// 带 `CREATE_NO_WINDOW`。桌面壳与 daemon 的 release 构建都是 GUI 子系统，
/// 直接拉起 console 子系统程序（cmd / taskkill / ffmpeg …）时 Windows 会新
/// 分配一个控制台——用户看到黑窗一闪（#168 / #787 / #814）。对 GUI 子系统的
/// 子进程（比如 ppf-daemon sidecar）这个标志没有效果，所以一律带上即可。
///
/// 直接写 `Command::new` 会被 clippy 的 `disallowed-methods` 拦下（见仓根
/// `clippy.toml`）。调用方不用、也不许关心平台差异。
pub fn command(program: impl AsRef<std::ffi::OsStr>) -> std::process::Command {
    #[allow(clippy::disallowed_methods)] // 唯一被批准的构造点。
    #[cfg_attr(not(windows), allow(unused_mut))]
    let mut cmd = std::process::Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// 本平台的「平台能力」（[`PlatformAdapter`]）。daemon 与其他核心 crate 只走这个入口。
///
/// #1043（S-9）：返回值是 `impl PlatformAdapter`，**看不到** [`HostingAdapter`]
/// 的方法——核心想调托管能力在编译期就过不去；托管只经 [`hosting`] 拿。
#[cfg(target_os = "macos")]
pub fn adapter() -> impl PlatformAdapter {
    MacosAdapter::new()
}
#[cfg(windows)]
pub fn adapter() -> impl PlatformAdapter {
    WindowsAdapter::new()
}

/// 本平台的「托管」能力（[`HostingAdapter`]）：开机自启登记、服务管理器、结束
/// daemon 进程、安装位置。只给桌面发行层（壳）用；daemon 不许调（门禁 G3）。
#[cfg(target_os = "macos")]
pub fn hosting() -> impl HostingAdapter {
    MacosAdapter::new()
}
#[cfg(windows)]
pub fn hosting() -> impl HostingAdapter {
    WindowsAdapter::new()
}
/// Headless/server platforms (Linux cloud boxes run the daemon too):
/// data dir follows XDG; desktop-only capabilities answer honestly.
#[cfg(not(any(target_os = "macos", windows)))]
pub fn adapter() -> impl PlatformAdapter {
    HeadlessAdapter
}
#[cfg(not(any(target_os = "macos", windows)))]
pub fn hosting() -> impl HostingAdapter {
    HeadlessAdapter
}

#[cfg(not(any(target_os = "macos", windows)))]
pub struct HeadlessAdapter;

#[cfg(not(any(target_os = "macos", windows)))]
impl PlatformAdapter for HeadlessAdapter {
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

    // #1115：与 macOS 同一份 unix 实现（0700、属主必须是本用户）。
    fn prepare_private_dir(&self, path: &std::path::Path) -> Result<()> {
        #[cfg(unix)]
        {
            crate::unix::prepare_private_dir(path)
        }
        #[cfg(not(unix))]
        {
            std::fs::create_dir_all(path).map_err(|source| PlatformError::Io {
                action: "prepare_private_dir",
                source,
            })
        }
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
    /// 无桌面托管的 Linux：日志交给 stderr（systemd / Docker 接），不另写文件。
    fn daemon_log_paths(&self, _data_dir: &std::path::Path) -> DaemonLogPaths {
        DaemonLogPaths::default()
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
    fn platform_name(&self) -> &'static str {
        // headless 平台实际上就是 Linux；迁移前桌面壳那行 `else` 分支
        // 给的也是 "linux"，行为一字不变。
        "linux"
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
impl HostingAdapter for HeadlessAdapter {
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
    fn stop_daemon(&self, exe: &std::path::Path, pid_hint: Option<u32>) -> Result<KillOutcome> {
        #[cfg(unix)]
        {
            crate::unix::stop_processes_at(exe, pid_hint)
        }
        #[cfg(not(unix))]
        {
            let _ = (exe, pid_hint);
            Err(PlatformError::Failed {
                action: "stop_daemon",
                detail: "这个平台没有实现结束进程".into(),
            })
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// 取消是独立的一类，不能被归成失败——否则 UI 会把用户自己的选择
    /// 说成出错（macOS 的 `disable_auto_sleep` 仍走这条路径）。
    /// #1043：没有桌面向导的平台（headless Linux）——关窗提示照 Windows/Linux
    /// 习惯、原生标题栏、不回答睡眠归属。
    #[cfg(not(any(target_os = "macos", windows)))]
    #[test]
    fn headless_ui_capabilities() {
        let a = adapter();
        assert!(a.close_to_tray_hint());
        assert!(!a.overlay_titlebar());
        assert_eq!(a.sleep_owner(), None);
    }

    #[test]
    fn sleep_owner_wire_values() {
        assert_eq!(SleepOwner::User.as_str(), "user");
        assert_eq!(SleepOwner::Daemon.as_str(), "daemon");
    }

    /// #1056：multi-sz（界面语言列表）只取首项。
    #[test]
    fn multi_sz_first_entry() {
        let w = |s: &str| s.encode_utf16().collect::<Vec<u16>>();
        assert_eq!(
            first_multi_sz_entry(&w("zh-CN\0en-US\0\0")).as_deref(),
            Some("zh-CN")
        );
        assert_eq!(
            first_multi_sz_entry(&w("en-US\0\0")).as_deref(),
            Some("en-US")
        );
        assert_eq!(first_multi_sz_entry(&w("en-US")).as_deref(), Some("en-US"));
        assert_eq!(first_multi_sz_entry(&w("\0\0")), None);
        assert_eq!(first_multi_sz_entry(&[]), None);
        assert_eq!(first_multi_sz_entry(&[0xD800, 0]), None);
    }

    /// #1043（B6）：POSIX 环境变量的优先级与清洗。反证：把 `C`/`POSIX` 当成
    /// 语言、或 `LANG` 抢在 `LC_ALL` 前面 → 红。
    #[test]
    fn posix_env_locale_follows_priority_and_strips_encoding() {
        assert_eq!(
            posix_env_locale(Some("zh_CN.UTF-8"), Some("en_US"), Some("fr_FR")),
            Some("zh-CN".into())
        );
        assert_eq!(
            posix_env_locale(None, Some(""), Some("en_US.UTF-8@euro")),
            Some("en-US".into())
        );
        assert_eq!(posix_env_locale(None, None, Some("C.UTF-8")), None);
        assert_eq!(posix_env_locale(Some("POSIX"), None, None), None);
        assert_eq!(posix_env_locale(None, None, None), None);
        assert_eq!(posix_env_locale(Some("  "), None, Some("")), None);
    }

    #[test]
    fn cancelled_is_its_own_variant_not_a_failure() {
        let c = PlatformError::Cancelled {
            action: "disable_auto_sleep",
        };
        assert!(matches!(c, PlatformError::Cancelled { .. }));
        assert!(c.to_string().contains("取消"), "{c}");
    }

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

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_plist_keepalive_spares_clean_exit() {
        // DAE-02 缺陷①：退位实例 exit(0) 后 launchd 不得重拉（无条件
        // KeepAlive 会把它无限复活成 churn）。plist 必须是
        // SuccessfulExit=false 语义——成功退出不重拉、崩溃/被杀才复活。
        let plist = macos::agent_plist(
            std::path::Path::new("/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon"),
            &macos::daemon_log_paths_in(std::path::Path::new("/var/ppf")),
        );
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

    /// 【DESK-42 #604】对账决策的四条分支：
    /// 未登记（不许多手去装）、登记正确（不许动它）、登记漂移（必须重写）、登记损坏（#726，必须重写）。
    #[test]
    fn reconcile_decision_covers_all_four_shapes() {
        use AutostartRegistration::{Absent, At, Unreadable};
        let expected = std::path::Path::new(
            "/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
        );
        // 真机实测值（#604 挂号现象）：登记被钉在备份目录里的旧 App 上。
        let stale = std::path::Path::new(
            "/Users/lizhaowen/P-Pass-Backups/2026-09-30-before-0.6.2/old-app/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
        );

        assert_eq!(
            reconcile_decision(&Absent, expected),
            AutostartReconcile::NotRegistered,
            "没登记就不许顺手装（DAE-03 ②：纯新启动不得改用户的开机自启）"
        );
        assert_eq!(
            reconcile_decision(&At(expected.into()), expected),
            AutostartReconcile::Unchanged,
            "登记正确时不许反复重写（否则每次启动都 bootout/bootstrap 一次）"
        );
        assert_eq!(
            reconcile_decision(&At(stale.into()), expected),
            AutostartReconcile::Rewritten,
            "指向别处（换目录/更新/备份副本）必须判要重写——这就是本卡的现象"
        );
        // #726：登记文件在但读不出 ⇒ 必须修。当成「没登记」⇒ 每次开机服务都起不来、不会自己好。
        assert_eq!(
            reconcile_decision(&Unreadable, expected),
            AutostartReconcile::Repaired,
            "登记文件损坏必须判要重写，不许当成没登记"
        );
    }

    /// #1046：对账用的假托管端口——登记指向哪、内容是不是本版本的样子都可注入，
    /// 记下 `install_autostart` 被调了几次。
    struct FakeHosting {
        registration: AutostartRegistration,
        current: bool,
        installs: std::sync::Mutex<Vec<std::path::PathBuf>>,
    }

    impl HostingAdapter for FakeHosting {
        fn install_autostart(&self, exec: &std::path::Path) -> Result<()> {
            self.installs.lock().unwrap().push(exec.to_path_buf());
            Ok(())
        }
        fn autostart_installed(&self) -> Result<bool> {
            Ok(!matches!(self.registration, AutostartRegistration::Absent))
        }
        fn uninstall_autostart(&self) -> Result<()> {
            Ok(())
        }
        fn autostart_registration(&self) -> Result<AutostartRegistration> {
            Ok(self.registration.clone())
        }
        fn autostart_registration_current(&self, _expected: &std::path::Path) -> Result<bool> {
            Ok(self.current)
        }
        fn autostart_reconcile_allowed(&self, _expected: &std::path::Path) -> bool {
            true
        }
        fn service_mode(&self) -> ServiceMode {
            ServiceMode::UserAutostart
        }
        fn stop_daemon(
            &self,
            _exe: &std::path::Path,
            _pid_hint: Option<u32>,
        ) -> Result<KillOutcome> {
            Ok(KillOutcome::NotRunning)
        }
    }

    /// #1046（S-11）：老版本登记的 exe 没变、但内容（macOS plist 的日志落点）是旧的
    /// ⇒ 对账必须按本版本重写一次；重写后内容一致 ⇒ 不再动（幂等，不反复 bootout）。
    /// 反证：去掉 `reconcile_autostart` 里的内容比对 → 第一条断言得到 Unchanged，红。
    #[test]
    fn reconcile_refreshes_a_registration_whose_content_is_stale() {
        let exe = std::path::Path::new(
            "/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
        );
        let stale = FakeHosting {
            registration: AutostartRegistration::At(exe.into()),
            current: false,
            installs: Default::default(),
        };
        assert_eq!(
            stale.reconcile_autostart(exe).unwrap(),
            AutostartReconcile::Refreshed
        );
        assert_eq!(*stale.installs.lock().unwrap(), vec![exe.to_path_buf()]);

        let fresh = FakeHosting {
            registration: AutostartRegistration::At(exe.into()),
            current: true,
            installs: Default::default(),
        };
        assert_eq!(
            fresh.reconcile_autostart(exe).unwrap(),
            AutostartReconcile::Unchanged
        );
        assert!(fresh.installs.lock().unwrap().is_empty(), "一致时不许重写");

        // 未登记仍然不动（DAE-03 ②），内容比对不改变这一条。
        let absent = FakeHosting {
            registration: AutostartRegistration::Absent,
            current: false,
            installs: Default::default(),
        };
        assert_eq!(
            absent.reconcile_autostart(exe).unwrap(),
            AutostartReconcile::NotRegistered
        );
        assert!(absent.installs.lock().unwrap().is_empty());
    }

    /// 【DESK-42 #604】读得出登记路径，是对账的前提；读不出来就永远发现不了漂移。
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_plist_round_trips_its_program_argument() {
        let exec = std::path::Path::new(
            "/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
        );
        let text = macos::agent_plist(
            exec,
            &macos::daemon_log_paths_in(std::path::Path::new("/var/ppf")),
        );
        assert_eq!(
            macos::plist_program_argument(&text).as_deref(),
            Some("/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon"),
            "生成的 plist 必须能被自己的解析器读回同一个路径"
        );
        // 反证：把 ProgramArguments 段换掉，必须读不出——否则「读到了」可能只是巧合。
        let broken = text.replace(
            "<key>ProgramArguments</key>",
            "<key>NotProgramArguments</key>",
        );
        assert_eq!(macos::plist_program_argument(&broken), None);
    }

    /// #726：登记文件「在但读不出」必须归成 `Unreadable`，不许混进「没登记」。
    /// 每种坏法都是真实会出现的形状：写到一半断电、被截成空文件、被改坏。
    /// 反证：把 `registration_from_read` 里的 `Unreadable` 换回 `Absent` → 本测试必须红。
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_unreadable_registration_is_not_mistaken_for_absent() {
        use macos::registration_from_read as classify;
        use AutostartRegistration::{Absent, At, Unreadable};
        let exec = std::path::Path::new(
            "/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
        );
        let good = macos::agent_plist(
            exec,
            &macos::daemon_log_paths_in(std::path::Path::new("/var/ppf")),
        );

        assert_eq!(classify(Ok(good.clone())).unwrap(), At(exec.into()));
        let not_found = std::io::Error::from(std::io::ErrorKind::NotFound);
        assert_eq!(classify(Err(not_found)).unwrap(), Absent);

        let half = good[..good.find("<key>ProgramArguments</key>").unwrap() + 10].to_string();
        for (shape, text) in [
            ("写到一半", half),
            ("空文件", String::new()),
            ("被改坏", "not a plist at all".to_string()),
        ] {
            assert_eq!(
                classify(Ok(text)).unwrap(),
                Unreadable,
                "{shape}：登记文件在但读不出，必须判损坏（由对账重写）"
            );
        }
        // 读文件本身出错（权限等）照旧报错，不许静默归类
        let denied = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        assert!(classify(Err(denied)).is_err());
    }

    /// #726：原子写入——写完内容完整、临时文件不残留、已有文件被整体替换。
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_write_atomic_replaces_whole_file_and_leaves_no_temp() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("com.hawkeyexb.ppass.desktop.daemon.plist");
        std::fs::write(&path, "half a plist <key>Progr").unwrap();

        macos::write_atomic(&path, "complete").unwrap();

        assert_eq!(std::fs::read_to_string(&path).unwrap(), "complete");
        let names: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            names,
            vec!["com.hawkeyexb.ppass.desktop.daemon.plist"],
            "临时文件不许残留"
        );
    }

    /// UPD-06 (#616)：壳是**登录项**，但**不是守卫**。
    ///
    /// 两件事必须同时成立：
    /// ① `RunAtLoad=true` —— 登录时由 launchd 拉起（"启动壳"归系统管；也正因为
    ///    如此 `kickstart -k` 才有东西可杀，见 `shell_agent_started_us`）；
    /// ② **不许出现 `KeepAlive`** —— 挂上它用户就再也退不掉 App（托盘「退出 App」
    ///    会被立刻复活）。用户可以完全退出，只是下次登录会再起来。
    ///
    /// 反证：把 `KeepAlive` 段加回去、或把 `RunAtLoad` 改成 `<false/>` → 本测试必须红。
    #[cfg(target_os = "macos")]
    #[test]
    fn shell_agent_is_a_login_item_but_never_guarded() {
        let exec = std::path::Path::new("/Applications/P-Pass.app/Contents/MacOS/p-pass-desktop");
        let plist = macos::shell_agent_plist(exec);
        assert!(
            !plist.contains("KeepAlive"),
            "壳的登记不许挂 KeepAlive（用户会退不掉 App）: {plist}"
        );
        assert!(
            plist.contains("<key>RunAtLoad</key><true/>"),
            "壳是登录项：登录时由 launchd 拉起，kickstart 才有东西可杀: {plist}"
        );
        assert_eq!(
            macos::plist_program_argument(&plist),
            Some(exec.display().to_string()),
            "ProgramArguments 必须指向壳自己的可执行文件，kickstart 才有意义"
        );
        // 能力要真的暴露出来：调用方靠它决定走"系统重启"还是退化到自己重启。
        assert_eq!(
            HostingAdapter::shell_agent_label(&macos::MacosAdapter::new()),
            Some("com.hawkeyexb.ppass.desktop.shell")
        );
    }

    /// UPD-06 (#616)：安装包版本的判据建立在"从可执行文件推出它所属的 `.app`"上，
    /// 形状不对必须返回 `None`（= **不知道**）——猜错方向的代价是"一切正常的机器
    /// 也去做一次没必要的换壳/重启"。
    #[cfg(target_os = "macos")]
    #[test]
    fn bundle_root_only_accepts_the_app_bundle_shape() {
        use macos::bundle_root;
        use std::path::{Path, PathBuf};
        assert_eq!(
            bundle_root(Path::new(
                "/Applications/P-Pass.app/Contents/MacOS/p-pass-desktop"
            )),
            Some(PathBuf::from("/Applications/P-Pass.app"))
        );
        // 不是 .app 布局的一律 None：开发构建、裸二进制、少一层目录
        assert_eq!(bundle_root(Path::new("/usr/local/bin/ppf-daemon")), None);
        assert_eq!(
            bundle_root(Path::new("/Applications/P-Pass.app/p-pass-desktop")),
            None
        );
        assert_eq!(
            bundle_root(Path::new("/Applications/P-Pass.app/Contents/MacOS")),
            None
        );
    }

    /// UPD-07 (#617)：owner 换壳前必须先确认"登记里的实例就是用户现在这把壳"。
    /// 判据取自 `launchctl print` 的真实输出形状（样本来自本机 `ai.hermes.gateway`）。
    /// 反证：把解析改成"取任意含数字的行"→ 下面「没在跑」那条会读到别的数字而红。
    #[cfg(target_os = "macos")]
    #[test]
    fn launchd_job_pid_only_reads_the_running_instances_pid_line() {
        use macos::launchd_job_pid;
        // 正在跑（真机样本，pid 换成了假数）
        let running = "gui/501/ai.hermes.gateway = {\n\tactive count = 1\n\tpath = /Users/x/Library/LaunchAgents/ai.hermes.gateway.plist\n\ttype = LaunchAgent\n\tstate = running\n\n\tprogram = /usr/bin/python\n\tlast exit code = 0\n\tpid = 992\n}\n";
        assert_eq!(launchd_job_pid(running), Some(992));
        // 没在跑：launchd 不打 pid 行（真机样本）
        let not_running = "gui/501/com.apple.SafariHistoryServiceAgent = {\n\tactive count = 0\n\tstate = not running\n\n\tprogram = /usr/libexec/SafariHistoryServiceAgent\n\tlast exit code = 78\n}\n";
        assert_eq!(launchd_job_pid(not_running), None);
        // 别的行里出现的数字不许被当成 pid
        assert_eq!(launchd_job_pid("\tactive count = 123\n"), None);
        assert_eq!(launchd_job_pid(""), None);
    }

    /// #667/#732：`kickstart -p` 的 stdout 就是新 pid（本机 2026-10-08 实测输出 `35736\n`）。
    /// 读不出必须是 `None`（调用方再用 `print` 兜），不许编一个 0。
    #[cfg(target_os = "macos")]
    #[test]
    fn kickstart_reported_pid_reads_the_bare_pid_line() {
        use macos::kickstart_reported_pid;
        assert_eq!(kickstart_reported_pid("35736\n"), Some(35736));
        assert_eq!(kickstart_reported_pid(""), None);
        assert_eq!(kickstart_reported_pid("service already running\n"), None);
    }

    /// #667/#732：没有服务管理器的平台（headless）**什么都不做**，调用方据此
    /// 退回一次性 spawn。Windows 自 DESK-65 (#957) 起由任务计划程序托管，不在此列。
    #[cfg(not(any(target_os = "macos", windows)))]
    #[test]
    fn resident_restart_is_a_no_op_without_a_service_manager() {
        assert_eq!(
            hosting().restart_resident_daemon(true).unwrap(),
            ResidentRestart::Unsupported
        );
        assert_eq!(hosting().resident_daemon_pid(), None);
    }

    /// 【DESK-42 #604】闸门判据：只放行稳定安装位置。
    /// 外部评审在 PR #611 上拦下的正是「不判位置就静默改写登记」——这些一次性路径
    /// 必须一条都不许过。
    #[cfg(target_os = "macos")]
    #[test]
    fn gate_allows_only_stable_install_locations() {
        use macos::is_stable_install_location as allowed;
        let p = |s: &str| std::path::PathBuf::from(s);

        // 稳定：系统级 / 用户级安装
        assert!(allowed(&p(
            "/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon"
        )));
        assert!(allowed(&p(&format!(
            "{}/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
            std::env::var("HOME").unwrap_or_default()
        ))));

        // 一次性 / 不稳定：一条都不许过（每行都是真机上真实存在的形态）
        assert!(
            !allowed(&p("/Volumes/P-Pass/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon")),
            "dmg 挂载点"
        );
        assert!(
            !allowed(&p(&format!(
                "{}/Downloads/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
                std::env::var("HOME").unwrap_or_default()
            ))),
            "「下载」目录直接点开"
        );
        assert!(
            !allowed(&p("/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon")),
            "App Translocation 随机路径"
        );
        assert!(
            !allowed(&p("/Users/lizhaowen/P-Pass-Backups/2026-09-30-before-0.6.2/old-app/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon")),
            "备份副本（本卡的原始现场）"
        );
        assert!(
            !allowed(&p("/Users/x/workspace/P-Pass/target/debug/ppf-daemon")),
            "开发构建路径"
        );
    }

    /// 【DESK-42 #604】闸门必须**先于**读登记生效：不稳定位置上，对账直接返回
    /// `SkippedUnstableLocation`，既不改也不读。
    /// 反证：把闸门去掉（恒真），这条会变成 NotRegistered/Unchanged/Rewritten → 断言失败。
    #[cfg(target_os = "macos")]
    #[test]
    fn gate_precedes_registration_read_and_write() {
        let adapter = macos::MacosAdapter::new();
        let dmg = std::path::Path::new(
            "/Volumes/P-Pass/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
        );
        assert_eq!(
            adapter.reconcile_autostart(dmg).expect("reconcile"),
            AutostartReconcile::SkippedUnstableLocation,
            "从 dmg 挂载点启动时绝不许改写开机自启登记"
        );
    }
}

#[cfg(test)]
mod computer_name_tests {
    use super::*;

    #[test]
    fn blank_names_count_as_unreadable() {
        assert_eq!(clean_computer_name("  "), None);
        assert_eq!(clean_computer_name(""), None);
        assert_eq!(
            clean_computer_name(" 客厅的 Mac \n").as_deref(),
            Some("客厅的 Mac")
        );
    }

    /// #1118：与系统自带工具读到的同一个名字（`scutil --get ComputerName` 是
    /// 「关于本机」里那个名称的命令行出口）。
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_reads_the_same_name_as_scutil() {
        let out = std::process::Command::new("scutil")
            .args(["--get", "ComputerName"])
            .output()
            .expect("scutil");
        let expected = clean_computer_name(&String::from_utf8_lossy(&out.stdout));
        assert!(expected.is_some(), "this Mac has no ComputerName");
        assert_eq!(adapter().computer_name(), expected);
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    #[test]
    fn posix_reads_the_hostname() {
        assert!(adapter().computer_name().is_some());
    }
}

#[cfg(test)]
mod relocation_probe_tests {
    use super::*;

    #[test]
    fn two_dirs_on_one_disk_are_one_volume_and_local() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        assert_eq!(same_volume(a.path(), b.path()), Some(true));
        assert!(!is_network_volume(a.path()));
    }

    // 系统工具拷目录：内容、空目录、隐藏文件都在，原目录不动。
    #[test]
    fn the_system_tool_copies_a_directory_tree() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src");
        std::fs::create_dir_all(src.join("a/b")).unwrap();
        std::fs::create_dir_all(src.join("empty")).unwrap();
        std::fs::write(src.join("a/b/photo.jpg"), b"photo").unwrap();
        std::fs::write(src.join(".hidden"), b"h").unwrap();
        let dst = dir.path().join("dst");
        copy_dir_contents(&src, &dst).unwrap();
        assert_eq!(std::fs::read(dst.join("a/b/photo.jpg")).unwrap(), b"photo");
        assert!(dst.join("empty").is_dir());
        assert!(dst.join(".hidden").is_file());
        assert!(src.join("a/b/photo.jpg").is_file(), "原目录不动");
    }

    #[test]
    fn a_failing_copy_is_reported() {
        let dir = tempfile::tempdir().unwrap();
        assert!(copy_dir_contents(&dir.path().join("nope"), &dir.path().join("dst")).is_err());
    }
}
