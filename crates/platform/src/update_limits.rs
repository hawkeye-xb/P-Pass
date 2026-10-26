//! #1151：应用内更新的大小上限与总时长上限（TUF 的 endless data / slow retrieval）。
//!
//! 更新源返回无限长的数据、或慢到几乎不动时，下载要中止，而不是把内存读爆或一直挂着。
//! 这里只放与 updater 插件无关的纯逻辑，桌面壳的 `update_install.rs` 把插件的 `check()` /
//! `download()` 包进来：
//! - 总时长：`tokio::time::timeout`，到点丢弃 future（连接随之关闭）；
//! - 大小：插件的 `download` 每收到一块调一次回调（含服务端声明的 Content-Length），
//!   回调里累计字节，超限就置位；包装层在下一次轮询时发现置位，立即丢弃 future。
//!   回调就在 `download` 被轮询的过程中同步调用，所以置位后无需额外唤醒。
//!
//! 插件内部读清单没有字节回调，清单只能靠总时长兜底。
//!
//! 纯逻辑、三平台都编译并跑单测；只有桌面壳的更新路径调用它。

use std::fmt;
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::task::Poll;
use std::time::Duration;

/// 检查更新（清单）的总时长上限。
pub const MANIFEST_TIMEOUT: Duration = Duration::from_secs(30);
/// 安装包下载的大小上限。当前最大的包约 21–23MB（macOS），留 10 倍以上余量。
pub const PACKAGE_MAX_BYTES: u64 = 256 * 1024 * 1024;
/// 安装包下载的总时长上限：面向慢网络（国内下 GitHub 资产），整次下载一小时。
pub const PACKAGE_TIMEOUT: Duration = Duration::from_secs(60 * 60);

/// 超限的两种原因，或被包住的操作自己的错误。
#[derive(Debug, PartialEq, Eq)]
pub enum LimitError<E> {
    Inner(E),
    TooLarge { max_bytes: u64 },
    TimedOut(Duration),
}

impl<E: fmt::Display> fmt::Display for LimitError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Inner(e) => write!(f, "{e}"),
            Self::TooLarge { max_bytes } => {
                write!(
                    f,
                    "update package exceeds the {} MiB size limit; download aborted",
                    max_bytes / (1024 * 1024)
                )
            }
            Self::TimedOut(d) => write!(
                f,
                "update did not complete within {} s; aborted",
                d.as_secs()
            ),
        }
    }
}

/// 累计收到的字节，超过上限就置位。回调里调用 [`ByteBudget::on_chunk`]。
#[derive(Debug)]
pub struct ByteBudget {
    max_bytes: u64,
    seen: AtomicU64,
    tripped: AtomicBool,
}

impl ByteBudget {
    pub fn new(max_bytes: u64) -> Arc<Self> {
        Arc::new(Self {
            max_bytes,
            seen: AtomicU64::new(0),
            tripped: AtomicBool::new(false),
        })
    }

    /// 与 `tauri_plugin_updater::Update::download` 的块回调同形：本块长度、服务端声明的总长度。
    /// 声明的总长度本身超限就立刻置位（一个字节都不用等）；声明可以撒谎或缺失，所以
    /// 同时按实际累计字节判。
    pub fn on_chunk(&self, chunk_len: usize, declared_total: Option<u64>) {
        if declared_total.is_some_and(|t| t > self.max_bytes) {
            self.tripped.store(true, Ordering::SeqCst);
        }
        let seen = self.seen.fetch_add(chunk_len as u64, Ordering::SeqCst) + chunk_len as u64;
        if seen > self.max_bytes {
            self.tripped.store(true, Ordering::SeqCst);
        }
    }

    pub fn tripped(&self) -> bool {
        self.tripped.load(Ordering::SeqCst)
    }

    pub fn max_bytes(&self) -> u64 {
        self.max_bytes
    }
}

/// 只限总时长（检查更新用）。
pub async fn with_timeout<T, E, F>(timeout: Duration, op: F) -> Result<T, LimitError<E>>
where
    F: Future<Output = Result<T, E>>,
{
    match tokio::time::timeout(timeout, op).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(LimitError::Inner(e)),
        Err(_) => Err(LimitError::TimedOut(timeout)),
    }
}

