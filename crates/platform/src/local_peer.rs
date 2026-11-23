//! #1115：本机 IPC 对端是谁——按对端进程的**代码签名**认人，不按「能读到某个文件」。
//!
//! macOS：连接建立时内核记下对端的 audit token（`LOCAL_PEERTOKEN`，macOS 13+ 公开支持），
//! 用 Security 框架按 token 找到对端代码（`SecCodeCopyGuestWithAttributes`）并校验
//! [`code_requirement`]。不用 PID：「先连上发请求、再 exec 成合法程序」能骗过 PID 查询
//! （讨论稿 §2.5 实测 6/6），audit token 带 pidversion，exec 之后就对不上。
//!
//! 服务端（daemon）用它认客户端；客户端（壳、daemon 的单实例交接、诊断导出）对已连上的
//! socket 调用它，拿到的是**监听方**的身份——反向校验服务端，防 socket 被抢注。
//!
//! 校验是同步 Security 调用（实测 0.2–7ms，含读盘校验静态签名），async 调用方放进
//! `spawn_blocking`。
//!
//! #1167：Windows 按**用户 SID** 认人（D5：按用户认，不按程序认），实现在
//! `windows_pipe.rs`：服务端模拟客户端取令牌用户，客户端看管道属主 + 服务端会话。
//! 同样是同步系统调用，同样放进 `spawn_blocking`（服务端的模拟会临时换掉调用线程的身份）。

use crate::code_signature::{DAEMON_APP_ID, DESKTOP_APP_ID};

/// 我们自己的两个签名程序。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerRole {
    /// 桌面主 App（窗口程序），[`DESKTOP_APP_ID`]。
    Shell,
    /// 内置 daemon（helper App），[`DAEMON_APP_ID`]。
    Daemon,
}

impl PeerRole {
    pub fn identifier(self) -> &'static str {
        match self {
            PeerRole::Shell => DESKTOP_APP_ID,
            PeerRole::Daemon => DAEMON_APP_ID,
        }
    }
}

/// 对端校验结果。不是 `Result`：「本平台不做这项校验」不能被说成通过。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PeerCheck {
    /// 对端满足 `code_requirement(role.identifier())`。
    Verified(PeerRole),
    /// 不是我们签名的程序（或拿不到对端身份）——断开，什么都不发。
    Rejected(String),
    /// 本平台没有本机对端认证的实现（Linux：仍用令牌）。
    NotSupported(&'static str),
}

/// #1826 / #1918：用户「标准目录」的事实——家目录，加上桌面 / 文稿 / 下载 / 图片 / 影片 / 音乐，
/// 以及 macOS 的 `~/Library`。**真实位置**由系统口径给出（Windows 走 `SHGetKnownFolderPath`，
/// 可能被重定向到家目录外、别的盘）；调用方负责解析符号链接。
///
/// 平台差异（怎么取）留在 [`UserDirFacts::for_current_user`] 里，结构本身各平台同一份，
/// daemon 只消费这一份。Windows 服务形态下由已通过管道 SID 鉴权的本机主人桌面进程调
/// [`UserDirFacts::for_current_user`] 获取并随 `config.set_library` / `library.relocate`
/// 传给 daemon（#1918）；`library` 在 Windows 上按定义就是 `None`，不算缺失。
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct UserDirFacts {
    /// 家目录；读不到 = `None`。
    pub home: Option<std::path::PathBuf>,
    pub desktop: Option<std::path::PathBuf>,
    pub documents: Option<std::path::PathBuf>,
    pub downloads: Option<std::path::PathBuf>,
    /// macOS 的 `~/Library`（应用支持、缓存、iCloud 都在它下面）；别的平台没有。
    pub library: Option<std::path::PathBuf>,
    pub pictures: Option<std::path::PathBuf>,
    /// macOS 的「影片」；Windows 是 `FOLDERID_Videos`（Linux 按 XDG 的 `Videos`）。
    pub videos: Option<std::path::PathBuf>,
    pub music: Option<std::path::PathBuf>,
}

