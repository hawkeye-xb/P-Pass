//! D4 / brief §5.2：`%ProgramData%\` 正本存放与目录 ACL 的基础件。
//!
//! 三样东西（身份私钥、配对白名单、照片库位置）必须交给一个和用户不同的安全主体保
//! 管：目录 DACL 只给**服务账户 SID** 与 **Administrators**，受保护、不继承。用户名下
//! 的任何程序——包括恶意程序——都读不到也改不了。
//!
//! 这里只做「目录 / 文件」这一层，不决定服务账户是谁：服务 SID 由调用方给（服务化那张
//! 卡把它算出来）。同理，文件内容不加密、原子替换、`Ok(None)` 的严格语义都在这一层。
//!
//! 失败一律拒绝：`verify` 不通过时 daemon 必须拒绝启动，不回退到用户目录、不重建目录。

use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::ptr;

use windows_sys::Win32::Foundation::{LocalFree, ERROR_SUCCESS};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSidToSidW, GetNamedSecurityInfoW, SetEntriesInAclW,
    SetNamedSecurityInfoW, EXPLICIT_ACCESS_W, NO_MULTIPLE_TRUSTEE, SET_ACCESS, SE_FILE_OBJECT,
    TRUSTEE_IS_SID, TRUSTEE_IS_USER, TRUSTEE_W,
};
use windows_sys::Win32::Security::{
    EqualSid, GetAce, GetSecurityDescriptorControl, ACL, DACL_SECURITY_INFORMATION,
    OWNER_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, PSID, SE_DACL_PROTECTED,
};
use windows_sys::Win32::Storage::FileSystem::{
    MoveFileExW, FILE_ALL_ACCESS, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
};

use crate::{IdentityKeyStore, PlatformError, Result, SecretBlobStore};

/// 服务账户 SID 之外，唯一允许完全控制的 SID。
pub const ADMINISTRATORS_SID: &str = "S-1-5-32-544";

const ALLOWED_ACE_TYPE: u8 = 0;

pub(crate) fn wide(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt as _;
    path.as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn io_err(action: &'static str, source: std::io::Error) -> PlatformError {
    PlatformError::Io { action, source }
}

fn failed(action: &'static str, detail: impl Into<String>) -> PlatformError {
    PlatformError::Failed {
        action,
        detail: detail.into(),
    }
}

/// SID 字符串 → 系统分配的 SID（调用方用 [`free_sid`] 释放）。
pub(crate) fn sid_from_string(sid: &str) -> Result<PSID> {
    let wide_sid: Vec<u16> = sid.encode_utf16().chain(std::iter::once(0)).collect();
    let mut out: PSID = ptr::null_mut();
    // SAFETY: wide_sid 是 NUL 结尾的宽字符串；成功时 out 由 LocalAlloc 分配。
    let ok = unsafe { ConvertStringSidToSidW(wide_sid.as_ptr(), &mut out) };
    if ok == 0 || out.is_null() {
        return Err(failed(
            "ConvertStringSidToSidW",
            format!("SID 不合法：{sid}"),
        ));
    }
    Ok(out)
}

/// SAFETY: `sid` 必须来自 [`sid_from_string`] 或 `GetNamedSecurityInfoW` 的临时缓冲。
pub(crate) unsafe fn free_sid(sid: PSID) {
    if !sid.is_null() {
        LocalFree(sid.cast());
    }
}

pub(crate) unsafe fn sid_to_string(sid: PSID) -> String {
    let mut out: *mut u16 = ptr::null_mut();
    if ConvertSidToStringSidW(sid, &mut out) == 0 || out.is_null() {
        return "<unknown sid>".into();
    }
    let mut len = 0usize;
    while *out.add(len) != 0 {
        len += 1;
    }
    let s = String::from_utf16_lossy(std::slice::from_raw_parts(out, len));
    LocalFree(out.cast());
    s
}

/// 当前进程用户的 SID 字符串（安装器不一定在跑；这个给日志与默认值用）。
pub fn current_user_sid_string() -> Result<String> {
    use windows_sys::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    let mut token = std::ptr::null_mut();
    // SAFETY: 拿自己进程的令牌，句柄成功时有效，下面关闭。
    unsafe {
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(io_err("OpenProcessToken", std::io::Error::last_os_error()));
        }
        let mut needed = 0u32;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut needed);
        let mut buf = vec![0u8; needed.max(128) as usize];
        let ok = GetTokenInformation(
            token,
            TokenUser,
            buf.as_mut_ptr().cast::<c_void>(),
            buf.len() as u32,
            &mut needed,
        );
        let _ = windows_sys::Win32::Foundation::CloseHandle(token);
        if ok == 0 {
            return Err(io_err(
                "GetTokenInformation",
                std::io::Error::last_os_error(),
            ));
        }
        let tu = &*(buf.as_ptr() as *const TOKEN_USER);
        Ok(sid_to_string(tu.User.Sid))
    }
}

