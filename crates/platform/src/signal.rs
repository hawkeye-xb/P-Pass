//! #1047：进程停止信号（SIGTERM / Windows 控制台关闭事件）。
//!
//! 为什么要接：服务管理器停服务（launchd bootout、systemd stop、docker stop）
//! 的第一步都是发 SIGTERM，等一个宽限期再 SIGKILL。不接，等于被直接杀掉；
//! 接了，daemon 才有机会停接新连接、收尾后再走。
//!
//! 为什么在这个 crate：信号机制是平台差异（unix 信号 / Windows 控制台事件），
//! daemon 里不许出现 `cfg(windows)` 之类的分支（门禁 B.2 / G5）。daemon 只用
//! 这两个平台无关的入口：[`stop_signal`] 等一次停止请求，[`StopRequest::finish`]
//! 在收尾后以「被这个信号终止」的方式离开。
//!
//! 与 PlatformAdapter 无关，独立成函数：adapter trait 正被拆分，不往里加方法。
//!
//! ⚠️ 产品路径上 Windows 的「停止」多半是 `TerminateProcess`（DESK-52 的
//! kill_daemon_process、计划任务的「结束」对无窗口进程同理），那种硬杀任何
//! 处理器都收不到——所以真正的数据安全不能依赖这里，由落盘侧（入库不留
//! 占位、启动清残留）兜底。这里只负责「收得到信号时体面地走」。

/// 托管方（Windows SCM）登记的「停止」通道。进程级：一个进程只有一个服务上下文。
#[cfg(windows)]
static SERVICE_STOP: std::sync::OnceLock<tokio::sync::Notify> = std::sync::OnceLock::new();
#[cfg(windows)]
static SERVICE_STOP_NAME: std::sync::Mutex<Option<&'static str>> = std::sync::Mutex::new(None);

/// 由托管方（SCM）要求停止：唤醒 [`stop_signal`]，名字用 `name`。
///
/// 只给平台自己的服务托管用；daemon 不需要调用。不走信号，所以在服务（session 0、
/// 没有控制台事件）里也能让 daemon 走正常收尾路径。
#[cfg(windows)]
pub fn request_stop(name: &'static str) {
    *SERVICE_STOP_NAME.lock().expect("stop name lock") = Some(name);
    // notify_one 会保留一个 permit：此刻没有等待者，下一次 stop_signal 也会立刻返回。
    SERVICE_STOP
        .get_or_init(tokio::sync::Notify::new)
        .notify_one();
}

/// 一次收到的停止请求。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StopRequest {
    name: &'static str,
    #[cfg(unix)]
    signo: i32,
}

impl StopRequest {
    /// 人读的信号名，写日志用（`SIGTERM`、`CTRL_CLOSE` 等）。
    pub fn name(&self) -> &'static str {
        self.name
    }

    /// 收尾完成后离开进程，**不返回**。
    ///
    /// unix：把该信号恢复成默认处理再对自己重发一次，进程以「被信号终止」
    /// 结束。这样 launchd / systemd / docker 看到的退出状态与没有接信号时
    /// 完全一样——尤其 plist 的 `KeepAlive{SuccessfulExit=false}` 依赖「被
    /// 杀 = 非成功退出 = 重拉」（桌面壳的「重启 daemon」就是 pkill 后等
    /// launchd 复活）；若改成 `exit(0)`，launchd 会把它当成正常退出，从此
    /// 不再拉起。
    ///
    /// Windows：没有「被信号终止」的概念，`exit(0)`；任务计划程序的每分钟
    /// 看门狗不看退出码。
    pub fn finish(self) -> ! {
        #[cfg(unix)]
        {
            // SAFETY: signal/raise 都是 async-signal-safe 的简单系统调用；
            // 先恢复 SIG_DFL，raise 之后进程即终止。
            unsafe {
                libc::signal(self.signo, libc::SIG_DFL);
                libc::raise(self.signo);
            }
            // 信号被屏蔽等极端情况下 raise 可能不终止进程，兜底退出。
        }
        std::process::exit(if cfg!(unix) { 143 } else { 0 })
    }
}

