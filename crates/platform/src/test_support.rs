//! 只给测试用的平台能力（feature `test-support`，默认关闭）。
//!
//! # 为什么这些东西在 platform crate 里
//!
//! 架构红线 B.2 说平台分叉只许待在本 crate。桌面壳里有三条测试守着同一条
//! 安全契约（MOB-47 / #212：**指向目录的链接必须被拒绝**，哪怕名字叫
//! `tricky.mp4`），它们此前各自带着 `#[cfg(windows)]` / `#[cfg(unix)]`
//! ——因为"怎么造一个指向目录的链接"每个系统不一样。
//!
//! 曾经的想法是给这几处开豁免，理由是"测试脚手架不该塞进产品 crate"。
//! 那个论证是错的（#287 里记着）：它从**谁调用**出发，而不是从**它是什么**
//! 出发。本 crate 的职责就是收纳「这个系统怎么做某件事」，而"怎么造一个
//! 指向目录的链接"**正是**这种知识。它本来就该在这儿。
//!
//! # feature gate 不是装饰
//!
//! `test-support` 关着的时候本模块整个不参与编译，产品二进制里不会多出
//! 任何东西。消费方在 `[dev-dependencies]` 里开这个 feature，普通依赖那条
//! 不开——Cargo 会把测试构建的 feature 并起来，产品构建则不会。

use std::io;
use std::path::Path;

/// 本系统上「能指向目录的链接」的一种形态。
///
/// Windows 有两种（junction 与目录符号链接），unix 一种（符号链接）。
/// 两者在 `canonicalize` 下的行为都需要被契约覆盖到——它们是不同的机制，
/// 不能只验一种就当验过了。
pub struct DirLinkKind {
    /// 断言失败时用来指认是哪一种，例如 `"junction"`。
    pub name: &'static str,
    /// `true` ⇒ 建这种链接可能因权限不足而失败。
    ///
    /// 调用方遇到失败时应当**跳过并打印原因**，绝不静默算通过；
    /// `false` 的那些建不出来就是真出事了，该判红。
    pub may_need_privilege: bool,
    make: fn(&Path, &Path) -> io::Result<()>,
}

impl DirLinkKind {
    /// 在 `link` 处造一个本形态、指向目录 `target` 的链接。
    pub fn make(&self, target: &Path, link: &Path) -> io::Result<()> {
        (self.make)(target, link)
    }
}

impl std::fmt::Debug for DirLinkKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DirLinkKind")
            .field("name", &self.name)
            .field("may_need_privilege", &self.may_need_privilege)
            .finish()
    }
}

/// 本系统支持的全部「指向目录的链接」形态。
///
/// 调用方遍历它，就不必知道自己跑在哪个系统上——「对这台机器能造出的
/// **每一种**指向目录的链接，契约都必须成立」这层意图因此能直接写进测试。
pub fn dir_link_kinds() -> &'static [DirLinkKind] {
    #[cfg(windows)]
    {
        &[
            DirLinkKind {
                name: "junction",
                // junction 不需要特权，建不出来就是真出事了。
                may_need_privilege: false,
                make: windows_junction,
            },
            DirLinkKind {
                name: "symlink_dir",
                // 目录符号链接要管理员，或要传
                // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE（std 不传）。
                may_need_privilege: true,
                make: |target, link| std::os::windows::fs::symlink_dir(target, link),
            },
        ]
    }
    #[cfg(unix)]
    {
        &[DirLinkKind {
            name: "symlink",
            may_need_privilege: false,
            make: |target, link| std::os::unix::fs::symlink(target, link),
        }]
    }
}

/// 建一个 junction。
///
/// std 没有 junction API，`mklink` 是 cmd 的内建命令——所以只能起 cmd。
///
/// ⚠️ 起 console 子系统程序（`cmd.exe`）在产品路径里是被 DESK-19 (#168)
/// 明令禁止的：桌面壳是 GUI 子系统、没有控制台，spawn 它会让 Windows 新分配
/// 一个控制台，用户看到黑窗一闪。**这里可以，因为本模块在 `test-support`
/// feature 之内、根本不进产品二进制，也不面向用户。**
///
/// DESK-33 (#325)：clippy 的 `disallowed-methods` 现在看得到本文件；这里是
/// **有意**放行（下面的 `allow`），理由就是上面那句：不进产品、不面向用户。
#[cfg(windows)]
#[allow(clippy::disallowed_methods)]
fn windows_junction(target: &Path, link: &Path) -> io::Result<()> {
    let out = std::process::Command::new("cmd")
        .args([
            "/C",
            "mklink",
            "/J",
            &link.to_string_lossy(),
            &target.to_string_lossy(),
        ])
        .output()?;
    if out.status.success() && link.exists() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "mklink /J 失败: status={:?} stdout={} stderr={}",
            out.status.code(),
            String::from_utf8_lossy(&out.stdout).trim(),
            String::from_utf8_lossy(&out.stderr).trim()
        )))
    }
}