/// #1918：单个用户目录事实路径是否合法：非空、本机磁盘绝对路径、不含 `..`，
/// 且显式拒绝 UNC 网络共享与 Windows 设备命名空间路径（防止服务端以 `NT SERVICE\P-Pass`
/// 身份 `canonicalize` 触发外连 SMB/NTLM 或访问设备对象）。
///
/// 跨平台判据（不依赖 `cfg`）：
/// - 含 NUL 或任一段为 `..` ⇒ 拒绝；
/// - UNC（`\\server\...`、`//server/...`、`\\?\UNC\...`）与设备/非盘符命名空间
///   （`\\.\...`、`\\?\GlobalRoot\...`、`\\?\Volume{...}`）⇒ 由
///   [`UserDirFacts::is_unc_or_device_path`] 统一拒绝；
/// - Windows 盘符绝对路径：`<盘符>:\`、`<盘符>:/`、以及 `canonicalize()` 产出的本地盘符
///   扩展路径 `\\?\<盘符>:\` ⇒ 放行；
/// - POSIX 绝对路径：非 Windows 宿主上以单个 `/` 开头（排除 `//`）⇒ 放行；
///   Windows 宿主上无盘符的 `/...` 属于驱动器相对路径，由 `path.is_absolute()` 自然拒绝。
///
/// #1927：格式合法后还要在两个**会产生文件系统访问**的判据上过一遍——指向远端 /
/// 设备命名空间的重解析点（[`crate::contains_remote_reparse_point`]）与网络卷 / 映射
/// 网络盘（[`crate::is_network_volume_or_ancestor`]）一律拒，避免服务形态下以服务
/// 身份跟随 junction / 映射盘外连。
fn is_valid_dir_fact_path(path: &std::path::Path) -> bool {
    let raw = path.as_os_str();
    if raw.is_empty() {
        return false;
    }
    let s = raw.to_string_lossy();
    if s.trim().is_empty() || UserDirFacts::is_unc_or_device_path(path) {
        return false;
    }
    // 任一路径段出现 `..` 一律拒绝（兼容 `/` 与 `\` 两种分隔符）。
    if path
        .components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
        || s.split(['/', '\\']).any(|seg| seg == "..")
    {
        return false;
    }
    let bytes = s.as_bytes();
    // 1. 标准 Windows 本地盘符绝对路径：`C:\...` 或 `C:/...`。
    let normal_drive = bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'\\' || bytes[2] == b'/');
    // 2. Windows `canonicalize()` 产出的本地盘符 verbatim 路径：`\\?\C:\...`。
    let verbatim_drive = bytes.len() >= 7
        && bytes.starts_with(br"\\?\")
        && bytes[4].is_ascii_alphabetic()
        && bytes[5] == b':'
        && bytes[6] == b'\\';
    // 3. POSIX 本地绝对路径（单个 `/` 开头；在 Windows 宿主上 `is_absolute()` 为 false）。
    let posix = bytes[0] == b'/' && path.is_absolute();
    // #1927：格式合法后，还要在 `canonicalize()` / `real_path` 之前拦掉指向远端 /
    // 设备命名空间的重解析点，以及网络卷 / 映射网络盘——服务形态下这些都会让服务
    // 账户以服务身份外连 SMB/NTLM（`user_dirs` 进入 `real_path` 前就要拒）。
    (normal_drive || verbatim_drive || posix)
        && !crate::contains_remote_reparse_point(path)
        && !crate::is_network_volume_or_ancestor(path)
}

