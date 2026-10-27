//! Unix（macOS + Linux）共享的平台实现。
//!
//! QA-09 迁移（#211）新增。在此之前 `crates/platform/` 只有 `macos.rs` 与
//! `windows.rs`，非两者走 `lib.rs` 里的 `HeadlessAdapter`。而这次从 daemon
//! 迁过来的分叉里有 3 处写的是 `#[cfg(unix)]`——**同时覆盖 macOS 和 Linux**。
//! 没有共享模块就得把同一段 libc 调用抄两遍，抄两遍就会漂。
//!
//! 本模块只提供自由函数，谁用由各自的适配器 impl 决定
//! （`MacosAdapter` 与 `HeadlessAdapter` 都用）。

// DESK-33 (#325)：clippy.toml 禁止直接 `Command::new`，那条约束只为 Windows
// 的「GUI 进程拉起 console 程序会闪黑窗」而设。本文件只在 unix（macOS / Linux） 上编译，
// 没有这个问题，整文件放行；Windows 代码请走 `crate::command`。
#![allow(clippy::disallowed_methods)]

use crate::{Applied, KillOutcome, PlatformError, VolumeStats};
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

/// #1115：建一个只有本用户能进的目录（0700）。已存在就核对属主是本用户、并把权限收回 0700；
/// 属主不是本用户（别人抢先建的）⇒ 报错，调用方拒绝启动——不在别人控制的目录里放 socket。
pub fn prepare_private_dir(path: &Path) -> crate::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    let io = |source| PlatformError::Io {
        action: "prepare_private_dir",
        source,
    };
    match std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
    {
        Ok(()) => {}
        Err(e) => return Err(io(e)),
    }
    let meta = std::fs::symlink_metadata(path).map_err(io)?;
    if !meta.is_dir() {
        return Err(PlatformError::Failed {
            action: "prepare_private_dir",
            detail: format!("{} 不是目录（软链或文件）", path.display()),
        });
    }
    // SAFETY: getuid 无参数、不失败。
    let me = unsafe { libc::getuid() };
    if meta.uid() != me {
        return Err(PlatformError::Failed {
            action: "prepare_private_dir",
            detail: format!(
                "{} 的属主不是本用户（uid {} ≠ {me}）",
                path.display(),
                meta.uid()
            ),
        });
    }
    if meta.permissions().mode() & 0o777 != 0o700 {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).map_err(io)?;
    }
    Ok(())
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
    /// #1115：私有目录建成 0700；已存在但权限放宽了 ⇒ 收回 0700；是文件 ⇒ 报错。
    #[test]
    fn private_dir_is_0700_and_owned_by_us() {
        use std::os::unix::fs::PermissionsExt as _;
        let base = std::env::temp_dir().join(format!("ppf-1115-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let dir = base.join("run");
        prepare_private_dir(&dir).unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700);
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        prepare_private_dir(&dir).unwrap();
        assert_eq!(mode(&dir), 0o700, "放宽过的权限要收回");
        let file = base.join("not-a-dir");
        std::fs::write(&file, b"x").unwrap();
        assert!(prepare_private_dir(&file).is_err());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn restrict_to_owner_fails_loudly_on_missing_file() {
        assert!(restrict_to_owner(std::path::Path::new("/definitely/not/here/ppf-qa09")).is_err());
    }
}

/// B7（#1043）：结束以 `exe` 这个可执行文件运行的 daemon 进程（SIGTERM，与改前
/// `pkill` 的默认信号相同；不等它退出，同改前）。
///
/// 判据是**可执行文件的绝对路径**，不是命令行：改前的 `pkill -f ppf-daemon`
/// 会把命令行里恰好带这几个字的任何进程一起杀掉（编辑器开着同名文件、
/// `tail -f …/ppf-daemon.log`、另一份开发构建……）。
///
/// 1. `pid_hint`（daemon 经 IPC 自报的 pid）优先：它的可执行文件**名**确实是
///    `exe` 的文件名才动它——pid 会被复用，不核对就可能杀错人。只核对文件名、
///    不核对目录：应答 IPC 的那个 daemon 跑在别处（开发构建、解压副本）时，
///    改前的 `pkill -f` 也停得掉它，「停止服务」不能因此变成停不下来。
/// 2. 兜底：枚举进程，可执行文件**完整路径**等于 `exe` 的都结束（daemon 挂死、
///    IPC 不通时靠这条）。
///
/// 只动本用户的进程：别的用户（快速用户切换）同一个 App 里的 daemon，
/// `kill(pid, 0)` 报 `EPERM`，跳过，不算失败。
pub fn stop_processes_at(exe: &Path, pid_hint: Option<u32>) -> crate::Result<KillOutcome> {
    let want = std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_path_buf());
    let me = std::process::id();
    let mut seen = std::collections::HashSet::from([me]);
    let mut outcomes = Vec::new();
    if let Some(pid) = pid_hint {
        let same_name = process_exe(pid).is_some_and(|p| p.file_name() == want.file_name());
        if seen.insert(pid) && same_name {
            outcomes.push(sigterm(pid));
        }
    }
    for pid in all_pids()? {
        if seen.insert(pid) && process_exe(pid).as_deref() == Some(want.as_path()) {
            outcomes.push(sigterm(pid));
        }
    }
    stop_verdict(&outcomes)
}

