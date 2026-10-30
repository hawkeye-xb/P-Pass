//! D2 / brief §5.3：照片库目录设为私有，并授权给服务账户。
//!
//! 照片库是主人的备份，同机其他账户不该能看、改、删。用户在向导 / 设置里选好目录（首次
//! 设置与换位置走同一入口）后，壳以**主人身份**把该目录的 DACL 设成受保护（不继承上级）、
//! 只含四个 SID：主人、服务账户（修改）、SYSTEM、Administrators——与系统给用户配置文件
//! 目录的权限一致。目录归主人所有时不需要提权；失败（属主不是主人、来自别的电脑的 NTFS
//! 盘）把错误原样交给调用方。
//!
//! 只在首次设置与换位置时设置：主人事后在文件夹属性里加的权限（例如共享给装成服务的媒体
//! 服务器），P-Pass 不再覆盖。
//!
//! exFAT / FAT32 没有 ACL：跳过（[`GrantOutcome::SkippedNoAcl`]），不假装成功、不提示。
//! 网络路径本期不支持，明确拒绝。

use std::path::Path;

use windows_sys::Win32::Foundation::{LocalFree, ERROR_ACCESS_DENIED, ERROR_SUCCESS};
use windows_sys::Win32::Security::Authorization::{GetNamedSecurityInfoW, SE_FILE_OBJECT};
use windows_sys::Win32::Security::{
    GetAce, GetSecurityDescriptorControl, ACL, DACL_SECURITY_INFORMATION, SE_DACL_PROTECTED,
};
use windows_sys::Win32::Storage::FileSystem::{
    GetVolumeInformationW, GetVolumePathNameW, DELETE, FILE_ALL_ACCESS, FILE_GENERIC_EXECUTE,
    FILE_GENERIC_READ, FILE_GENERIC_WRITE,
};

use crate::windows_programdata::{set_private_dacl_with, sid_to_string, wide, ADMINISTRATORS_SID};
use crate::{PlatformError, Result};

/// 「修改」= 读 + 写 + 执行 + 删；与资源管理器里「修改」一档对齐。服务账户拿这一档。
const MODIFY_MASK: u32 = FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_GENERIC_EXECUTE | DELETE;

/// LocalSystem。
pub const SYSTEM_SID: &str = "S-1-5-18";

const ALLOWED_ACE_TYPE: u8 = 0;

/// 设置结果。不是 `Result<()>`：exFAT 上「没有 ACL 可设」不是失败，是平台事实。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GrantOutcome {
    /// 已设为私有并回读确认。
    Done,
    /// 卷没有 ACL（FAT/FAT32/exFAT），跳过。
    SkippedNoAcl { file_system: String },
}

/// 把 `dir` 设为私有：受保护 DACL，只含 `owner_sid`、SYSTEM、Administrators（完全控制）与
/// `service_sid`（修改），全部可继承并传播到已有子项。幂等；设完回读真实 DACL 核对。
pub fn make_private_for_service(
    dir: &Path,
    service_sid: &str,
    owner_sid: &str,
) -> Result<GrantOutcome> {
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

    let grants = library_grants(service_sid, owner_sid);
    if let Err(e) = set_private_dacl_with(dir, &grants) {
        if let PlatformError::Io { source, .. } = &e {
            if source.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) {
                return Err(failed(
                    "grant_photo_dir",
                    "目录不归当前用户所有，改权限需要管理员权限",
                ));
            }
        }
        return Err(e);
    }
    // 回读确认：判据是真实 DACL，不是 SetNamedSecurityInfoW 的返回值。
    let facts = dacl_facts(dir)?;
    check_private(&facts, &grants)?;
    Ok(GrantOutcome::Done)
}

/// 照片库目录的访问表（同一 SID 出现两次时只留一条）。
fn library_grants<'a>(service_sid: &'a str, owner_sid: &'a str) -> Vec<(&'a str, u32)> {
    let mut grants: Vec<(&str, u32)> = vec![
        (owner_sid, FILE_ALL_ACCESS),
        (SYSTEM_SID, FILE_ALL_ACCESS),
        (ADMINISTRATORS_SID, FILE_ALL_ACCESS),
        (service_sid, MODIFY_MASK),
    ];
    let mut seen = std::collections::HashSet::new();
    grants.retain(|(sid, _)| seen.insert(sid.to_ascii_uppercase()));
    grants
}

/// 一个目录 / 文件 DACL 的事实：是否受保护、每条 ACE 的（类型、掩码、SID）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DaclFacts {
    pub protected: bool,
    pub aces: Vec<(u8, u32, String)>,
}