/// 总时长 + 大小（下载用）：`op` 里的字节回调必须喂给同一个 [`ByteBudget`]。
pub async fn with_limits<T, E, F>(
    timeout: Duration,
    budget: Arc<ByteBudget>,
    op: F,
) -> Result<T, LimitError<E>>
where
    F: Future<Output = Result<T, E>>,
{
    let max_bytes = budget.max_bytes();
    let mut op = Box::pin(op);
    let guarded = std::future::poll_fn(move |cx| match op.as_mut().poll(cx) {
        Poll::Ready(Ok(v)) => Poll::Ready(Ok(v)),
        Poll::Ready(Err(e)) => Poll::Ready(Err(LimitError::Inner(e))),
        Poll::Pending if budget.tripped() => Poll::Ready(Err(LimitError::TooLarge { max_bytes })),
        Poll::Pending => Poll::Pending,
    });
    match tokio::time::timeout(timeout, guarded).await {
        Ok(r) => r,
        Err(_) => Err(LimitError::TimedOut(timeout)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::task::Context;

    /// 假下载：每次被轮询送出 `chunk` 字节（经回调），共 `chunks` 次后结束（`None` = 永不结束）。
    /// 与真实 `download` 一样，回调在 future 被轮询的过程中同步调用。
    struct FakeDownload {
        budget: Arc<ByteBudget>,
        declared_total: Option<u64>,
        chunk: usize,
        chunks: Option<u32>,
        sent: u32,
        pending_between_chunks: bool,
    }

    impl Future for FakeDownload {
        type Output = Result<usize, String>;
        fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
            loop {
                if self.chunks.is_some_and(|n| self.sent >= n) {
                    return Poll::Ready(Ok(self.sent as usize * self.chunk));
                }
                self.sent += 1;
                self.budget.on_chunk(self.chunk, self.declared_total);
                if self.pending_between_chunks {
                    cx.waker().wake_by_ref();
                    return Poll::Pending;
                }
            }
        }
    }

    fn fake(
        budget: &Arc<ByteBudget>,
        declared: Option<u64>,
        chunk: usize,
        chunks: Option<u32>,
    ) -> FakeDownload {
        FakeDownload {
            budget: budget.clone(),
            declared_total: declared,
            chunk,
            chunks,
            sent: 0,
            pending_between_chunks: true,
        }
    }

    const LONG: Duration = Duration::from_secs(30);

    #[tokio::test]
    async fn within_limits_succeeds() {
        let b = ByteBudget::new(10_000);
        let r = with_limits(LONG, b.clone(), fake(&b, Some(4_000), 1_000, Some(4))).await;
        assert_eq!(r, Ok(4_000));
    }

    #[tokio::test]
    async fn exactly_at_the_limit_still_succeeds() {
        let b = ByteBudget::new(4_000);
        let r = with_limits(LONG, b.clone(), fake(&b, Some(4_000), 1_000, Some(4))).await;
        assert_eq!(r, Ok(4_000));
    }

    #[tokio::test]
    async fn endless_stream_without_declared_length_is_cut_at_the_size_limit() {
        let b = ByteBudget::new(10_000);
        let r = with_limits(LONG, b.clone(), fake(&b, None, 1_000, None)).await;
        assert_eq!(r, Err(LimitError::TooLarge { max_bytes: 10_000 }));
        // 超限后立即丢弃，不会继续累计到无穷。
        assert!(
            b.seen.load(Ordering::SeqCst) <= 12_000,
            "seen={}",
            b.seen.load(Ordering::SeqCst)
        );
    }

    #[tokio::test]
    async fn declared_length_over_the_limit_aborts_on_the_first_chunk() {
        let b = ByteBudget::new(10_000);
        let r = with_limits(LONG, b.clone(), fake(&b, Some(1_000_000), 10, None)).await;
        assert_eq!(r, Err(LimitError::TooLarge { max_bytes: 10_000 }));
        assert_eq!(b.seen.load(Ordering::SeqCst), 10, "第一块之后就该中止");
    }

    #[tokio::test]
    async fn a_lying_short_declared_length_does_not_bypass_the_limit() {
        let b = ByteBudget::new(10_000);
        let r = with_limits(LONG, b.clone(), fake(&b, Some(100), 1_000, None)).await;
        assert_eq!(r, Err(LimitError::TooLarge { max_bytes: 10_000 }));
    }

    #[tokio::test]
    async fn a_stalled_download_hits_the_total_timeout() {
        let b = ByteBudget::new(10_000);
        let never = std::future::pending::<Result<(), String>>();
        let r = with_limits(Duration::from_millis(50), b, never).await;
        assert_eq!(r, Err(LimitError::TimedOut(Duration::from_millis(50))));
    }

    #[tokio::test]
    async fn a_trickling_download_hits_the_total_timeout_even_though_bytes_keep_coming() {
        let b = ByteBudget::new(u64::MAX);
        let slow = async {
            loop {
                b.on_chunk(1, None);
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            #[allow(unreachable_code)]
            Ok::<(), String>(())
        };
        let r = with_limits(Duration::from_millis(100), b.clone(), slow).await;
        assert_eq!(r, Err(LimitError::TimedOut(Duration::from_millis(100))));
    }

    #[tokio::test]
    async fn the_inner_error_passes_through() {
        let b = ByteBudget::new(10_000);
        let r = with_limits(LONG, b, async { Err::<(), _>("boom".to_string()) }).await;
        assert_eq!(r, Err(LimitError::Inner("boom".to_string())));
    }

    #[tokio::test]
    async fn with_timeout_cuts_a_hung_manifest_fetch_and_passes_results_through() {
        let hung = with_timeout(
            Duration::from_millis(50),
            std::future::pending::<Result<(), String>>(),
        )
        .await;
        assert_eq!(hung, Err(LimitError::TimedOut(Duration::from_millis(50))));
        let ok = with_timeout(LONG, async { Ok::<_, String>(7) }).await;
        assert_eq!(ok, Ok(7));
        let err = with_timeout(LONG, async { Err::<(), _>("e".to_string()) }).await;
        assert_eq!(err, Err(LimitError::Inner("e".to_string())));
    }

    #[test]
    fn production_limits_are_sane() {
        // 编译期断言：上限被改成离谱的值时直接编译不过。
        const {
            assert!(
                PACKAGE_MAX_BYTES >= 100 * 1024 * 1024 && PACKAGE_MAX_BYTES <= 1024 * 1024 * 1024
            );
            assert!(PACKAGE_TIMEOUT.as_secs() >= 30 * 60);
            assert!(MANIFEST_TIMEOUT.as_secs() >= 5 && MANIFEST_TIMEOUT.as_secs() <= 120);
        }
    }

    #[test]
    fn messages_say_what_happened() {
        let big: LimitError<String> = LimitError::TooLarge {
            max_bytes: 256 * 1024 * 1024,
        };
        assert!(big.to_string().contains("256 MiB"));
        let slow: LimitError<String> = LimitError::TimedOut(Duration::from_secs(30));
        assert!(slow.to_string().contains("30 s"));
    }
}