/// 一次 `kill(SIGTERM)` 的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Signal {
    Sent,
    /// 枚举之后它自己退了（ESRCH），或不是本用户的进程（EPERM）——都不归我们。
    NotOurs,
    Failed(String),
}

fn sigterm(pid: u32) -> Signal {
    let Ok(raw) = libc::pid_t::try_from(pid) else {
        return Signal::NotOurs;
    };
    // SAFETY: kill 只读两个整数参数。
    if unsafe { libc::kill(raw, libc::SIGTERM) } == 0 {
        return Signal::Sent;
    }
    let err = std::io::Error::last_os_error();
    match err.raw_os_error() {
        Some(libc::ESRCH) | Some(libc::EPERM) => Signal::NotOurs,
        _ => Signal::Failed(format!("pid {pid}：{err}")),
    }
}

/// 把逐个进程的结果合成结论。纯函数，单测钉死：有一个没结束掉就是 `Err`
/// （DESK-25 #208 的教训：「没杀掉」被当成杀成功，调用方接着拉第二个 daemon）。
pub(crate) fn stop_verdict(outcomes: &[Signal]) -> crate::Result<KillOutcome> {
    let failures: Vec<&str> = outcomes
        .iter()
        .filter_map(|o| match o {
            Signal::Failed(d) => Some(d.as_str()),
            _ => None,
        })
        .collect();
    if !failures.is_empty() {
        return Err(PlatformError::Failed {
            action: "stop_daemon",
            detail: failures.join("; "),
        });
    }
    Ok(if outcomes.contains(&Signal::Sent) {
        KillOutcome::Killed
    } else {
        KillOutcome::NotRunning
    })
}

/// 进程的可执行文件绝对路径（已解析符号链接）；读不到 = `None`。
#[cfg(target_os = "macos")]
fn process_exe(pid: u32) -> Option<std::path::PathBuf> {
    use std::os::unix::ffi::OsStrExt as _;
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: buf 是本函数持有的缓冲区，长度如实传入。
    let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    let n = usize::try_from(n).ok().filter(|&n| n > 0)?;
    Some(std::ffi::OsStr::from_bytes(&buf[..n]).into())
}

#[cfg(not(target_os = "macos"))]
fn process_exe(pid: u32) -> Option<std::path::PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/exe")).ok()
}