/// `%ProgramData%\P-Pass`：服务模式（D1）下 daemon 唯一的数据根。
///
/// 服务账户 `NT SERVICE\<服务名>` 没有属于用户的配置文件，`%LOCALAPPDATA%` /
/// `%APPDATA%` 指向 `C:\Windows\ServiceProfiles\` 下它读不到的地方——身份私钥、
/// 配对白名单、库位置、配置、日志、索引全部落在本函数给的目录里。
pub fn service_root() -> PathBuf {
    std::env::var_os("ProgramData")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"))
        .join("P-Pass")
}

/// 账户名（如 `NT SERVICE\P-Pass`）→ SID 字符串。
///
/// 虚拟服务账户的 SID 由服务名派生，**不需要服务真的装着**；所以安装器可以在
/// `sc create` 之后立刻用它核对目录 ACL，daemon 也能在启动时自己算出来核对。
pub fn account_sid_string(account: &str) -> Result<String> {
    use windows_sys::Win32::Security::{LookupAccountNameW, SID_NAME_USE};

    let name: Vec<u16> = account.encode_utf16().chain(std::iter::once(0)).collect();
    let mut sid_len = 0u32;
    let mut domain_len = 0u32;
    let mut use_: SID_NAME_USE = 0;
    // SAFETY: name 是 NUL 结尾的宽字符串；第一次只取所需长度。
    unsafe {
        LookupAccountNameW(
            ptr::null(),
            name.as_ptr(),
            ptr::null_mut(),
            &mut sid_len,
            ptr::null_mut(),
            &mut domain_len,
            &mut use_,
        );
    }
    if sid_len == 0 {
        return Err(failed(
            "LookupAccountNameW",
            format!("查不到账户 {account}（SID 长度 0）"),
        ));
    }
    let mut sid = vec![0u8; sid_len as usize];
    let mut domain = vec![0u16; domain_len.max(1) as usize];
    // SAFETY: 两个缓冲都按上面回报的长度分配。
    let ok = unsafe {
        LookupAccountNameW(
            ptr::null(),
            name.as_ptr(),
            sid.as_mut_ptr().cast(),
            &mut sid_len,
            domain.as_mut_ptr(),
            &mut domain_len,
            &mut use_,
        )
    };
    if ok == 0 {
        return Err(io_err(
            "LookupAccountNameW",
            std::io::Error::last_os_error(),
        ));
    }
    // SAFETY: sid 是上面填充的合法 SID，长度足够。
    Ok(unsafe { sid_to_string(sid.as_mut_ptr().cast()) })
}

/// 服务模式下 daemon 启动前的硬核对（brief §5.2）。
///
/// 核对 [`service_root`] 的 ACL：属主是 Administrators / 服务账户、DACL 受保护、
/// ACE 白名单只有这两个 SID。**不通过就拒绝启动**——不回退用户目录、不重建目录。
pub fn verify_service_root() -> Result<PathBuf> {
    let root = service_root();
    let account = format!(r"NT SERVICE\{}", crate::windows_service::SERVICE_NAME);
    let sid = account_sid_string(&account)?;
    ProgramDataDir::verify(&root, &sid)?;
    Ok(root)
}

/// `%ProgramData%\<name>` 目录本身：建、核对。
pub struct ProgramDataDir;

