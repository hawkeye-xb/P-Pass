//! D2 / brief §5.3：照片库目录授权给服务账户。
//!
//! 服务账户默认读写不了用户目录。用户在向导/设置里选好目录后，壳以**主人身份**给该目录
//! 加一条授予服务 SID「修改」的 ACE（可继承），目录归主人所有时不需要提权；失败时（属主
//! 不是主人、来自别的电脑的 NTFS 盘）把错误原样交给调用方去决定要不要弹 UAC。
//!
//! exFAT / FAT32 没有 ACL：按 brief 跳过（[`GrantOutcome::SkippedNoAcl`]），不假装成功。
//! 网络路径本期不支持，明确拒绝。

use std::path::Path;

use windows_sys::Win32::Foundation::{LocalFree, ERROR_ACCESS_DENIED, ERROR_SUCCESS};
use windows_sys::Win32::Security::Authorization::{
    GetNamedSecurityInfoW, SetEntriesInAclW, SetNamedSecurityInfoW, EXPLICIT_ACCESS_W,
    NO_MULTIPLE_TRUSTEE, SET_ACCESS, SE_FILE_OBJECT, TRUSTEE_IS_SID, TRUSTEE_IS_USER, TRUSTEE_W,
};
use windows_sys::Win32::Security::{
    EqualSid, GetAce, ACL, DACL_SECURITY_INFORMATION, SUB_CONTAINERS_AND_OBJECTS_INHERIT,
};
use windows_sys::Win32::Storage::FileSystem::{
    GetVolumeInformationW, GetVolumePathNameW, DELETE, FILE_GENERIC_EXECUTE, FILE_GENERIC_READ,
    FILE_GENERIC_WRITE,
};

use crate::windows_programdata::{free_sid, sid_from_string, sid_to_string, wide};
use crate::{PlatformError, Result};

/// 「修改」= 读 + 写 + 执行 + 删；与资源管理器里「修改」一档对齐。
const MODIFY_MASK: u32 = FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_GENERIC_EXECUTE | DELETE;

/// 授权结果。不是 `Result<()>`：exFAT 上「没有 ACL 可加」不是失败，是平台事实。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GrantOutcome {
    /// ACE 已经在了，或刚加上并且回读确认过。
    Done,
    /// 卷没有 ACL（FAT/FAT32/exFAT），跳过。
    SkippedNoAcl { file_system: String },
}