/// 本机全部进程的 pid。
#[cfg(target_os = "macos")]
fn all_pids() -> crate::Result<Vec<u32>> {
    // 先问个数再取；进程数在两次调用之间会涨，多留余量。
    // SAFETY: 传空缓冲区只查询数量。
    let n = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if n <= 0 {
        return Err(PlatformError::Io {
            action: "stop_daemon",
            source: std::io::Error::last_os_error(),
        });
    }
    let mut buf = vec![0 as libc::c_int; n as usize + 64];
    let bytes = libc::c_int::try_from(buf.len() * std::mem::size_of::<libc::c_int>())
        .unwrap_or(libc::c_int::MAX);
    // SAFETY: buf 是本函数持有的缓冲区，字节数如实传入。
    let got = unsafe { libc::proc_listallpids(buf.as_mut_ptr().cast(), bytes) };
    if got <= 0 {
        return Err(PlatformError::Io {
            action: "stop_daemon",
            source: std::io::Error::last_os_error(),
        });
    }
    buf.truncate(got as usize);
    Ok(buf
        .into_iter()
        .filter_map(|p| u32::try_from(p).ok())
        .collect())
}

#[cfg(not(target_os = "macos"))]
fn all_pids() -> crate::Result<Vec<u32>> {
    let dir = std::fs::read_dir("/proc").map_err(|e| PlatformError::Io {
        action: "stop_daemon",
        source: e,
    })?;
    Ok(dir
        .filter_map(|e| e.ok()?.file_name().to_str()?.parse::<u32>().ok())
        .collect())
}

#[cfg(test)]
mod stop_tests {
    use super::*;

    #[test]
    fn nothing_signalled_is_not_running() {
        assert_eq!(stop_verdict(&[]).unwrap(), KillOutcome::NotRunning);
        assert_eq!(
            stop_verdict(&[Signal::NotOurs]).unwrap(),
            KillOutcome::NotRunning
        );
    }

    #[test]
    fn a_sent_signal_is_killed() {
        assert_eq!(
            stop_verdict(&[Signal::NotOurs, Signal::Sent]).unwrap(),
            KillOutcome::Killed
        );
    }

    /// 结束了一个、另一个失败 ⇒ 必须是 Err（DESK-25 #208）。
    #[test]
    fn any_failure_is_a_failure() {
        let e = stop_verdict(&[Signal::Sent, Signal::Failed("pid 42：boom".into())]).unwrap_err();
        assert!(e.to_string().contains("pid 42"), "{e}");
    }

    fn spawn(cmd: &mut std::process::Command) -> std::process::Child {
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap()
    }

    /// 设了它，[`sleeper`] 才真睡（值是秒数）。
    const SLEEPER_SECS_ENV: &str = "PPF_TEST_SLEEPER_SECS";

    /// 真进程测试里的「daemon」：把**本测试二进制**复制到目标路径，再只跑这一条。
    /// 平时（没设 [`SLEEPER_SECS_ENV`]）直接返回。
    ///
    /// 为什么不复制 `/bin/sleep`（#1230）：Ubuntu 26.04 的 `/bin/sleep` 是 uutils
    /// coreutils 的多合一程序，按 argv[0] 分派，改名成 `ppf-daemon` 后报
    /// `unknown program` 立刻退出。测试二进制一定是独立可执行文件，不看自己叫什么。
    #[test]
    fn sleeper() {
        if let Ok(secs) = std::env::var(SLEEPER_SECS_ENV) {
            std::thread::sleep(std::time::Duration::from_secs(secs.parse().unwrap()));
        }
    }

    /// 在 `exe`（本测试二进制的副本）上只跑 [`sleeper`]，睡 `secs` 秒。
    fn sleeper_at(exe: &Path, secs: u64) -> std::process::Command {
        // libtest 里的用例名不带 crate 前缀：`unix::stop_tests::sleeper`。
        let name = concat!(module_path!(), "::sleeper")
            .strip_prefix(concat!(env!("CARGO_CRATE_NAME"), "::"))
            .unwrap();
        let mut cmd = std::process::Command::new(exe);
        cmd.args([name, "--exact", "--test-threads=1"])
            .env(SLEEPER_SECS_ENV, secs.to_string());
        cmd
    }