/// #763：让目录拒绝在其中新建文件 / 子目录，守卫析构时恢复。
///
/// unix：去掉写位（0o555）。调用方拿到守卫后应先自己验一次「确实建不了」——
/// 以 root 运行时写位挡不住，那时测试证明不了任何东西，必须判红而不是静默通过。
///
/// Windows：返回 [`io::ErrorKind::Unsupported`]，调用方**跳过并打印原因**。
/// Windows CI（PR #776）两种做法都没能让测试进程在自己的临时目录里建不了东西：
/// `icacls /deny Everyone:(AD,WD)` 挡住了新建文件、没挡住新建子目录；
/// `/inheritance:r /grant:r Everyone:(RX)`（不留任何写入授权）连新建文件都没挡住。
/// 造不出「不可写目录」就不假装造得出——产品探针本身不分平台（真去建文件），
/// Windows 上那时该报什么由系统说了算。
pub fn deny_file_creation(dir: &Path) -> io::Result<CreationDenied> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let original = std::fs::metadata(dir)?.permissions();
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o555))?;
        Ok(CreationDenied {
            dir: dir.to_path_buf(),
            original,
        })
    }
    #[cfg(windows)]
    {
        let _ = dir;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Windows: no ACL setup made the test process unable to create entries in its own temp folder (PR #776)",
        ))
    }
}

/// [`deny_file_creation`] 的守卫：析构时恢复原权限。
pub struct CreationDenied {
    #[cfg(unix)]
    dir: std::path::PathBuf,
    #[cfg(unix)]
    original: std::fs::Permissions,
}

impl Drop for CreationDenied {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            let _ = std::fs::set_permissions(&self.dir, self.original.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 每个系统都必须至少给出一种形态——给不出等于契约在这台机器上没被验过，
    /// 而消费方遍历一个空表会**静默全绿**。
    #[test]
    fn every_platform_offers_at_least_one_dir_link_kind() {
        assert!(!dir_link_kinds().is_empty());
    }

    /// 不需要特权的那些必须真能建出来。这条同时兜住了「junction 在本机建不
    /// 出来」这类环境问题——否则消费方只会看到契约用例莫名其妙不跑。
    #[test]
    fn unprivileged_kinds_actually_produce_a_link_to_the_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("realdir");
        std::fs::create_dir_all(&dir).unwrap();

        for (i, kind) in dir_link_kinds().iter().enumerate() {
            if kind.may_need_privilege {
                continue;
            }
            let link = tmp.path().join(format!("link{i}"));
            kind.make(&dir, &link).unwrap_or_else(|e| {
                panic!("{} 不需要特权却建不出来: {e}", kind.name);
            });
            // 链接确实指向那个目录：解析之后应当落在 dir 上。
            assert_eq!(
                std::fs::canonicalize(&link).unwrap(),
                std::fs::canonicalize(&dir).unwrap(),
                "{} 建出来了，但没指向目标目录",
                kind.name
            );
        }
    }

    /// 守卫在手时目录里确实建不了文件；守卫释放后又能建。Windows 上明确报不支持（见函数注释）。
    #[test]
    fn denied_dir_refuses_new_files_until_the_guard_drops() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("locked");
        std::fs::create_dir(&dir).unwrap();
        if cfg!(windows) {
            let err = deny_file_creation(&dir)
                .err()
                .expect("Windows reports unsupported");
            assert_eq!(err.kind(), io::ErrorKind::Unsupported);
            return;
        }
        {
            let _guard = deny_file_creation(&dir).unwrap();
            assert!(
                std::fs::File::create(dir.join("probe")).is_err(),
                "a denied folder must refuse a new file (running as root?)"
            );
            assert!(std::fs::create_dir(dir.join("sub")).is_err());
        }
        std::fs::File::create(dir.join("probe")).unwrap();
    }
}