/// 给 `dir` 加一条「服务 SID 可修改、可继承」的 ACE（幂等，保留原有 ACE）。
///
/// 失败时把系统错误原样带上：调用方据此区分「权限不够，值得弹一次 UAC」与「盘不归我」。
pub fn grant_modify_for_sid(dir: &Path, service_sid: &str) -> Result<GrantOutcome> {
    if is_network_path(dir) {
        return Err(failed(
            "grant_photo_dir",
            "网络路径（NAS/共享盘）本期不支持，请选本机磁盘上的目录",
        ));
    }
    let meta = std::fs::symlink_metadata(dir).map_err(|e| PlatformError::Io {
        action: "stat_photo_dir",
        source: e,
    })?;
    if !meta.is_dir() {
        return Err(failed("grant_photo_dir", "选的不是目录"));
    }
    if let Some(fs) = file_system_of(dir) {
        let normalized = fs.to_ascii_uppercase();
        if !matches!(normalized.as_str(), "NTFS" | "REFS") {
            return Ok(GrantOutcome::SkippedNoAcl { file_system: fs });
        }
    }

    let sid = sid_from_string(service_sid)?;
    let result = (|| -> Result<GrantOutcome> {
        let w = wide(dir);
        let mut dacl: *mut ACL = std::ptr::null_mut();
        let mut sd: *mut std::ffi::c_void = std::ptr::null_mut();
        // SAFETY: w 是 NUL 结尾的宽路径；sd 由 LocalAlloc，下面释放。
        let rc = unsafe {
            GetNamedSecurityInfoW(
                w.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut dacl,
                std::ptr::null_mut(),
                &mut sd,
            )
        };
        if rc != ERROR_SUCCESS {
            return Err(io_err("GetNamedSecurityInfoW", rc));
        }
        let outcome = (|| -> Result<GrantOutcome> {
            if unsafe { has_modify_ace(dacl, sid) } {
                return Ok(GrantOutcome::Done);
            }
            let access = EXPLICIT_ACCESS_W {
                grfAccessPermissions: MODIFY_MASK,
                grfAccessMode: SET_ACCESS,
                grfInheritance: SUB_CONTAINERS_AND_OBJECTS_INHERIT,
                Trustee: TRUSTEE_W {
                    pMultipleTrustee: std::ptr::null_mut(),
                    MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
                    TrusteeForm: TRUSTEE_IS_SID,
                    TrusteeType: TRUSTEE_IS_USER,
                    ptstrName: sid.cast(),
                },
            };
            let mut new_acl: *mut ACL = std::ptr::null_mut();
            // SAFETY: access 与其 SID 在调用期间存活；old 是上面拿到的 DACL。
            let rc = unsafe { SetEntriesInAclW(1, &access, dacl, &mut new_acl) };
            if rc != ERROR_SUCCESS {
                return Err(io_err("SetEntriesInAclW", rc));
            }
            // SAFETY: new_acl 是合法 ACL；只改 DACL，不动 owner/group/SACL，也不设受保护位
            // （照片目录要保留继承——文件本身仍要让主人能读）。
            let rc = unsafe {
                SetNamedSecurityInfoW(
                    w.as_ptr(),
                    SE_FILE_OBJECT,
                    DACL_SECURITY_INFORMATION,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    new_acl,
                    std::ptr::null(),
                )
            };
            unsafe { LocalFree(new_acl.cast()) };
            if rc == ERROR_ACCESS_DENIED {
                return Err(failed(
                    "grant_photo_dir",
                    "目录不归当前用户所有，改 DACL 需要管理员权限",
                ));
            }
            if rc != ERROR_SUCCESS {
                return Err(io_err("SetNamedSecurityInfoW", rc));
            }
            // 回读确认：判据是真实 DACL，不是 SetNamedSecurityInfoW 的返回值。
            let mut check_dacl: *mut ACL = std::ptr::null_mut();
            let mut check_sd: *mut std::ffi::c_void = std::ptr::null_mut();
            let rc = unsafe {
                GetNamedSecurityInfoW(
                    w.as_ptr(),
                    SE_FILE_OBJECT,
                    DACL_SECURITY_INFORMATION,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut check_dacl,
                    std::ptr::null_mut(),
                    &mut check_sd,
                )
            };
            if rc != ERROR_SUCCESS {
                return Err(io_err("GetNamedSecurityInfoW", rc));
            }
            let ok = unsafe { has_modify_ace(check_dacl, sid) };
            unsafe { LocalFree(check_sd.cast()) };
            if !ok {
                return Err(failed("grant_photo_dir", "写 ACE 后回读没有找到"));
            }
            Ok(GrantOutcome::Done)
        })();
        unsafe { LocalFree(sd.cast()) };
        outcome
    })();
    unsafe { free_sid(sid) };
    result
}

fn is_network_path(dir: &Path) -> bool {
    let text = dir.to_string_lossy();
    text.starts_with(r"\\")
}