    fn wait_until_exe(pid: u32, exe: &Path) {
        let want = std::fs::canonicalize(exe).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while process_exe(pid).as_deref() != Some(want.as_path()) {
            assert!(std::time::Instant::now() < deadline, "pid {pid} 没起来");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    /// B7（#1043）真进程：按可执行文件路径结束，**命令行里带 `ppf-daemon` 的
    /// 其他进程不会被杀**，同名但不在这个路径上的副本也不会。
    ///
    /// 反证：把判据改回「命令行含 ppf-daemon」（= 改前的 `pkill -f`）→
    /// 两个诱饵都被杀，`try_wait` 那两条红。
    #[test]
    fn stops_only_the_process_running_from_that_exact_path() {
        let tmp = tempfile::tempdir().unwrap();
        let me = std::env::current_exe().unwrap();
        let target = tmp
            .path()
            .join("bundle")
            .join(crate::DAEMON_EXECUTABLE_STEM);
        let elsewhere = tmp.path().join("dev").join(crate::DAEMON_EXECUTABLE_STEM);
        for p in [&target, &elsewhere] {
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::copy(&me, p).unwrap();
        }
        let mut daemon = spawn(&mut sleeper_at(&target, 30));
        // 诱饵 1：命令行里恰好含 `ppf-daemon`（pkill -f 会命中）。脚本写两条
        // 命令，免得 sh 直接 exec 成 sleep、命令行里没了这几个字。
        let mut decoy_cmdline = spawn(std::process::Command::new("/bin/sh").args([
            "-c",
            "sleep 20; :",
            crate::DAEMON_EXECUTABLE_STEM,
        ]));
        // 诱饵 2：同名可执行文件，但在另一个目录（开发构建）。
        let mut decoy_copy = spawn(&mut sleeper_at(&elsewhere, 30));
        wait_until_exe(daemon.id(), &target);
        wait_until_exe(decoy_copy.id(), &elsewhere);
        // 诱饵确实是改前判据会命中的形状（否则这条测试证明不了什么）。
        let args = std::process::Command::new("ps")
            .args(["-o", "args=", "-p", &decoy_cmdline.id().to_string()])
            .output()
            .unwrap();
        assert!(
            String::from_utf8_lossy(&args.stdout).contains(crate::DAEMON_EXECUTABLE_STEM),
            "诱饵命令行里应含 {}",
            crate::DAEMON_EXECUTABLE_STEM
        );

        // pid 提示指向命令行诱饵（sh）：文件名对不上，不许动它。
        let got = stop_processes_at(&target, Some(decoy_cmdline.id())).unwrap();
        assert_eq!(got, KillOutcome::Killed);
        let status = daemon.wait().unwrap();
        assert!(!status.success(), "目标应被 SIGTERM 结束：{status:?}");
        assert!(
            decoy_cmdline.try_wait().unwrap().is_none(),
            "命令行诱饵被误杀"
        );
        assert!(
            decoy_copy.try_wait().unwrap().is_none(),
            "别处的同名副本被误杀"
        );

        // 再停一次：已经没有在那个路径上跑的了。
        assert_eq!(
            stop_processes_at(&target, None).unwrap(),
            KillOutcome::NotRunning
        );

        // daemon 自报的 pid 优先：跑在别处的同名 daemon（开发构建）只要是它在
        // 应答 IPC，照样停得掉（同改前 `pkill -f` 的覆盖面）。
        assert_eq!(
            stop_processes_at(&target, Some(decoy_copy.id())).unwrap(),
            KillOutcome::Killed
        );
        assert!(!decoy_copy.wait().unwrap().success());
        assert!(
            decoy_cmdline.try_wait().unwrap().is_none(),
            "命令行诱饵被误杀"
        );

        for c in [&mut decoy_cmdline, &mut decoy_copy] {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}