impl UserDirFacts {
    /// #1918：路径是否指向 UNC 网络共享或 Windows 设备/非盘符命名空间（如 `\\server\share`、
    /// `//server/share`、`\\?\UNC\...`、`\\.\...`、`\\?\GlobalRoot\...`、`\\?\Volume{...}`），
    /// 或含 NUL 字节。`canonicalize()` 产出的本地盘符 verbatim 路径（`\\?\<盘符>:\...`）不算。
    ///
    /// `user_dirs` 校验与照片库目标路径（`check_library_path`）共用这一份判据：必须在任何
    /// `canonicalize()` / 文件系统访问之前拒绝，防止服务账户触发外连 SMB/NTLM 或设备访问。
    pub fn is_unc_or_device_path(path: &std::path::Path) -> bool {
        let s = path.as_os_str().to_string_lossy();
        if s.contains('\0') {
            return true;
        }
        let bytes = s.as_bytes();
        // `canonicalize()` 产出的本地盘符 verbatim 路径 `\\?\C:\...` 放行。
        if bytes.len() >= 7
            && bytes.starts_with(br"\\?\")
            && bytes[4].is_ascii_alphabetic()
            && bytes[5] == b':'
            && bytes[6] == b'\\'
        {
            return false;
        }
        bytes.len() >= 2
            && (bytes[0] == b'\\' || bytes[0] == b'/')
            && (bytes[1] == b'\\' || bytes[1] == b'/')
    }

    /// 给定家目录、按各平台的标准名字算全套事实（测试与无 KF 机制的平台的口径）。
    pub fn from_home(home: std::path::PathBuf) -> Self {
        let at = |name: &str| Some(home.join(name));
        Self {
            desktop: at("Desktop"),
            documents: at("Documents"),
            downloads: at("Downloads"),
            library: if cfg!(target_os = "macos") {
                at("Library")
            } else {
                None
            },
            pictures: at("Pictures"),
            videos: at(if cfg!(target_os = "macos") {
                "Movies"
            } else {
                "Videos"
            }),
            music: at("Music"),
            home: Some(home),
        }
    }

    /// **没有连接方**时的事实：macOS / Linux 从平台适配器的家目录与「图片」目录算；
    /// Windows 按当前用户的 Known Folder 逐个取（计划任务形态下 daemon 本来就跑在
    /// 用户自己名下，当前用户 = 主人）。
    pub fn for_current_user() -> Self {
        #[cfg(windows)]
        {
            crate::windows::current_user_dir_facts()
        }
        #[cfg(not(windows))]
        {
            use crate::PlatformAdapter as _;
            let mut facts = Self::from_home(crate::adapter().home_dir().unwrap_or_default());
            facts.pictures = crate::adapter().pictures_dir();
            facts
        }
    }

    /// 遍历各标准目录（不含家目录本身——家目录单独有一类判定）。缺失的就跳过。
    pub fn standard_dirs(&self) -> impl Iterator<Item = &std::path::PathBuf> {
        [
            &self.desktop,
            &self.documents,
            &self.downloads,
            &self.library,
            &self.pictures,
            &self.videos,
            &self.music,
        ]
        .into_iter()
        .flatten()
    }

    /// #1826 / #1918：选照片库位置要用的关键事实齐不齐且格式合法：家目录 + 除 macOS
    /// `library` 外的全部标准目录均非空、为绝对路径且不含 `..`；可选 `library` 若存在
    /// 也必须同样合法（Windows 的 `library` 按 [`UserDirFacts`] 的定义就是 `None`）。
    /// 连接方存在而事实不齐或不合法 ⇒ 调用方必须拒绝本次选择，不拿自己的目录代答、不按形状猜。
    pub fn selection_ready(&self) -> bool {
        let req = |p: &Option<std::path::PathBuf>| p.as_deref().is_some_and(is_valid_dir_fact_path);
        let opt = |p: &Option<std::path::PathBuf>| p.as_deref().is_none_or(is_valid_dir_fact_path);
        req(&self.home)
            && req(&self.desktop)
            && req(&self.documents)
            && req(&self.downloads)
            && req(&self.pictures)
            && req(&self.videos)
            && req(&self.music)
            && opt(&self.library)
    }
}

/// #1167：连接方的系统用户（Windows：SID 字符串）。只有 Windows 管道的**服务端**取得到；
/// 用途有两个——首启向导写好库位置时把它记成主人（`PlatformAdapter::claim_resident_owner`），
/// 以及敏感目录判定要知道主人的用户标准目录（#1826 / #1918）。
///
/// #1918：命名管道保持 `SECURITY_IDENTIFICATION` 且服务账户禁止 `SeImpersonatePrivilege`，
/// 因此跨用户（服务形态）时服务端不再用标识级令牌调 `SHGetKnownFolderPath`，`dirs` 初始为空；
/// 由已通过管道 SID 鉴权的本机主人桌面进程直接调 `SHGetKnownFolderPath` 获取 [`UserDirFacts`]
/// 并随 `config.set_library` / `library.relocate` 传入，经服务端校验后注入。
/// 同用户直跑/计划任务形态下服务端直接取当前用户事实。事实不齐或不合法 ⇒ 拒绝本次选择。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerUser {
    pub(crate) sid: String,
    pub(crate) dirs: UserDirFacts,
}

impl PeerUser {
    /// 平台实现与测试构造用。
    pub fn new(sid: String, dirs: UserDirFacts) -> Self {
        Self { sid, dirs }
    }