/// 等到一次停止请求。信号处理器在**第一次调用**时才装；装不上（极罕见）
/// 则永远不返回——此时行为与不接信号一致，不比现状差。
///
/// 停止请求到来后调用方应再调用一次本函数，把「第二次请求」当作「别等了，
/// 立刻走」。
#[cfg(unix)]
pub async fn stop_signal() -> StopRequest {
    use tokio::signal::unix::{signal, SignalKind};
    let kinds = [
        (SignalKind::terminate(), "SIGTERM", libc::SIGTERM),
        (SignalKind::interrupt(), "SIGINT", libc::SIGINT),
        (SignalKind::hangup(), "SIGHUP", libc::SIGHUP),
    ];
    let mut streams = Vec::new();
    for (kind, name, signo) in kinds {
        if let Ok(s) = signal(kind) {
            streams.push((s, name, signo));
        }
    }
    if streams.is_empty() {
        return std::future::pending().await;
    }
    std::future::poll_fn(|cx| {
        for (s, name, signo) in streams.iter_mut() {
            if s.poll_recv(cx).is_ready() {
                return std::task::Poll::Ready(StopRequest {
                    name,
                    signo: *signo,
                });
            }
        }
        std::task::Poll::Pending
    })
    .await
}

#[cfg(windows)]
pub async fn stop_signal() -> StopRequest {
    use std::future::Future;
    use std::task::Poll;
    use tokio::signal::windows::{ctrl_break, ctrl_c, ctrl_close, ctrl_logoff, ctrl_shutdown};

    // 先把「托管方要求停止」的等待者建出来，避免请求与注册之间的竞态。
    let notified = SERVICE_STOP
        .get_or_init(tokio::sync::Notify::new)
        .notified();
    tokio::pin!(notified);
    let (Ok(mut c), Ok(mut b), Ok(mut close), Ok(mut logoff), Ok(mut shutdown)) = (
        ctrl_c(),
        ctrl_break(),
        ctrl_close(),
        ctrl_logoff(),
        ctrl_shutdown(),
    ) else {
        return std::future::pending().await;
    };
    std::future::poll_fn(|cx| {
        if notified.as_mut().poll(cx).is_ready() {
            let name = SERVICE_STOP_NAME
                .lock()
                .ok()
                .and_then(|mut g| g.take())
                .unwrap_or("SERVICE_STOP");
            return Poll::Ready(StopRequest { name });
        }
        let hit = if c.poll_recv(cx).is_ready() {
            "CTRL_C"
        } else if b.poll_recv(cx).is_ready() {
            "CTRL_BREAK"
        } else if close.poll_recv(cx).is_ready() {
            "CTRL_CLOSE"
        } else if logoff.poll_recv(cx).is_ready() {
            "CTRL_LOGOFF"
        } else if shutdown.poll_recv(cx).is_ready() {
            "CTRL_SHUTDOWN"
        } else {
            return std::task::Poll::Pending;
        };
        std::task::Poll::Ready(StopRequest { name: hit })
    })
    .await
}

/// 其它平台（Linux 开发机）：与 unix 同一套——`cfg(unix)` 已覆盖。
/// 这里只给「既非 unix 也非 windows」的目标一个永不返回的实现，保证能编。
#[cfg(not(any(unix, windows)))]
pub async fn stop_signal() -> StopRequest {
    std::future::pending().await
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    /// 给自己发 SIGTERM，`stop_signal` 必须返回而不是杀掉测试进程。
    /// （处理器装好之前发信号会杀进程——所以先让 future 跑到装好处理器。）
    #[tokio::test(flavor = "multi_thread")]
    async fn sigterm_is_delivered_to_stop_signal_instead_of_killing() {
        let waiter = tokio::spawn(stop_signal());
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        unsafe { libc::raise(libc::SIGTERM) };
        let got = tokio::time::timeout(std::time::Duration::from_secs(5), waiter)
            .await
            .expect("5s 内必须收到")
            .unwrap();
        assert_eq!(got.name(), "SIGTERM");
    }
}

#[cfg(all(test, windows))]
mod service_stop_tests {
    use super::*;

    /// 托管方（SCM）请求停止时，`stop_signal` 必须返回，名字是登记的那个。
    #[tokio::test(flavor = "multi_thread")]
    async fn requested_stop_wakes_stop_signal() {
        let waiter = tokio::spawn(stop_signal());
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        request_stop("SERVICE_CONTROL_STOP");
        let got = tokio::time::timeout(std::time::Duration::from_secs(5), waiter)
            .await
            .expect("5s 内必须收到")
            .unwrap();
        assert_eq!(got.name(), "SERVICE_CONTROL_STOP");
    }
}