impl DaclFacts {
    /// 允许型 ACE 指向的 SID（去重、排序）。
    pub fn allowed_sids(&self) -> Vec<String> {
        let mut out: Vec<String> = self
            .aces
            .iter()
            .filter(|(t, _, _)| *t == ALLOWED_ACE_TYPE)
            .map(|(_, _, s)| s.clone())
            .collect();
        out.sort();
        out.dedup();
        out
    }
}

fn check_private(facts: &DaclFacts, grants: &[(&str, u32)]) -> Result<()> {
    if !facts.protected {
        return Err(failed("grant_photo_dir", "设置后 DACL 仍在继承上级目录"));
    }
    if facts.aces.iter().any(|(t, _, _)| *t != ALLOWED_ACE_TYPE) {
        return Err(failed("grant_photo_dir", "设置后 DACL 里有非允许型 ACE"));
    }
    let mut want: Vec<String> = grants.iter().map(|(s, _)| s.to_string()).collect();
    want.sort();
    if facts.allowed_sids() != want {
        return Err(failed(
            "grant_photo_dir",
            format!(
                "设置后 DACL 的 SID 是 {:?}，应为 {want:?}",
                facts.allowed_sids()
            ),
        ));
    }
    for (sid, mask) in grants {
        let has = facts
            .aces
            .iter()
            .any(|(_, m, s)| s == sid && m & mask == *mask);
        if !has {
            return Err(failed(
                "grant_photo_dir",
                format!("设置后 {sid} 缺少应有的访问权"),
            ));
        }
    }
    Ok(())
}