    /// 用新的目录事实替换（保留已验证的 SID）。供服务端把客户端提交并校验后的
    /// [`UserDirFacts`] 绑定到已通过 SID 鉴权的连接方（#1918）。
    pub fn with_dirs(&self, dirs: UserDirFacts) -> Self {
        Self {
            sid: self.sid.clone(),
            dirs,
        }
    }

    /// 给日志与错误说明用的标识（Windows：SID）。
    pub fn id(&self) -> &str {
        &self.sid
    }

    /// 连接方（主人）的用户目录事实；各字段读不到的是 `None`。
    pub fn dirs(&self) -> &UserDirFacts {
        &self.dirs
    }
}

/// 能取出对端身份的本机连接（interprocess 的同步与 tokio 两种 Stream）。
pub trait LocalPeerSource {
    #[doc(hidden)]
    fn check_peer(&self, allowed: &[PeerRole], min_version: Option<&str>) -> PeerCheck;
    #[doc(hidden)]
    fn peer_user(&self) -> Option<PeerUser>;
}

impl LocalPeerSource for interprocess::local_socket::Stream {
    fn check_peer(&self, allowed: &[PeerRole], min_version: Option<&str>) -> PeerCheck {
        imp::check_sync(self, allowed, min_version)
    }
    fn peer_user(&self) -> Option<PeerUser> {
        imp::peer_user_sync(self)
    }
}

impl LocalPeerSource for interprocess::local_socket::tokio::Stream {
    fn check_peer(&self, allowed: &[PeerRole], min_version: Option<&str>) -> PeerCheck {
        imp::check_tokio(self, allowed, min_version)
    }
    fn peer_user(&self) -> Option<PeerUser> {
        imp::peer_user_tokio(self)
    }
}

/// 校验本机连接的对端是 `allowed` 里的哪一个（macOS 按签名、Windows 按用户 SID；
/// 按顺序试，第一个满足的胜出）。
pub fn verify_local_peer<S: LocalPeerSource>(stream: &S, allowed: &[PeerRole]) -> PeerCheck {
    stream.check_peer(allowed, None)
}

/// 同 [`verify_local_peer`]，另要求对端**被签名封住的版本号不低于** `min_version`（#1150）。
///
/// 只给**服务端接入**用（daemon 认窗口程序 / 另一个 daemon）：旧的已签名版本不能一直
/// 被认作合法对端。客户端方向（壳连 daemon、新 daemon 连旧 daemon 交接）不加下限——升级窗口里
/// 新壳必须能连上旧 daemon 让它退位。版本读不出来 ⇒ 拒绝，不猜。
pub fn verify_local_peer_min_version<S: LocalPeerSource>(
    stream: &S,
    allowed: &[PeerRole],
    min_version: &str,
) -> PeerCheck {
    stream.check_peer(allowed, Some(min_version))
}

/// 版本下限判据（纯函数，各平台一致）：对端版本缺失或为空 ⇒ 拒绝；低于下限 ⇒ 拒绝；
/// 等于或更高 ⇒ 通过。比较用项目统一的 `version_cmp`（它把垃圾输入当 0，所以缺失
/// 必须在这里先显式拒绝，不能指望比较结果兜底）。
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn meets_min_version(peer: Option<&str>, min_version: &str) -> Result<(), String> {
    let Some(peer) = peer.map(str::trim).filter(|v| !v.is_empty()) else {
        return Err("对端没有可读的版本号".into());
    };
    if version_cmp::version_cmp(peer, min_version) == std::cmp::Ordering::Less {
        return Err(format!("对端版本 {peer} 低于下限 {min_version}"));
    }
    Ok(())
}

/// #1167：服务端要不要**先读到客户端发来的数据**才能核对它。
///
/// Windows：`ImpersonateNamedPipeClient` 在服务端还没从管道读到数据时答
/// `ERROR_CANNOT_IMPERSONATE`（1368，Win11 26200 实测）。所以 Windows 的服务端先读出第一行
/// （不解析、不应答），再认人；认不过就断开，读到的那一行丢掉。macOS 按 audit token 认，
/// 连接建立即可，读任何字节之前就校验。
pub fn peer_check_needs_first_message() -> bool {
    cfg!(windows)
}

