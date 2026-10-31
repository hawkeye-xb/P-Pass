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

/// 在 `link` 处造一个指向文件 `target` 的符号链接（#1150：库内链接指到库外的测试要用）。
///
/// Windows 上建文件符号链接要特权：失败时返回 `Err`（`PermissionDenied`），调用方
/// 应跳过并打印原因，绝不静默算通过。
pub fn file_symlink(target: &Path, link: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        std::os::windows::fs::symlink_file(target, link)
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link)
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
            // cmd 把参数里的 `/` 当开关（`Path::join("a/b")` 在 Windows 上会留下 `/`），
            // 传给 mklink 前统一换成 `\`。
            &link.to_string_lossy().replace('/', "\\"),
            &target.to_string_lossy().replace('/', "\\"),
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
/// Windows（#778）：给目录加一条拒绝**当前用户**新建文件 / 子文件夹的 ACE，守卫
/// 析构时写回原 DACL。拒绝 ACE 先于一切允许生效，提权的管理员进程（CI runner）也
/// 拦得住。PR #776 用 `icacls` 命令行试过两种写法都没拦住，所以改为直接调 Win32
/// 安全 API（与 SEC-07 `restrict_to_owner` 同一套），机制见
/// `windows::deny_entry_creation`。
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
        let original_dacl = crate::windows::deny_entry_creation(dir)?;
        Ok(CreationDenied {
            dir: dir.to_path_buf(),
            original_dacl,
        })
    }
}

/// #778：`dir` 里还能不能落下一个文件——直接放，或先建一层子文件夹再放（照片
/// 落地就是 `create_dir_all` 再建文件）。都落不下才算 `true`。
///
/// 为什么不直接断言「建不了子文件夹」：Windows 上持有备份 / 还原特权的进程（提权
/// 的 CI runner）建文件夹会绕过 ACL（见 `windows::deny_entry_creation`），但继承
/// 了拒绝的新子文件夹里照样建不了文件。真正要问的是「照片能不能落进来」。
/// 探测中途建成的子文件夹会删掉，不留痕迹。
pub fn nothing_can_land_in(dir: &Path) -> bool {
    if std::fs::File::create(dir.join(".land-probe")).is_ok() {
        let _ = std::fs::remove_file(dir.join(".land-probe"));
        return false;
    }
    let sub = dir.join(".land-probe-dir");
    if std::fs::create_dir(&sub).is_err() {
        return true;
    }
    let landed = std::fs::File::create(sub.join("probe")).is_ok();
    let _ = std::fs::remove_file(sub.join("probe"));
    let _ = std::fs::remove_dir(&sub);
    !landed
}

/// [`deny_file_creation`] 的守卫：析构时恢复原权限。
pub struct CreationDenied {
    #[cfg(any(unix, windows))]
    dir: std::path::PathBuf,
    #[cfg(unix)]
    original: std::fs::Permissions,
    #[cfg(windows)]
    original_dacl: Vec<u8>,
}

impl Drop for CreationDenied {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            let _ = std::fs::set_permissions(&self.dir, self.original.clone());
        }
        #[cfg(windows)]
        {
            crate::windows::restore_dacl(&self.dir, &self.original_dacl);
        }
    }
}

/// W-3：「加密存放」的身份私钥存放处，供 daemon 的 `settle` 测试用。
///
/// Windows 上就是产品用的 DPAPI 存放处（真实加密）；其他平台没有 DPAPI，
/// 用一个行为等价的替身：带文件头、内容变形、带校验，旧明文（无文件头）读到即删并
/// 当作「没有」，被改动的内容读取是 `Err`。两边对 `settle` 的可观察行为一致。
pub fn sealed_identity_store(path: &Path) -> Box<dyn crate::IdentityKeyStore> {
    #[cfg(windows)]
    {
        Box::new(crate::ProgramDataStore::sealed(path, "身份私钥"))
    }
    #[cfg(not(windows))]
    {
        Box::new(StandInSealed(path.to_path_buf()))
    }
}

#[cfg(not(windows))]
struct StandInSealed(std::path::PathBuf);

#[cfg(not(windows))]
impl StandInSealed {
    const MAGIC: &'static [u8; 8] = b"PPDPAPI1";

    fn checksum(body: &[u8]) -> [u8; 8] {
        body.iter()
            .fold(0u64, |a, b| a.wrapping_mul(31).wrapping_add(u64::from(*b)))
            .to_le_bytes()
    }
}

#[cfg(not(windows))]
impl crate::IdentityKeyStore for StandInSealed {
    fn read(&self) -> crate::Result<Option<Vec<u8>>> {
        let bytes = match std::fs::read(&self.0) {
            Ok(b) => b,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(source) => {
                return Err(crate::PlatformError::Io {
                    action: "read_programdata_blob",
                    source,
                })
            }
        };
        let Some(rest) = bytes.strip_prefix(Self::MAGIC.as_slice()) else {
            std::fs::remove_file(&self.0).map_err(|source| crate::PlatformError::Io {
                action: "remove_legacy_plaintext",
                source,
            })?;
            return Ok(None);
        };
        let bad = || crate::PlatformError::Failed {
            action: "unseal_programdata_blob",
            detail: "无法解密".into(),
        };
        let (body, sum) = rest.split_at(rest.len().checked_sub(8).ok_or_else(bad)?);
        if Self::checksum(body) != sum {
            return Err(bad());
        }
        Ok(Some(body.iter().map(|b| b ^ 0xa5).collect()))
    }

    fn write(&self, secret: &[u8]) -> crate::Result<()> {
        let body: Vec<u8> = secret.iter().map(|b| b ^ 0xa5).collect();
        let out = [Self::MAGIC.as_slice(), &body, &Self::checksum(&body)].concat();
        std::fs::write(&self.0, out).map_err(|source| crate::PlatformError::Io {
            action: "write_programdata_blob",
            source,
        })
    }

    fn location(&self) -> String {
        self.0.display().to_string()
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

    /// 守卫在手时目录里落不下任何文件（直接放、或先建子文件夹再放）；守卫释放后又能
    /// 落下。三个平台都跑（#778 之前 Windows 在这里报不支持）。
    #[test]
    fn denied_dir_refuses_new_files_until_the_guard_drops() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("locked");
        std::fs::create_dir(&dir).unwrap();
        {
            let _guard = deny_file_creation(&dir).unwrap();
            assert!(
                std::fs::File::create(dir.join("probe")).is_err(),
                "a denied folder must refuse a new file (running as root?)"
            );
            assert!(
                nothing_can_land_in(&dir),
                "nothing may land under a denied folder, not even via a new sub-folder"
            );
        }
        assert!(
            !nothing_can_land_in(&dir),
            "released folder takes files again"
        );
        std::fs::File::create(dir.join("probe")).unwrap();
        std::fs::create_dir(dir.join("sub")).unwrap();
    }
}