/// 读回 `path` 的真实 DACL。
pub fn dacl_facts(path: &Path) -> Result<DaclFacts> {
    let w = wide(path);
    let mut dacl: *mut ACL = std::ptr::null_mut();
    let mut sd: *mut std::ffi::c_void = std::ptr::null_mut();
    // SAFETY: w 是 NUL 结尾的宽路径；成功时 sd 由 LocalAlloc，dacl 指向 sd 内部，下面释放。
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
    let mut control = 0u16;
    let mut revision = 0u32;
    // SAFETY: sd 是上面拿到的合法安全描述符。
    unsafe { GetSecurityDescriptorControl(sd, &mut control, &mut revision) };
    let mut aces = Vec::new();
    if !dacl.is_null() {
        let count = unsafe { (*dacl).AceCount } as u32;
        for i in 0..count {
            let mut ace: *mut std::ffi::c_void = std::ptr::null_mut();
            if unsafe { GetAce(dacl, i, &mut ace) } == 0 || ace.is_null() {
                continue;
            }
            // ACE_HEADER（4 字节）+ 掩码（4 字节）+ SID：允许 / 拒绝型的布局相同。
            let header = unsafe { &*(ace as *const windows_sys::Win32::Security::ACE_HEADER) };
            let mask = unsafe { *(ace as *const u32).add(1) };
            let sid = unsafe { (ace as *const u8).add(8) } as *mut std::ffi::c_void;
            aces.push((header.AceType, mask, unsafe { sid_to_string(sid) }));
        }
    }
    unsafe { LocalFree(sd.cast()) };
    Ok(DaclFacts {
        protected: control & SE_DACL_PROTECTED != 0,
        aces,
    })
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
    Ok(dacl_facts(dir)?
        .aces
        .into_iter()
        .filter(|(t, m, _)| *t == ALLOWED_ACE_TYPE && m & MODIFY_MASK == MODIFY_MASK)
        .map(|(_, _, s)| s)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 本机账户里肯定没有的服务 SID（测试注入，不依赖服务已安装）。
    const TEST_SERVICE: &str = "S-1-5-80-1-2-3-4-5";
    /// Authenticated Users。
    const AUTHENTICATED_USERS: &str = "S-1-5-11";

    fn me() -> String {
        crate::windows_programdata::current_user_sid_string().unwrap()
    }

    fn tempdir() -> tempfile::TempDir {
        tempfile::Builder::new()
            .prefix("ppass-photo-")
            .tempdir()
            .expect("tempdir")
    }

    fn sorted(mut v: Vec<String>) -> Vec<String> {
        v.sort();
        v
    }

    /// 父目录给 Authenticated Users 加一条可继承的「修改」（非系统盘根目录的默认形状）。
    fn open_parent_to_authenticated_users(dir: &Path) {
        let ok = std::process::Command::new("icacls")
            .arg(dir)
            .args(["/grant", "*S-1-5-11:(OI)(CI)M"])
            .status()
            .expect("icacls");
        assert!(ok.success());
    }

    /// 判据：设置后库目录 DACL 受保护、恰好是主人 / 服务 / SYSTEM / Administrators 四个 SID；
    /// 父目录给 Authenticated Users 的可继承修改权不再落到库目录与其中已有的文件上。
    /// 反证：去掉 PROTECTED 位（DACL 仍继承上级）⇒ 库目录与文件上都会出现 S-1-5-11，红。
    #[test]
    fn library_dir_private_dacl_has_exactly_four_sids_and_drops_inherited_ones() {
        let parent = tempdir();
        open_parent_to_authenticated_users(parent.path());
        let lib = parent.path().join("P-Pass Library");
        std::fs::create_dir(&lib).unwrap();
        let child = lib.join("originals");
        std::fs::create_dir(&child).unwrap();
        let photo = child.join("a.jpg");
        std::fs::write(&photo, b"x").unwrap();
        assert!(
            dacl_facts(&photo)
                .unwrap()
                .allowed_sids()
                .contains(&AUTHENTICATED_USERS.to_string()),
            "前提：设置前文件继承了父目录的 Authenticated Users"
        );

        assert_eq!(
            make_private_for_service(&lib, TEST_SERVICE, &me()).expect("make private"),
            GrantOutcome::Done
        );

        let root = dacl_facts(&lib).unwrap();
        assert!(root.protected, "库目录 DACL 必须受保护：{root:?}");
        assert_eq!(
            root.allowed_sids(),
            sorted(vec![
                me(),
                TEST_SERVICE.to_string(),
                SYSTEM_SID.to_string(),
                ADMINISTRATORS_SID.to_string()
            ]),
            "{root:?}"
        );
        assert!(
            list_modify_sids(&lib)
                .unwrap()
                .contains(&TEST_SERVICE.to_string()),
            "服务账户要有修改权"
        );
        for p in [&child, &photo] {
            let f = dacl_facts(p).unwrap();
            assert!(
                !f.allowed_sids().contains(&AUTHENTICATED_USERS.to_string()),
                "{} 仍带着上级目录的 Authenticated Users：{f:?}",
                p.display()
            );
            assert!(
                f.allowed_sids().contains(&TEST_SERVICE.to_string()),
                "{} 没有继承到服务账户：{f:?}",
                p.display()
            );
        }
    }

    /// 之后新建的文件同样只继承这四个 SID。
    #[test]
    fn library_dir_private_dacl_is_inherited_by_new_files() {
        let parent = tempdir();
        open_parent_to_authenticated_users(parent.path());
        let lib = parent.path().join("lib");
        std::fs::create_dir(&lib).unwrap();
        make_private_for_service(&lib, TEST_SERVICE, &me()).expect("make private");
        let later = lib.join("later.jpg");
        std::fs::write(&later, b"x").unwrap();
        assert_eq!(
            dacl_facts(&later).unwrap().allowed_sids(),
            sorted(vec![
                me(),
                TEST_SERVICE.to_string(),
                SYSTEM_SID.to_string(),
                ADMINISTRATORS_SID.to_string()
            ])
        );
    }

    #[test]
    fn library_dir_private_dacl_is_idempotent() {
        let d = tempdir();
        make_private_for_service(d.path(), TEST_SERVICE, &me()).expect("first");
        let before = dacl_facts(d.path()).unwrap();
        make_private_for_service(d.path(), TEST_SERVICE, &me()).expect("second");
        assert_eq!(
            before,
            dacl_facts(d.path()).unwrap(),
            "第二次不应堆重复 ACE"
        );
    }

    /// 回读核对本身：没受保护、多一个 SID、少一个 SID 都要报错。
    #[test]
    fn library_dir_private_check_rejects_wrong_dacls() {
        let grants = library_grants(TEST_SERVICE, "S-1-5-21-1-2-3-1001");
        let good = DaclFacts {
            protected: true,
            aces: grants
                .iter()
                .map(|(s, m)| (0u8, *m, s.to_string()))
                .collect(),
        };
        check_private(&good, &grants).expect("good");
        let mut inherited = good.clone();
        inherited.protected = false;
        assert!(check_private(&inherited, &grants).is_err());
        let mut extra = good.clone();
        extra
            .aces
            .push((0, MODIFY_MASK, AUTHENTICATED_USERS.into()));
        assert!(check_private(&extra, &grants).is_err());
        let mut missing = good.clone();
        missing.aces.pop();
        assert!(check_private(&missing, &grants).is_err());
    }

    #[test]
    fn rejects_network_paths() {
        let err =
            make_private_for_service(Path::new(r"\\server\share\photos"), TEST_SERVICE, &me())
                .unwrap_err();
        assert!(format!("{err}").contains("网络路径"), "{err}");
    }

    #[test]
    fn rejects_missing_directory() {
        let err = make_private_for_service(
            Path::new(r"C:\definitely-not-here-ppass"),
            TEST_SERVICE,
            &me(),
        )
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
