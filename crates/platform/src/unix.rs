//! Unix（macOS + Linux）共享的平台实现。
//!
//! QA-09 迁移（#211）新增。在此之前 `crates/platform/` 只有 `macos.rs` 与
//! `windows.rs`，非两者走 `lib.rs` 里的 `HeadlessAdapter`。而这次从 daemon
//! 迁过来的分叉里有 3 处写的是 `#[cfg(unix)]`——**同时覆盖 macOS 和 Linux**。
//! 没有共享模块就得把同一段 libc 调用抄两遍，抄两遍就会漂。
//!
//! 本模块只提供自由函数，谁用由各自的适配器 impl 决定
//! （`MacosAdapter` 与 `HeadlessAdapter` 都用）。

use crate::{Applied, PlatformError, VolumeStats};
use std::path::Path;

/// `free` 取 `statvfs` 的 `f_bavail`——**无特权写入者真正可用**的字节数，
/// 也就是 `df` / Finder 显示的那个数，而不是卷上的物理空闲量（有配额或
/// 保留区时两者不同）。这条语义是 trait 上写死的契约，Windows 侧
/// `GetDiskFreeSpaceExW` 的第一个出参对齐的也是它。
// statvfs 字段宽度各 unix 不同（fsblkcnt_t：macOS 是 u32，Linux 是 u64）
// ——`u64::from` 在一边是必需的、在另一边被判「多余」，这个 lint 两边无法
// 同时满足。用 From 而不是 `as`，保证无损。
#[allow(clippy::useless_conversion)]
pub fn volume_stats(path: &Path) -> Option<VolumeStats> {
    use std::os::unix::ffi::OsStrExt as _;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut vfs: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: c 是 NUL 结尾的合法 C 字符串且在调用期间存活；vfs 是栈上
    // 已零初始化的 POD 出参，指针非空且对齐。
    if unsafe { libc::statvfs(c.as_ptr(), &mut vfs) } != 0 {
        return None;
    }
    let frsize = u64::from(vfs.f_frsize);
    Some(VolumeStats {
        free: u64::from(vfs.f_bavail) * frsize,
        total: u64::from(vfs.f_blocks) * frsize,
    })
}

/// 0o600：只有属主可读写。
pub fn restrict_to_owner(path: &Path) -> crate::Result<Applied> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|source| {
        PlatformError::Io {
            action: "restrict_to_owner",
            source,
        }
    })?;
    Ok(Applied::Done)
}

/// fd 2 就是本进程自己的 stderr——launchd / systemd 这类托管方把真正的
/// `.err` 文件 `open()` 之后 `dup2` 到 fd 2 才 exec 我们，所以对 fd 2
/// `set_len(0)` + `seek(0)` 动的就是那个文件本身。
pub fn truncate_own_stderr() -> Applied {
    use std::os::fd::FromRawFd as _;
    // ManuallyDrop：这只是「借用 fd 2 的视角」，真把它 drop 掉会把 stderr
    // 从整个进程手里关掉。
    // SAFETY: POSIX 下 fd 2 是本进程的 stderr，进程存活期间始终有效；
    // ManuallyDrop 保证这里不会关闭它。
    let mut file = std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(2) });
    let _ = file.set_len(0);
    let _ = std::io::Seek::seek(&mut *file, std::io::SeekFrom::Start(0));
    Applied::Done
}

/// unix domain socket 在文件系统里留下真实文件。被强杀的前任留下的那个
/// 不清掉，`bind` 会 EADDRINUSE，整个 IPC 平面起不来。
///
/// 清不掉不报错，与迁移前行为一致：文件本来就可能不存在（正常首启），
/// 而真正的失败会在紧接着的 bind 上暴露出来。
pub fn remove_stale_ipc_endpoint(name: &str) -> Applied {
    let _ = std::fs::remove_file(format!("/tmp/{name}"));
    Applied::Done
}

#[cfg(test)]
mod tests {
    use super::*;

    /// QA-09 (#211) 契约：unix 上 volume_stats 必须回真实数字。
    /// 迁移前 daemon 自己调 statvfs，迁进来之后这条就是那段行为的守卫——
    /// 谁把它改回 None，这里必须红。
    #[test]
    fn volume_stats_reports_real_numbers_on_unix() {
        let v = volume_stats(std::path::Path::new("/")).expect("unix 上必须有数字，不能是 None");
        assert!(v.total > 0, "总容量不该是 0：{v:?}");
        assert!(v.free <= v.total, "可用不该大于总量：{v:?}");
    }

    /// 不存在的路径必须回 None，而不是 0/0 —— 「老实的 null 胜过编造的数字」。
    #[test]
    fn volume_stats_returns_none_for_missing_path() {
        assert_eq!(
            volume_stats(std::path::Path::new("/definitely/not/here/ppf-qa09")),
            None
        );
    }

    /// 0o600 契约：改完之后 group/other 位必须全灭。
    #[test]
    fn restrict_to_owner_clears_group_and_other_bits() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = std::env::temp_dir().join(format!("ppf-qa09-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("identity.key");
        std::fs::write(&f, b"x").unwrap();
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o644)).unwrap();

        assert_eq!(restrict_to_owner(&f).unwrap(), Applied::Done);

        let mode = std::fs::metadata(&f).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "期望 0o600，实得 {mode:o}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 路径不存在时必须报错，不能静默说自己做过了。
    #[test]
    fn restrict_to_owner_fails_loudly_on_missing_file() {
        assert!(restrict_to_owner(std::path::Path::new("/definitely/not/here/ppf-qa09")).is_err());
    }
}
