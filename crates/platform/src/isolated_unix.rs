//! `isolated` 的非 Windows 实现。macOS：经 `/usr/bin/sandbox-exec` 套 Seatbelt
//! （apply 后 exec，pid 不变）；其他 unix：普通子进程，无隔离（见 `isolated.rs`）。

use std::io;
use std::os::unix::process::CommandExt as _;
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Mutex};

use crate::isolated::{IsolatedChild, Isolation, Killer, Limits};

pub(crate) struct Inner {
    child: std::process::Child,
    /// 子进程已回收后置空，避免对被复用的 pid 发信号。
    pid: Arc<Mutex<Option<u32>>>,
}

impl Inner {
    pub(crate) fn isolation(&self) -> Isolation {
        #[cfg(target_os = "macos")]
        {
            Isolation::Seatbelt
        }
        #[cfg(not(target_os = "macos"))]
        {
            Isolation::None
        }
    }

    pub(crate) fn killer(&self) -> Killer {
        let pid = Arc::clone(&self.pid);
        Killer::new(move || {
            if let Ok(g) = pid.lock() {
                if let Some(p) = *g {
                    // SAFETY: 向自己拉起、尚未回收的子进程组发 SIGKILL。
                    unsafe {
                        // 负 pid = 整个进程组：连同它可能拉起的后代一起杀。
                        libc::kill(-(p as libc::pid_t), libc::SIGKILL);
                    }
                }
            }
        })
    }

    pub(crate) fn wait(&mut self) -> io::Result<bool> {
        let status = self.child.wait()?;
        if let Ok(mut g) = self.pid.lock() {
            *g = None;
        }
        Ok(status.success())
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        if let Ok(mut g) = self.pid.lock() {
            if g.take().is_some() {
                unsafe {
                    libc::kill(-(self.child.id() as libc::pid_t), libc::SIGKILL);
                }
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }
    }
}

pub(crate) fn spawn(exe: &Path, limits: &Limits) -> io::Result<IsolatedChild> {
    #[cfg(target_os = "macos")]
    let mut cmd = seatbelt::command(exe)?;
    #[cfg(not(target_os = "macos"))]
    let mut cmd = {
        let _ = limits;
        crate::command(exe)
    };
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        // 自成一组，强杀时整组一起走。
        .process_group(0)
        .spawn()?;
    let stdin = child.stdin.take().map(|s| Box::new(s) as _);
    let stdout = child.stdout.take().map(|s| Box::new(s) as _);
    let pid = Arc::new(Mutex::new(Some(child.id())));
    #[cfg(target_os = "macos")]
    seatbelt::watch_memory(Arc::clone(&pid), limits.memory_bytes);
    Ok(IsolatedChild {
        stdin,
        stdout,
        inner: Inner { child, pid },
    })
}

#[cfg(target_os = "macos")]
mod seatbelt {
    use std::io;
    use std::path::Path;
    use std::process::Command;
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::Duration;

    const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

    /// deny-default。只放行：执行 worker 本身、读系统库与 worker 所在目录
    /// （自带的 dylib）、读写 /dev/null。没有网络、mach-lookup、fork、用户目录。
    /// 管道是继承来的 fd，不受路径规则约束。
    /// 调试构建额外放行 Homebrew 前缀，只为本机开发时 worker 链着系统 libheif。
        /// 与 tools/bundle-desktop-macos.sh 的打包自检共用同一份文件。
    const PROFILE: &str = include_str!("seatbelt.sb");

    #[cfg(debug_assertions)]
    const DEV_EXTRA: &str = r#"(allow file-map-executable (subpath "/opt/homebrew") (subpath "/usr/local"))
(allow file-read* (subpath "/opt/homebrew") (subpath "/usr/local"))
"#;
    #[cfg(not(debug_assertions))]
    const DEV_EXTRA: &str = "";