impl ProgramDataDir {
    /// 建目录并把 DACL 收成「服务 SID + Administrators，受保护、不继承」。
    ///
    /// 幂等：目录已存在就只重设 DACL。写入用「显式 ACL 覆盖」，不保留任何继承来的 ACE。
    pub fn create(dir: &Path, service_sid: &str) -> Result<()> {
        std::fs::create_dir_all(dir).map_err(|e| io_err("create_programdata_dir", e))?;
        set_private_dacl(dir, &[service_sid, ADMINISTRATORS_SID])
    }

    /// 启动时核对：属主 ∈ {Administrators, SYSTEM}、受保护 DACL、ACE 只指向白名单 SID。
    ///
    /// 任何一条不满足都 `Err`——daemon 据此拒绝启动（brief §5.2）。这里**不**试图修，
    /// 修是安装器 / 显式管理操作的事。
    pub fn verify(dir: &Path, service_sid: &str) -> Result<()> {
        let meta = std::fs::symlink_metadata(dir).map_err(|e| io_err("stat_programdata_dir", e))?;
        if meta.file_type().is_symlink() {
            return Err(failed("verify_programdata_dir", "目录是符号链接"));
        }
        if !meta.is_dir() {
            return Err(failed("verify_programdata_dir", "不是目录"));
        }

        let service = sid_from_string(service_sid)?;
        let admins = sid_from_string(ADMINISTRATORS_SID)?;
        let allowed = [service, admins];
        let result = (|| -> Result<()> {
            let w = wide(dir);
            let mut owner: PSID = ptr::null_mut();
            let mut dacl: *mut ACL = ptr::null_mut();
            let mut sd: PSID = ptr::null_mut();
            // SAFETY: w 是 NUL 结尾；成功时 sd 由 LocalAlloc，owner/dacl 指向 sd 内部，
            // 到函数结束前都有效。
            let rc = unsafe {
                GetNamedSecurityInfoW(
                    w.as_ptr(),
                    SE_FILE_OBJECT,
                    OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                    &mut owner,
                    ptr::null_mut(),
                    &mut dacl,
                    ptr::null_mut(),
                    &mut sd,
                )
            };
            if rc != ERROR_SUCCESS || sd.is_null() {
                return Err(io_err(
                    "GetNamedSecurityInfoW",
                    std::io::Error::from_raw_os_error(rc as i32),
                ));
            }
            let outcome = (|| -> Result<()> {
                // 属主必须不是普通用户：D4 的目录由安装器（提权）建，属主是管理员组或 SYSTEM。
                let owner_sid = unsafe { sid_to_string(owner) };
                let owner_is_ok =
                    unsafe { EqualSid(owner, allowed[0]) != 0 || EqualSid(owner, allowed[1]) != 0 };
                if !owner_is_ok {
                    return Err(failed(
                        "verify_programdata_dir",
                        format!("目录属主是 {owner_sid}，应为 Administrators 或服务账户"),
                    ));
                }

                let mut control = 0u16;
                let mut revision = 0u32;
                // SAFETY: sd 是上面拿到的合法安全描述符。
                unsafe { GetSecurityDescriptorControl(sd, &mut control, &mut revision) };
                if control & SE_DACL_PROTECTED == 0 {
                    return Err(failed(
                        "verify_programdata_dir",
                        "DACL 没有受保护（还在继承父目录 ACE）",
                    ));
                }

                if dacl.is_null() {
                    return Err(failed("verify_programdata_dir", "目录没有 DACL"));
                }
                // SAFETY: dacl 指向 sd 内部的合法 ACL。
                let ace_count = unsafe { (*dacl).AceCount } as u32;
                for i in 0..ace_count {
                    let mut ace: *mut c_void = ptr::null_mut();
                    // SAFETY: dacl 合法、i < AceCount。
                    if unsafe { GetAce(dacl, i, &mut ace) } == 0 || ace.is_null() {
                        return Err(failed("verify_programdata_dir", "读 ACE 失败"));
                    }
                    let header =
                        unsafe { &*(ace as *const windows_sys::Win32::Security::ACE_HEADER) };
                    if header.AceType != ALLOWED_ACE_TYPE {
                        return Err(failed(
                            "verify_programdata_dir",
                            format!("DACL 里有非允许型 ACE（type {}）", header.AceType),
                        ));
                    }
                    // ACCESS_ALLOWED_ACE：ACE_HEADER(4) + Mask(4) + SidStart，SID 从 +8 开始。
                    let sid = unsafe { (ace as *const u8).add(8) as PSID };
                    let is_allowed =
                        unsafe { EqualSid(sid, allowed[0]) != 0 || EqualSid(sid, allowed[1]) != 0 };
                    if !is_allowed {
                        let who = unsafe { sid_to_string(sid) };
                        return Err(failed(
                            "verify_programdata_dir",
                            format!("DACL 里有白名单之外的 ACE：{who}"),
                        ));
                    }
                }
                Ok(())
            })();
            // SAFETY: sd 由 GetNamedSecurityInfoW 分配。
            unsafe { LocalFree(sd.cast()) };
            outcome
        })();
        unsafe {
            free_sid(service);
            free_sid(admins);
        }
        result
    }
}