/// #1167：服务端连接上的客户端用户（见 [`PeerUser`]）。别的平台 / 客户端一侧 = `None`。
/// 同步系统调用（Windows 上要模拟客户端），async 调用方放进 `spawn_blocking`。
pub fn local_peer_user<S: LocalPeerSource>(stream: &S) -> Option<PeerUser> {
    stream.peer_user()
}

/// #1167：建常驻 daemon 的命名管道监听（[`crate::ResidentIpc::UserPipe`]）：DACL 只放白名单
/// SID（按主人模型现算）、拒绝网络登录与远程客户端、首实例独占。只有 Windows 有这种形态，
/// 别的平台答 `Unsupported`。
pub fn bind_resident_pipe(
    name: &str,
) -> std::io::Result<interprocess::local_socket::tokio::Listener> {
    imp::bind_resident_pipe(name)
}

/// 以客户端身份连常驻 daemon 的命名管道（[`crate::ResidentIpc::UserPipe`]）。
///
/// Windows：打开管道时声明 `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`，服务端只能
/// 识别客户端身份（读 `TokenUser`），不能以客户端身份行事。interprocess 不暴露这个参数，
/// 所以自己 `CreateFileW` 再交给 interprocess 包装（见 `windows_pipe`）。别的平台没有命名
/// 管道这种形态，按命名空间名照常连接。
pub fn connect_resident_pipe(name: &str) -> std::io::Result<interprocess::local_socket::Stream> {
    connect_imp::connect_sync(name)
}

/// [`connect_resident_pipe`] 的 tokio 版本。
pub async fn connect_resident_pipe_tokio(
    name: &str,
) -> std::io::Result<interprocess::local_socket::tokio::Stream> {
    connect_imp::connect_tokio(name).await
}

#[cfg(windows)]
mod connect_imp {
    pub(super) use crate::windows_pipe::{
        connect_identification_sync as connect_sync, connect_identification_tokio as connect_tokio,
    };
}

#[cfg(not(windows))]
mod connect_imp {
    use interprocess::local_socket::traits::{tokio::Stream as _, Stream as _};
    use interprocess::local_socket::{GenericNamespaced, ToNsName as _};

    pub(super) fn connect_sync(name: &str) -> std::io::Result<interprocess::local_socket::Stream> {
        interprocess::local_socket::Stream::connect(name.to_ns_name::<GenericNamespaced>()?)
    }