    /// 仅调试构建：`PPF_SEATBELT_TEST_EXEC`（冒号分隔的绝对路径）额外放行这些程序的
    /// 执行与读取，并放开 fork——给 media-codec 的假 worker（sh 脚本）用。
    /// release 构建不认；路径含引号 / 反斜杠 / 括号时忽略，避免拼出别的规则。
    fn test_exec_rules() -> String {
        #[cfg(debug_assertions)]
        if let Some(v) = std::env::var_os("PPF_SEATBELT_TEST_EXEC") {
            let mut out = String::from("(allow process-fork)\n");
            for p in v.to_string_lossy().split(':') {
                if p.starts_with('/') && !p.contains(['"', '\\', '(', ')', ';', '\n']) {
                    out.push_str(&format!(
                        "(allow process-exec (literal \"{p}\"))\n(allow file-map-executable (literal \"{p}\"))\n(allow file-read* (literal \"{p}\"))\n"
                    ));
                }
            }
            return out;
        }
        String::new()
    }

    fn profile() -> String {
        format!("{PROFILE}{DEV_EXTRA}{}", test_exec_rules())
    }

    fn base(exe: &Path, dir: &Path, profile: &str) -> Command {
        let mut c = crate::command(SANDBOX_EXEC);
        c.arg("-D")
            .arg(format!("EXE={}", exe.display()))
            .arg("-D")
            .arg(format!("EXEDIR={}", dir.display()))
            .arg("-p")
            .arg(profile);
        c
    }

    /// 本机能否真的套上这份沙箱（sandbox-exec 缺失、被更外层沙箱拒绝、SBPL 被系统
    /// 拒绝都在这里暴露）。进程内只验一次；不通过时 `spawn` 一律报错，绝不退成无隔离。
    fn self_check() -> &'static Result<(), String> {
        static CHECK: OnceLock<Result<(), String>> = OnceLock::new();
        CHECK.get_or_init(|| {
            let exe = Path::new("/usr/bin/true");
            let out = base(exe, Path::new("/usr/bin"), &profile())
                .arg(exe)
                .output()
                .map_err(|e| format!("{SANDBOX_EXEC}: {e}"))?;
            if out.status.success() {
                Ok(())
            } else {
                Err(format!(
                    "seatbelt self-check failed ({}): {}",
                    out.status,
                    String::from_utf8_lossy(&out.stderr).trim()
                ))
            }
        })
    }

    pub(super) fn command(exe: &Path) -> io::Result<Command> {
        if let Err(e) = self_check() {
            return Err(io::Error::other(e.clone()));
        }
        // 参数里的路径必须是真实路径（/var → /private/var 等符号链接在沙箱里按真实路径比）。
        let exe = std::fs::canonicalize(exe)?;
        let dir = exe
            .parent()
            .ok_or_else(|| io::Error::other("worker has no parent dir"))?
            .to_path_buf();
        let mut c = base(&exe, &dir, &profile());
        c.arg(&exe);
        Ok(c)
    }

    /// Darwin 不执行 RLIMIT_AS / RLIMIT_DATA，改为轮询物理占用，超限整组强杀。
    /// 与 Windows Job 的区别：这里是「事后杀」，超限到被杀之间有一个轮询周期的窗口。
    pub(super) fn watch_memory(pid: Arc<Mutex<Option<u32>>>, limit: u64) {
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(20));
            let Ok(g) = pid.lock() else { return };
            let Some(p) = *g else { return };
            let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
            // SAFETY: 向内核查询自己拉起、尚未回收的子进程；缓冲区大小与 flavor 匹配。
            let rc = unsafe {
                libc::proc_pid_rusage(
                    p as libc::c_int,
                    libc::RUSAGE_INFO_V2,
                    &mut info as *mut _ as *mut libc::rusage_info_t,
                )
            };
            if rc == 0 && info.ri_phys_footprint > limit {
                // SAFETY: 同 Killer，持锁期间 pid 不会被回收复用。
                unsafe {
                    libc::kill(-(p as libc::pid_t), libc::SIGKILL);
                }
                return;
            }
        });
    }
}
