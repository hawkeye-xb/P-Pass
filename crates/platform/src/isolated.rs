//! 把一个不可信输入的解码放进被隔离的子进程里跑的「拉起」能力。
//!
//! 协议与进程模型各平台一致：子进程只有 stdin / stdout 两根管道，一次性读入、
//! 一次性写出；换的只是「怎么拉起一个被隔离的子进程」。
//!
//! - Windows：AppContainer（不授任何 capability）+ Job（关闭即杀、禁子进程、
//!   单进程内存上限）+ win32k lockdown + 句柄白名单，见 `isolated_windows.rs`。
//! - 其他平台（含 macOS）：暂无隔离，普通子进程；[`IsolatedChild::isolation`]
//!   如实报告 [`Isolation::None`]。
//!
//! 拉起失败一律返回 `Err`，**不回退成不隔离的拉起**：调用方据此判定「本机沙箱
//! 不可用」，而不是悄悄在不安全的条件下继续。

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[cfg(not(windows))]
use crate::isolated_unix as sys;
#[cfg(windows)]
use crate::isolated_windows as sys;

/// 子进程实际获得的隔离程度。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Isolation {
    /// 普通子进程，没有任何隔离。
    None,
    /// Windows AppContainer + Job。
    AppContainer,
}

/// 资源上限。
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// 子进程内存上限（字节）。Windows 由 Job 强制；其他平台暂不强制。
    pub memory_bytes: u64,
}

/// 可跨线程持有的「强杀」句柄；子进程已结束后调用无副作用。
#[derive(Clone)]
pub struct Killer(Arc<dyn Fn() + Send + Sync>);

impl Killer {
    pub(crate) fn new(f: impl Fn() + Send + Sync + 'static) -> Self {
        Killer(Arc::new(f))
    }
    pub fn kill(&self) {
        (self.0)()
    }
}

/// 被拉起的子进程。丢弃即强杀（Windows 靠 Job 的关闭即杀）。
pub struct IsolatedChild {
    pub stdin: Option<Box<dyn Write + Send>>,
    pub stdout: Option<Box<dyn Read + Send>>,
    pub(crate) inner: sys::Inner,
}

impl IsolatedChild {
    pub fn isolation(&self) -> Isolation {
        self.inner.isolation()
    }
    pub fn killer(&self) -> Killer {
        self.inner.killer()
    }
    /// 等子进程退出；返回是否以成功状态退出。
    pub fn wait(&mut self) -> io::Result<bool> {
        self.inner.wait()
    }
}

/// 拉起 `exe`（无参数），stdin/stdout 接管道，stderr 丢弃。
pub fn spawn_isolated(exe: &Path, limits: &Limits) -> io::Result<IsolatedChild> {
    sys::spawn(exe, limits)
}

/// 解码子进程 `ppf-decoder` 的位置：与当前可执行文件同目录。
/// debug 构建另认 `PPF_DECODE_WORKER`（测试指向 cargo 构建出的二进制），
/// 并在测试二进制所在的 `deps/` 的上一层找；release 构建两者都不认。
pub fn decoder_worker_path() -> Option<PathBuf> {
    let name = if cfg!(windows) {
        "ppf-decoder.exe"
    } else {
        "ppf-decoder"
    };
    #[cfg(debug_assertions)]
    if let Some(p) = std::env::var_os("PPF_DECODE_WORKER") {
        return Some(PathBuf::from(p));
    }
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let mut candidates = vec![dir.join(name)];
    #[cfg(debug_assertions)]
    if let Some(up) = dir.parent() {
        candidates.push(up.join(name));
    }
    candidates.into_iter().find(|p| p.is_file())
}