/// 用显式访问表覆盖 DACL，并打上「受保护」标记（不再继承）。
fn set_private_dacl(path: &Path, sids: &[&str]) -> Result<()> {
    let mut allocated: Vec<PSID> = Vec::with_capacity(sids.len());
    let result = (|| -> Result<()> {
        let mut entries = Vec::with_capacity(sids.len());
        for sid_text in sids {
            let sid = sid_from_string(sid_text)?;
            allocated.push(sid);
            entries.push(EXPLICIT_ACCESS_W {
                grfAccessPermissions: FILE_ALL_ACCESS,
                grfAccessMode: SET_ACCESS,
                grfInheritance: windows_sys::Win32::Security::SUB_CONTAINERS_AND_OBJECTS_INHERIT,
                Trustee: TRUSTEE_W {
                    pMultipleTrustee: ptr::null_mut(),
                    MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
                    TrusteeForm: TRUSTEE_IS_SID,
                    TrusteeType: TRUSTEE_IS_USER,
                    // TRUSTEE_IS_SID 时这个字段装 SID 指针。
                    ptstrName: sid.cast(),
                },
            });
        }
        let mut acl: *mut ACL = ptr::null_mut();
        // SAFETY: entries 与它指向的 SID 在调用期间存活；oldacl=null 表示不保留旧 ACE。
        let rc = unsafe {
            SetEntriesInAclW(
                entries.len() as u32,
                entries.as_ptr(),
                ptr::null(),
                &mut acl,
            )
        };
        if rc != ERROR_SUCCESS {
            return Err(io_err(
                "SetEntriesInAclW",
                std::io::Error::from_raw_os_error(rc as i32),
            ));
        }
        let w = wide(path);
        // SAFETY: acl 是刚建好的合法 ACL；只改 DACL 并设受保护位。
        let rc = unsafe {
            SetNamedSecurityInfoW(
                w.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                ptr::null_mut(),
                ptr::null_mut(),
                acl,
                ptr::null(),
            )
        };
        unsafe { LocalFree(acl.cast()) };
        if rc != ERROR_SUCCESS {
            return Err(io_err(
                "SetNamedSecurityInfoW",
                std::io::Error::from_raw_os_error(rc as i32),
            ));
        }
        Ok(())
    })();
    unsafe {
        for sid in allocated {
            free_sid(sid);
        }
    }
    result
}

/// 一条整份读写的正本文件（`identity.key` / `pairings.json` / `library.json`）。
pub struct ProgramDataStore {
    path: PathBuf,
    what: &'static str,
}

impl ProgramDataStore {
    pub fn new(path: impl Into<PathBuf>, what: &'static str) -> Self {
        Self {
            path: path.into(),
            what,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// 整份读取。只有**确定不存在**是 Ok(None)，其余错误一律 Err。
    pub fn read(&self) -> Result<Option<Vec<u8>>> {
        self.read_impl()
    }

    /// 整份写入（临时文件 → 刷盘 → 原子替换）。
    pub fn write(&self, bytes: &[u8]) -> Result<()> {
        self.write_impl(bytes)
    }

    /// 删掉；本来就没有不算错。
    pub fn delete(&self) -> Result<()> {
        match std::fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(io_err("delete_programdata_blob", e)),
        }
    }

    /// 「读不到」与「确实没有」的分界：只有 `NotFound` 是 `Ok(None)`。
    fn read_impl(&self) -> Result<Option<Vec<u8>>> {
        match std::fs::read(&self.path) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(io_err("read_programdata_blob", e)),
        }
    }

