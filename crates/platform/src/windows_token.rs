//! 读令牌里的特权清单，供服务启动核对（判定口径见 [`crate::service_privileges`]）。

use std::ffi::c_void;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, LUID};
use windows_sys::Win32::Security::{
    GetTokenInformation, LookupPrivilegeNameW, TokenPrivileges, LUID_AND_ATTRIBUTES, TOKEN_QUERY,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

use crate::service_privileges::{judge_service_privileges, ServicePrivilegeVerdict};
use crate::{PlatformError, Result};

fn io_err(action: &'static str) -> PlatformError {
    PlatformError::Io {
        action,
        source: std::io::Error::last_os_error(),
    }
}

/// 令牌里**存在**的全部特权名（启用与否都算）。句柄需 `TOKEN_QUERY`，由调用方关闭。
pub(crate) fn token_privilege_names(token: HANDLE) -> Result<Vec<String>> {
    // SAFETY: token 由调用方保证有效；缓冲按回报长度分配并 8 字节对齐。
    unsafe {
        let mut needed = 0u32;
        GetTokenInformation(token, TokenPrivileges, std::ptr::null_mut(), 0, &mut needed);
        let mut buf = vec![0u64; (needed.max(64) as usize).div_ceil(8)];
        if GetTokenInformation(
            token,
            TokenPrivileges,
            buf.as_mut_ptr().cast::<c_void>(),
            (buf.len() * 8) as u32,
            &mut needed,
        ) == 0
        {
            return Err(io_err("GetTokenInformation(TokenPrivileges)"));
        }
        // TOKEN_PRIVILEGES = { PrivilegeCount: u32, Privileges: [LUID_AND_ATTRIBUTES; N] }；
        // 数组按 4 字节对齐紧跟在计数后面（LUID_AND_ATTRIBUTES 只含 u32 / i32）。
        let base = buf.as_ptr().cast::<u8>();
        let count = *(base as *const u32) as usize;
        let entries = base.add(4) as *const LUID_AND_ATTRIBUTES;
        let mut out = Vec::with_capacity(count);
        for i in 0..count {
            let luid: LUID = (*entries.add(i)).Luid;
            out.push(privilege_name(&luid)?);
        }
        Ok(out)
    }
}

fn privilege_name(luid: &LUID) -> Result<String> {
    let mut name = vec![0u16; 64];
    let mut len = name.len() as u32;
    // SAFETY: name 是可写缓冲，len 是它的字符数；失败时按回报长度重试一次。
    unsafe {
        if LookupPrivilegeNameW(std::ptr::null(), luid, name.as_mut_ptr(), &mut len) == 0 {
            name = vec![0u16; len as usize + 1];
            len = name.len() as u32;
            if LookupPrivilegeNameW(std::ptr::null(), luid, name.as_mut_ptr(), &mut len) == 0 {
                return Err(io_err("LookupPrivilegeNameW"));
            }
        }
    }
    Ok(String::from_utf16_lossy(&name[..len as usize]))
}

/// 本进程令牌里的特权名。
pub fn current_process_privilege_names() -> Result<Vec<String>> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: 取自己进程的令牌；成功时句柄有效，下面关闭。
    unsafe {
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(io_err("OpenProcessToken"));
        }
        let out = token_privilege_names(token);
        CloseHandle(token);
        out
    }
}

