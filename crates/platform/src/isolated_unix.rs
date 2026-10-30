//! `isolated` 的非 Windows 实现：普通子进程，无隔离（见 `isolated.rs`）。

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
        Isolation::None
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

pub(crate) fn spawn(exe: &Path, _limits: &Limits) -> io::Result<IsolatedChild> {
    let mut child = crate::command(exe)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        // 自成一组，强杀时整组一起走。
        .process_group(0)
        .spawn()?;
    let stdin = child.stdin.take().map(|s| Box::new(s) as _);
    let stdout = child.stdout.take().map(|s| Box::new(s) as _);
    let pid = Arc::new(Mutex::new(Some(child.id())));
    Ok(IsolatedChild {
        stdin,
        stdout,
        inner: Inner { child, pid },
    })
}