/// 目录所在卷的文件系统名（"NTFS" / "exFAT"）。读不到就 `None`，由调用方按「不知道」处理。
fn file_system_of(dir: &Path) -> Option<String> {
    let w = wide(dir);
    let mut root = vec![0u16; 260];
    // SAFETY: w 是 NUL 结尾的路径；root 是足够大的缓冲。
    if unsafe { GetVolumePathNameW(w.as_ptr(), root.as_mut_ptr(), root.len() as u32) } == 0 {
        return None;
    }
    let mut fs_name = vec![0u16; 64];
    // SAFETY: root 是 GetVolumePathNameW 写好的卷根路径。
    let ok = unsafe {
        GetVolumeInformationW(
            root.as_ptr(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            fs_name.as_mut_ptr(),
            fs_name.len() as u32,
        )
    };
    if ok == 0 {
        return None;
    }
    let len = fs_name.iter().position(|&c| c == 0).unwrap_or(0);
    Some(String::from_utf16_lossy(&fs_name[..len]))
}

/// SAFETY: `dacl` 必须是合法 ACL 或 null。
unsafe fn has_modify_ace(dacl: *mut ACL, sid: *mut std::ffi::c_void) -> bool {
    if dacl.is_null() {
        return false;
    }
    let count = unsafe { (*dacl).AceCount } as u32;
    for i in 0..count {
        let mut ace: *mut std::ffi::c_void = std::ptr::null_mut();
        if unsafe { GetAce(dacl, i, &mut ace) } == 0 || ace.is_null() {
            continue;
        }
        let header = unsafe { &*(ace as *const windows_sys::Win32::Security::ACE_HEADER) };
        if header.AceType != 0 {
            continue; // 只认允许型
        }
        let mask = unsafe { *(ace as *const u32).add(1) };
        let ace_sid = unsafe { (ace as *const u8).add(8) } as *mut std::ffi::c_void;
        if mask & MODIFY_MASK == MODIFY_MASK && unsafe { EqualSid(ace_sid, sid) } != 0 {
            return true;
        }
    }
    false
}

fn failed(action: &'static str, detail: impl Into<String>) -> PlatformError {
    PlatformError::Failed {
        action,
        detail: detail.into(),
    }
}

fn io_err(action: &'static str, rc: u32) -> PlatformError {
    PlatformError::Io {
        action,
        source: std::io::Error::from_raw_os_error(rc as i32),
    }
}

/// 给日志/诊断用的「这个目录当前给谁开了修改权」摘要（只列 SID，不列完整 DACL）。
pub fn list_modify_sids(dir: &Path) -> Result<Vec<String>> {
    let w = wide(dir);
    let mut dacl: *mut ACL = std::ptr::null_mut();
    let mut sd: *mut std::ffi::c_void = std::ptr::null_mut();
    // SAFETY: 同上。
    let rc = unsafe {
        GetNamedSecurityInfoW(
            w.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut dacl,
            std::ptr::null_mut(),
            &mut sd,
        )
    };
    if rc != ERROR_SUCCESS {
        return Err(io_err("GetNamedSecurityInfoW", rc));
    }
    let mut out = Vec::new();
    if !dacl.is_null() {
        let count = unsafe { (*dacl).AceCount } as u32;
        for i in 0..count {
            let mut ace: *mut std::ffi::c_void = std::ptr::null_mut();
            if unsafe { GetAce(dacl, i, &mut ace) } == 0 || ace.is_null() {
                continue;
            }
            let header = unsafe { &*(ace as *const windows_sys::Win32::Security::ACE_HEADER) };
            if header.AceType != 0 {
                continue;
            }
            let mask = unsafe { *(ace as *const u32).add(1) };
            if mask & MODIFY_MASK != MODIFY_MASK {
                continue;
            }
            let ace_sid = unsafe { (ace as *const u8).add(8) } as *mut std::ffi::c_void;
            out.push(unsafe { sid_to_string(ace_sid) });
        }
    }
    unsafe { LocalFree(sd.cast()) };
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> tempfile::TempDir {
        tempfile::Builder::new()
            .prefix("ppass-photo-")
            .tempdir()
            .expect("tempdir")
    }

    #[test]
    fn grants_an_ace_and_is_idempotent() {
        let d = tempdir();
        let sid = crate::windows_programdata::current_user_sid_string().unwrap();
        assert_eq!(
            grant_modify_for_sid(d.path(), &sid).expect("grant"),
            GrantOutcome::Done
        );
        let before = list_modify_sids(d.path()).unwrap();
        assert_eq!(
            grant_modify_for_sid(d.path(), &sid).expect("grant again"),
            GrantOutcome::Done
        );
        let after = list_modify_sids(d.path()).unwrap();
        assert_eq!(before, after, "第二次不应再堆一条重复 ACE");
    }

    #[test]
    fn adds_an_ace_for_a_new_sid_and_keeps_existing_ones() {
        let d = tempdir();
        let before = list_modify_sids(d.path()).unwrap();
        let users = "S-1-5-32-545";
        assert_eq!(
            grant_modify_for_sid(d.path(), users).expect("grant"),
            GrantOutcome::Done
        );
        let after = list_modify_sids(d.path()).unwrap();
        assert!(after.len() > before.len());
        assert!(after.contains(&users.to_string()), "{after:?}");
        for old in before {
            assert!(after.contains(&old), "原有 ACE 被弄丢了：{old}");
        }
    }

    #[test]
    fn rejects_network_paths() {
        let err =
            grant_modify_for_sid(Path::new(r"\\server\share\photos"), "S-1-5-32-545").unwrap_err();
        assert!(format!("{err}").contains("网络路径"), "{err}");
    }

    #[test]
    fn rejects_missing_directory() {
        let err = grant_modify_for_sid(Path::new(r"C:\definitely-not-here-ppass"), "S-1-5-32-545")
            .unwrap_err();
        assert!(format!("{err}").contains("stat_photo_dir"), "{err}");
    }

    #[test]
    fn file_system_of_the_workspace_is_ntfs_or_refs() {
        let fs = file_system_of(&std::env::current_dir().unwrap()).unwrap_or_default();
        assert!(
            matches!(fs.to_ascii_uppercase().as_str(), "NTFS" | "REFS"),
            "测试机应是 NTFS/ReFS，实际 {fs}"
        );
    }
}