    pub(super) async fn connect_tokio(
        name: &str,
    ) -> std::io::Result<interprocess::local_socket::tokio::Stream> {
        interprocess::local_socket::tokio::Stream::connect(name.to_ns_name::<GenericNamespaced>()?)
            .await
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::{PeerCheck, PeerRole, PeerUser};
    use crate::code_signature::code_requirement;
    use core_foundation::base::TCFType;
    use core_foundation::data::CFData;
    use security_framework::os::macos::code_signing::{
        Flags, GuestAttributes, SecCode, SecRequirement,
    };
    use std::os::fd::{AsFd, AsRawFd, RawFd};
    use std::str::FromStr;

    /// `SOL_LOCAL`（sys/un.h）。libc crate 没有导出它。
    const SOL_LOCAL: libc::c_int = 0;

    pub(super) fn check_sync(
        s: &interprocess::local_socket::Stream,
        allowed: &[PeerRole],
        min_version: Option<&str>,
    ) -> PeerCheck {
        #[allow(unreachable_patterns)]
        match s {
            interprocess::local_socket::Stream::UdSocket(u) => {
                check_fd(u.as_fd().as_raw_fd(), allowed, min_version)
            }
            _ => PeerCheck::Rejected("不是 Unix 域套接字".into()),
        }
    }

    pub(super) fn check_tokio(
        s: &interprocess::local_socket::tokio::Stream,
        allowed: &[PeerRole],
        min_version: Option<&str>,
    ) -> PeerCheck {
        #[allow(unreachable_patterns)]
        match s {
            interprocess::local_socket::tokio::Stream::UdSocket(u) => {
                check_fd(u.as_fd().as_raw_fd(), allowed, min_version)
            }
            _ => PeerCheck::Rejected("不是 Unix 域套接字".into()),
        }
    }

    pub(super) fn peer_user_sync(_s: &interprocess::local_socket::Stream) -> Option<PeerUser> {
        None
    }

    pub(super) fn peer_user_tokio(
        _s: &interprocess::local_socket::tokio::Stream,
    ) -> Option<PeerUser> {
        None
    }

    pub(super) fn bind_resident_pipe(
        _name: &str,
    ) -> std::io::Result<interprocess::local_socket::tokio::Listener> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "macOS 的常驻 IPC 是签名 socket，没有命名管道",
        ))
    }

    /// audit_token_t = 8 × u32（xnu bsm/audit.h）。连接建立那一刻由内核记下。
    fn peer_audit_token(fd: RawFd) -> std::io::Result<[u32; 8]> {
        let mut tok = [0u32; 8];
        let mut len = std::mem::size_of::<[u32; 8]>() as libc::socklen_t;
        // SAFETY: tok 是 32 字节的可写缓冲，len 如实给出其大小；fd 由调用方持有的连接借出。
        let r = unsafe {
            libc::getsockopt(
                fd,
                SOL_LOCAL,
                libc::LOCAL_PEERTOKEN,
                tok.as_mut_ptr().cast(),
                &mut len,
            )
        };
        if r != 0 {
            return Err(std::io::Error::last_os_error());
        }
        if len as usize != std::mem::size_of::<[u32; 8]>() {
            return Err(std::io::Error::other(format!("audit token 长度 {len}")));
        }
        Ok(tok)
    }

    fn check_fd(fd: RawFd, allowed: &[PeerRole], min_version: Option<&str>) -> PeerCheck {
        let tok = match peer_audit_token(fd) {
            Ok(t) => t,
            Err(e) => return PeerCheck::Rejected(format!("取不到对端 audit token：{e}")),
        };
        let bytes: Vec<u8> = tok.iter().flat_map(|v| v.to_ne_bytes()).collect();
        let data = CFData::from_buffer(&bytes);
        let mut attrs = GuestAttributes::new();
        attrs.set_audit_token(data.as_concrete_TypeRef());
        let code = match SecCode::copy_guest_with_attribues(None, &attrs, Flags::NONE) {
            Ok(c) => c,
            // exec 换身之后按旧 token 找不到 guest，正落在这里。
            Err(e) => return PeerCheck::Rejected(format!("按 audit token 找不到对端代码：{e}")),
        };
        let mut last = String::from("没有可接受的身份");
        for &role in allowed {
            let req = match SecRequirement::from_str(&code_requirement(role.identifier())) {
                Ok(r) => r,
                Err(e) => return PeerCheck::Rejected(format!("签名要求无效：{e}")),
            };
            match code.check_validity(Flags::NONE, &req) {
                Ok(()) => {
                    // #1150：签名通过之后再核版本下限（版本读自签名封住的 Info.plist）。
                    if let Some(floor) = min_version {
                        let peer = crate::sealed_version::of_guest(&code);
                        if let Err(why) = super::meets_min_version(peer.as_deref().ok(), floor) {
                            let seen = match &peer {
                                Ok(v) => v.clone(),
                                Err(e) => format!("读不到（{e}）"),
                            };
                            return PeerCheck::Rejected(format!(
                                "{}：{why}（对端 {seen}，下限 {floor}）",
                                role.identifier()
                            ));
                        }
                    }
                    return PeerCheck::Verified(role);
                }
                Err(e) => last = format!("不满足 {}：{e}", role.identifier()),
            }
        }
        PeerCheck::Rejected(last)
    }
}

#[cfg(windows)]
mod imp {
    use super::{PeerCheck, PeerRole};
    pub(super) use crate::windows_pipe::{
        bind_resident as bind_resident_pipe, peer_user_sync, peer_user_tokio,
    };

    // #1150 的版本下限读的是**签名封住的**版本号（macOS Info.plist），只有 macOS 有。Windows
    // 按用户 SID 认人（D5：按用户认，不按程序认），对端没有可信的版本可读，下限不适用——
    // 与 Linux 一样忽略这个参数。
    pub(super) fn check_sync(
        s: &interprocess::local_socket::Stream,
        allowed: &[PeerRole],
        _min_version: Option<&str>,
    ) -> PeerCheck {
        crate::windows_pipe::check_sync(s, allowed)
    }