    /// 写临时文件 → 刷盘 → 原子替换。失败时删掉临时文件，不留半份正本。
    fn write_impl(&self, bytes: &[u8]) -> Result<()> {
        use std::io::Write as _;

        let tmp =
            self.path
                .with_extension(format!("tmp.{}.{}", std::process::id(), monotonic_nonce()));
        let write = (|| -> std::io::Result<()> {
            let mut f = std::fs::File::create(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
            Ok(())
        })();
        if let Err(e) = write {
            let _ = std::fs::remove_file(&tmp);
            return Err(io_err("write_programdata_blob", e));
        }
        let from = wide(&tmp);
        let to = wide(&self.path);
        // SAFETY: 两个都是 NUL 结尾的宽路径；MOVEFILE_WRITE_THROUGH 保证换名落盘。
        let ok = unsafe {
            MoveFileExW(
                from.as_ptr(),
                to.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        };
        if ok == 0 {
            let e = std::io::Error::last_os_error();
            let _ = std::fs::remove_file(&tmp);
            return Err(io_err("replace_programdata_blob", e));
        }
        Ok(())
    }
}

fn monotonic_nonce() -> u128 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    t ^ (u128::from(n) << 96)
}

impl IdentityKeyStore for ProgramDataStore {
    fn read(&self) -> Result<Option<Vec<u8>>> {
        ProgramDataStore::read(self)
    }

    fn write(&self, secret: &[u8]) -> Result<()> {
        ProgramDataStore::write(self, secret)
    }

    fn location(&self) -> String {
        format!("{}（{}）", self.path.display(), self.what)
    }
}

impl SecretBlobStore for ProgramDataStore {
    fn read(&self) -> Result<Option<Vec<u8>>> {
        ProgramDataStore::read(self)
    }

    fn write(&self, bytes: &[u8]) -> Result<()> {
        ProgramDataStore::write(self, bytes)
    }

    fn delete(&self) -> Result<()> {
        ProgramDataStore::delete(self)
    }