/// 服务启动核对：读本进程令牌并判定。出现禁止特权 ⇒ `Err`（调用方拒绝启动）；
/// 否则返回判定结果，`unexpected` 由调用方写日志。
pub fn verify_service_token() -> Result<ServicePrivilegeVerdict> {
    let verdict = judge_service_privileges(&current_process_privilege_names()?);
    if verdict.is_allowed() {
        Ok(verdict)
    } else {
        Err(PlatformError::Failed {
            action: "verify_service_token",
            detail: format!(
                "服务令牌带有不该有的特权：{}（安装器应以 sc privs 收窄，请重新安装 P-Pass）",
                verdict.forbidden.join(", ")
            ),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows_sys::Win32::Security::{
        AdjustTokenPrivileges, DuplicateTokenEx, SecurityImpersonation, TokenPrimary,
        SE_PRIVILEGE_REMOVED, TOKEN_ADJUST_PRIVILEGES, TOKEN_DUPLICATE, TOKEN_PRIVILEGES,
    };

    /// 本进程令牌的一份可改副本（改它不影响同进程里的其他测试）。
    fn duplicated_process_token() -> HANDLE {
        unsafe {
            let mut token: HANDLE = std::ptr::null_mut();
            assert_ne!(
                OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE, &mut token),
                0,
                "{}",
                std::io::Error::last_os_error()
            );
            let mut dup: HANDLE = std::ptr::null_mut();
            let ok = DuplicateTokenEx(
                token,
                TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES,
                std::ptr::null(),
                SecurityImpersonation,
                TokenPrimary,
                &mut dup,
            );
            CloseHandle(token);
            assert_ne!(ok, 0, "{}", std::io::Error::last_os_error());
            dup
        }
    }

    /// 从令牌里**移除**（不是禁用）一个特权——与 `sc privs` 收窄后的效果相同。
    fn remove_privilege(token: HANDLE, name: &str) {
        let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        unsafe {
            let mut luid = LUID {
                LowPart: 0,
                HighPart: 0,
            };
            assert_ne!(
                windows_sys::Win32::Security::LookupPrivilegeValueW(
                    std::ptr::null(),
                    wide.as_ptr(),
                    &mut luid
                ),
                0
            );
            let tp = TOKEN_PRIVILEGES {
                PrivilegeCount: 1,
                Privileges: [LUID_AND_ATTRIBUTES {
                    Luid: luid,
                    Attributes: SE_PRIVILEGE_REMOVED,
                }],
            };
            assert_ne!(
                AdjustTokenPrivileges(token, 0, &tp, 0, std::ptr::null_mut(), std::ptr::null_mut()),
                0,
                "{}",
                std::io::Error::last_os_error()
            );
        }
    }

    /// 任何令牌都带 SeChangeNotifyPrivilege；读出来的名字是系统的规范写法。
    #[test]
    fn service_token_privileges_are_read_from_the_real_token() {
        let names = current_process_privilege_names().expect("read");
        assert!(
            names.iter().any(|n| n == "SeChangeNotifyPrivilege"),
            "{names:?}"
        );
    }

    /// 把令牌收窄到白名单（等价于 `sc privs <白名单>` 之后的服务令牌）⇒ 判定通过、没有多余项。
    /// 反证：本进程令牌若带着禁止特权（管理员 runner 通常有），收窄前判定必须拒绝。
    #[test]
    fn service_token_narrowed_to_allowlist_passes_and_unnarrowed_is_judged_honestly() {
        let token = duplicated_process_token();
        let before = token_privilege_names(token).expect("read before");
        let before_verdict = judge_service_privileges(&before);
        let has_forbidden = before.iter().any(|n| {
            crate::service_privileges::FORBIDDEN_SERVICE_PRIVILEGES
                .iter()
                .any(|f| f == n)
        });
        assert_eq!(
            before_verdict.is_allowed(),
            !has_forbidden,
            "{before:?} → {before_verdict:?}"
        );
        for name in &before {
            if !crate::service_privileges::SERVICE_PRIVILEGE_ALLOWLIST.contains(&name.as_str()) {
                remove_privilege(token, name);
            }
        }
        let after = token_privilege_names(token).expect("read after");
        unsafe { CloseHandle(token) };
        assert_eq!(after, vec!["SeChangeNotifyPrivilege".to_string()]);
        let v = judge_service_privileges(&after);
        assert!(v.is_allowed() && v.unexpected.is_empty(), "{v:?}");
    }
}