    pub(super) fn check_tokio(
        s: &interprocess::local_socket::tokio::Stream,
        allowed: &[PeerRole],
        _min_version: Option<&str>,
    ) -> PeerCheck {
        crate::windows_pipe::check_tokio(s, allowed)
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
mod imp {
    use super::{PeerCheck, PeerRole, PeerUser};

    const WHY: &str = "本平台不校验 IPC 对端身份（Linux 仍用令牌）";

    pub(super) fn check_sync(
        _s: &interprocess::local_socket::Stream,
        _allowed: &[PeerRole],
        _min_version: Option<&str>,
    ) -> PeerCheck {
        PeerCheck::NotSupported(WHY)
    }

    pub(super) fn check_tokio(
        _s: &interprocess::local_socket::tokio::Stream,
        _allowed: &[PeerRole],
        _min_version: Option<&str>,
    ) -> PeerCheck {
        PeerCheck::NotSupported(WHY)
    }

    pub(super) fn peer_user_sync(_s: &interprocess::local_socket::Stream) -> Option<PeerUser> {
        None
    }

    pub(super) fn peer_user_tokio(
        _s: &interprocess::local_socket::tokio::Stream,
    ) -> Option<PeerUser> {
        None
    }

    pub(super) fn bind_resident_pipe(
        _name: &str,
    ) -> std::io::Result<interprocess::local_socket::tokio::Listener> {
        Err(std::io::Error::new(std::io::ErrorKind::Unsupported, WHY))
    }
}

#[cfg(test)]
mod floor_tests {
    use super::meets_min_version;

    /// 卡面四种情况 + 项目版本语义的两个陷阱。
    /// 反证：把比较换成字符串字典序，`2026.10.10` 那条红；把预发布当「不低于正式版」，
    /// `0.10.0-test.10 vs 0.10.0` 那条红（csreq 的 `>=` 正是这么错的）。
    #[test]
    fn floor_decisions() {
        assert!(
            meets_min_version(Some("0.10.0"), "0.10.1").is_err(),
            "低版本被拒"
        );
        assert!(
            meets_min_version(Some("0.10.1"), "0.10.1").is_ok(),
            "同版本通过"
        );
        assert!(
            meets_min_version(Some("0.10.2"), "0.10.1").is_ok(),
            "高版本通过"
        );
        assert!(meets_min_version(None, "0.10.1").is_err(), "版本缺失被拒");
        assert!(meets_min_version(Some(""), "0.10.1").is_err(), "空串被拒");
        assert!(meets_min_version(Some("  "), "0.10.1").is_err(), "空白被拒");
        assert!(
            meets_min_version(Some("garbage"), "0.10.1").is_err(),
            "垃圾被拒"
        );
        // 不是字典序：
        assert!(meets_min_version(Some("2026.10.10"), "2026.10.9").is_ok());
        assert!(meets_min_version(Some("2026.10.9"), "2026.10.10").is_err());
        assert!(meets_min_version(Some("0.10.0-test.10"), "0.10.0-test.9").is_ok());
        assert!(meets_min_version(Some("0.10.0-test.9"), "0.10.0-test.10").is_err());
        // 预发布 < 正式版（csreq 的 `>=` 判反）：
        assert!(meets_min_version(Some("0.10.0-test.10"), "0.10.0").is_err());
        assert!(meets_min_version(Some("0.10.0"), "0.10.0-test.10").is_ok());
        // 版本串两端的空白不影响：
        assert!(meets_min_version(Some(" 0.10.1 "), "0.10.1").is_ok());
    }

    /// #1918：`UserDirFacts::selection_ready` 不仅要求必填 7 项存在，还必须全部为非空、
    /// 绝对路径、不含 `..`（可选 `library` 若存在也必须同样合法）；同时验证 `PeerUser::with_dirs`
    /// 保留 SID 并替换目录事实。
    /// 反证：把 `selection_ready` 退回只判 `is_some()` ⇒ 相对路径 / 空串 / `..` 全部变 true，红。
    #[test]
    fn user_dir_facts_selection_ready_rejects_relative_empty_and_parent_paths() {
        use super::{PeerUser, UserDirFacts};
        use std::path::PathBuf;

        let host_home = if cfg!(windows) {
            PathBuf::from(r"C:\Users\alice")
        } else {
            PathBuf::from("/Users/alice")
        };
        let host_facts = UserDirFacts::from_home(host_home);
        assert!(host_facts.selection_ready(), "合法宿主绝对路径事实应就绪");

        let win = UserDirFacts {
            home: Some(PathBuf::from(r"C:\Users\alice")),
            desktop: Some(PathBuf::from(r"\\?\C:\Users\alice\Desktop")),
            documents: Some(PathBuf::from(r"D:\Docs")),
            downloads: Some(PathBuf::from(r"C:\Users\alice\Downloads")),
            library: None,
            pictures: Some(PathBuf::from(r"D:\Pictures")),
            videos: Some(PathBuf::from(r"C:\Users\alice\Videos")),
            music: Some(PathBuf::from(r"C:\Users\alice\Music")),
        };
        assert!(win.selection_ready(), "合法 Windows 本地盘符路径应就绪");

        // Windows 下不带盘符的 `/Users/alice` 是驱动器相对路径，必须拒绝。
        if cfg!(windows) {
            let drive_rel = UserDirFacts::from_home(PathBuf::from("/Users/alice"));
            assert!(
                !drive_rel.selection_ready(),
                "Windows 下无盘符路径 /Users/alice 必须被拒"
            );
        }

        for bad in [
            "",
            "   ",
            "relative/path",
            r"Users\alice",
            r"C:relative",
            "/Users/alice/../bob",
            r"C:\Users\..\Public",
            // 安全边界：显式拒绝 UNC 网络共享与 Windows 设备/非盘符命名空间路径，
            // 防止服务账户 canonicalize 触发 NTLM 外连或设备对象访问。
            r"\\attacker\share\Desktop",
            "//attacker/share/Desktop",
            r"\\?\UNC\attacker\share\Desktop",
            r"\\.\pipe\ppf-svc",
            r"\\.\PhysicalDrive0",
            r"\\?\GlobalRoot\Device\HarddiskVolume1\Users",
            r"\\?\Volume{00000000-0000-0000-0000-000000000000}\Users",
        ] {
            let mut f = host_facts.clone();
            f.desktop = Some(PathBuf::from(bad));
            assert!(!f.selection_ready(), "非法 desktop 路径 {bad:?} 必须被拒");

            let mut f_lib = host_facts.clone();
            f_lib.library = Some(PathBuf::from(bad));
            assert!(
                !f_lib.selection_ready(),
                "非法可选 library 路径 {bad:?} 必须被拒"
            );
        }

        let peer = PeerUser::new("S-1-5-21-1".into(), UserDirFacts::default());
        assert!(!peer.dirs().selection_ready());
        let hydrated = peer.with_dirs(win.clone());
        assert_eq!(hydrated.id(), "S-1-5-21-1");
        assert_eq!(hydrated.dirs(), &win);
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use interprocess::local_socket::{prelude::*, GenericFilePath, ListenerOptions};

    /// 测试进程自己（cargo 产出的链接器 ad-hoc 签名）连上来：不是我们的签名程序，拒绝；
    /// 反过来客户端校验监听方（也是测试进程）同样拒绝。
    /// 反证：check_fd 退回「能取到 token 就放行」或要求串去掉 identifier / OID ⇒ 这里变 Verified，红。
    #[test]
    fn an_unsigned_peer_is_rejected_both_ways() {
        let dir = std::env::temp_dir().join(format!("ppf-peer-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.sock");
        let name = path.clone().to_fs_name::<GenericFilePath>().unwrap();
        let listener = ListenerOptions::new()
            .name(name.clone())
            .create_sync()
            .unwrap();
        let client = interprocess::local_socket::Stream::connect(name).unwrap();
        let server_side = listener.accept().unwrap();

        match verify_local_peer(&server_side, &[PeerRole::Shell, PeerRole::Daemon]) {
            PeerCheck::Rejected(why) => assert!(why.contains("不满足"), "{why}"),
            other => panic!("未签名的客户端不该通过：{other:?}"),
        }
        assert!(matches!(
            verify_local_peer(&client, &[PeerRole::Daemon]),
            PeerCheck::Rejected(_)
        ));
        drop((client, server_side, listener));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn roles_map_to_our_two_bundle_ids() {
        assert_eq!(PeerRole::Shell.identifier(), "com.hawkeyexb.ppass.desktop");
        assert_eq!(
            PeerRole::Daemon.identifier(),
            "com.hawkeyexb.ppass.desktop.daemon"
        );
    }
}