    fn location(&self) -> String {
        format!("{}（{}）", self.path.display(), self.what)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> tempfile::TempDir {
        tempfile::Builder::new()
            .prefix("ppass-programdata-")
            .tempdir()
            .expect("tempdir")
    }

    /// 测试里把「当前用户」当成服务账户：这台机器上没有服务 SID 时也能验证同一套 ACL 逻辑。
    fn test_sid() -> String {
        current_user_sid_string().expect("current sid")
    }

    /// D4：虚拟服务账户的 SID 由服务名派生，不用服务真的装着也能算出来；
    /// 且必须与当前用户 SID 不同——正是这个「不同」才让 ProgramData 的 ACL 有意义。
    #[test]
    fn service_account_resolves_to_its_own_sid() {
        let sid = account_sid_string(r"NT SERVICE\P-Pass").expect("lookup");
        assert!(sid.starts_with("S-1-5-80-"), "{sid}");
        assert_ne!(sid, test_sid());
    }

    /// 反证：不存在的账户名必须报错，不能编一个 SID 出来。
    #[test]
    fn unknown_account_is_an_error() {
        assert!(account_sid_string(r"NT SERVICE\PPassNoSuchService").is_err());
    }

    /// 数据根就是安装器用的那一处（`%ProgramData%\P-Pass`）。
    #[test]
    fn service_root_is_under_programdata() {
        assert_eq!(service_root().file_name().unwrap(), "P-Pass");
        assert_eq!(
            service_root().parent().unwrap().file_name().unwrap(),
            "ProgramData"
        );
    }

    #[test]
    fn create_and_verify_roundtrip() {
        let d = tempdir();
        ProgramDataDir::create(d.path(), &test_sid()).expect("create");
        ProgramDataDir::verify(d.path(), &test_sid()).expect("verify");
    }

    /// 反证：普通临时目录（继承父目录、带 Users 的 ACE）必须核对失败。
    #[test]
    fn verify_rejects_an_inherited_dacl() {
        let d = tempdir();
        let err = ProgramDataDir::verify(d.path(), &test_sid()).unwrap_err();
        let text = format!("{err}");
        assert!(
            text.contains("受保护") || text.contains("白名单") || text.contains("属主"),
            "{text}"
        );
    }

    /// 反证：多一条 Users 的允许 ACE 必须被拒。
    #[test]
    fn verify_rejects_an_extra_allow_ace() {
        let d = tempdir();
        ProgramDataDir::create(d.path(), &test_sid()).expect("create");
        // 再加一条 BUILTIN\Users 的 ACE（受保护 DACL 保持在，但白名单被破坏）。
        let users = sid_from_string("S-1-5-32-545").unwrap();
        let access = EXPLICIT_ACCESS_W {
            grfAccessPermissions: FILE_ALL_ACCESS,
            grfAccessMode: SET_ACCESS,
            grfInheritance: 0,
            Trustee: TRUSTEE_W {
                pMultipleTrustee: ptr::null_mut(),
                MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_USER,
                ptstrName: users.cast(),
            },
        };
        let w = wide(d.path());
        let mut owner: PSID = ptr::null_mut();
        let mut old: *mut ACL = ptr::null_mut();
        let mut sd: PSID = ptr::null_mut();
        unsafe {
            let rc = GetNamedSecurityInfoW(
                w.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                &mut owner,
                ptr::null_mut(),
                &mut old,
                ptr::null_mut(),
                &mut sd,
            );
            assert_eq!(rc, ERROR_SUCCESS);
            let mut new_acl: *mut ACL = ptr::null_mut();
            let rc = SetEntriesInAclW(1, &access, old, &mut new_acl);
            assert_eq!(rc, ERROR_SUCCESS);
            let rc = SetNamedSecurityInfoW(
                w.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                ptr::null_mut(),
                ptr::null_mut(),
                new_acl,
                ptr::null(),
            );
            assert_eq!(rc, ERROR_SUCCESS);
            LocalFree(new_acl.cast());
            LocalFree(sd.cast());
            free_sid(users);
        }
        let err = ProgramDataDir::verify(d.path(), &test_sid()).unwrap_err();
        let text = format!("{err}");
        assert!(text.contains("白名单"), "{text}");
    }

    #[test]
    fn store_roundtrip_and_missing_is_none() {
        let d = tempdir();
        ProgramDataDir::create(d.path(), &test_sid()).expect("create");
        let store = ProgramDataStore::new(d.path().join("pairings.json"), "pairings");
        assert!(store.read().expect("read missing").is_none());
        store.write(b"first").expect("write");
        assert_eq!(
            store.read().expect("read").as_deref(),
            Some(b"first".as_slice())
        );
        store.write(b"second").expect("rewrite");
        assert_eq!(
            store.read().expect("read").as_deref(),
            Some(b"second".as_slice())
        );
        store.delete().expect("delete");
        assert!(store.read().expect("read after delete").is_none());
        store.delete().expect("delete idempotent");
    }

    /// 「读不出来」不是「没有」：把正本路径做成目录，必须 `Err` 而不是 `Ok(None)`。
    #[test]
    fn read_error_is_not_none() {
        let d = tempdir();
        let path = d.path().join("identity.key");
        std::fs::create_dir(&path).unwrap();
        let store = ProgramDataStore::new(&path, "identity");
        assert!(store.read().is_err(), "读到目录必须 Err");
    }

    /// 原子替换：成功后不留临时文件，内容是最新那份。
    #[test]
    fn atomic_replace_leaves_no_temp_files() {
        let d = tempdir();
        ProgramDataDir::create(d.path(), &test_sid()).expect("create");
        let store = ProgramDataStore::new(d.path().join("library.json"), "library");
        store.write(b"a").expect("write a");
        store.write(b"bb").expect("write bb");
        let names: Vec<String> = std::fs::read_dir(d.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["library.json".to_string()], "{names:?}");
        assert_eq!(store.read().unwrap().as_deref(), Some(b"bb".as_slice()));
    }
}
