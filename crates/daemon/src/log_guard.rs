//! NET-02: fold repeated log lines, cap total bytes. DEVLOG-01: same
//! folding/capping guard, generalized to also drive a persistent file sink.
//!
//! 2026-08-26 家中真机实锤：Clash 把 iroh relay 的 TLS 握手流量代理
//! 掉，握手失败在 7 分钟内被逐条打印了 92211 次（73MB）。失败重试本身
//! 没错——错的是每一次重试都逐条写 `tls handshake eof` 到 `.err`。这些
//! 行来自 iroh/quinn 内部的 `tracing` 调用，不是我们自己代码里的日志
//! 点，所以折叠必须做在 subscriber 层，而不是某个我们能改的调用处。
//!
//! 折叠规则：同一条格式化后的行（去掉行首会变化的时间戳）第一次出现
//! 立即打印；之后的重复只计数，直到这条消息安静了 [`IDLE_GAP`] 才打一
//! 条汇总（次数 + 持续时长），随后这个 key 被清空——如果同一种错误
//! 后来又发生，会被当成新的一轮重新走"第一条立即打印"。偶发的单次
//! 失败只会走"第一条立即打印"这一步，安静期到了也不会补发多余的
//! "×1" 汇总。
//!
//! 体积上限是另一道独立的背景防线：折叠按*完全相同的文本*分
//! 组，如果某个循环 bug 每次都带一点不同的内容（比如带自增计数器），
//! 折叠会失效——这道上限保证即使折叠没接住，一次运行也不会把磁盘写爆。
//!
//! DEVLOG-01：本模块原本只管 stderr（生产靠 launchd plist 的
//! `StandardErrorPath` 落盘）。开发期手动前台起 daemon 时没有 launchd
//! 托管，日志只在终端一闪而过——出问题只能"复现时临时开一次日志"，
//! 而不是"出问题时日志已经在"。`DedupGuard::for_file` 把同一套折叠 +
//! 上限截断逻辑接到一个持久文件上，由 `PPF_LOG_FILE` 环境变量启用；
//! 不设就是原来的行为（只写 stderr），不影响生产 launchd 路径。

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::time::Instant;
use tracing_subscriber::fmt::MakeWriter;

/// 同一条消息安静这么久，才认为"这一轮折叠结束"并打汇总行。
const IDLE_GAP: Duration = Duration::from_secs(2);

/// 单次 daemon 运行里，同一个 sink（stderr 或持久日志文件）写入的字节数
/// 上限。超过就地 truncate 重来——不是等外部工具（launchd/logrotate）来
/// 做,那些工具从没为这个配过。
const SINK_CAP_BYTES: usize = 8 * 1024 * 1024;

struct KeyState {
    first_seen: Instant,
    last_seen: Instant,
    count: u64,
}

/// 折叠器实际写向哪里。Stderr 分支复用旧的 fd 2 truncate 技巧（launchd
/// 把 `.err` dup2 到 fd 2）；File 分支持有自己打开的句柄，truncate 就是
/// 标准的 `set_len(0)`——不需要 fd 层面的技巧，跨平台都能用。
enum Sink {
    Stderr,
    File(Mutex<File>),
}

/// 字节计数 + 超限 truncate，多个 writer 共享一份。
#[derive(Clone)]
struct BoundedSink {
    sink: Arc<Sink>,
    written: Arc<Mutex<usize>>,
}

impl BoundedSink {
    fn stderr() -> Self {
        Self {
            sink: Arc::new(Sink::Stderr),
            written: Arc::new(Mutex::new(0)),
        }
    }

    fn file(file: File) -> Self {
        Self {
            sink: Arc::new(Sink::File(Mutex::new(file))),
            written: Arc::new(Mutex::new(0)),
        }
    }

    fn write_line(&self, buf: &[u8]) {
        let mut written = self.written.lock().expect("sink byte counter lock");
        if *written + buf.len() >= SINK_CAP_BYTES {
            self.truncate();
            let marker = format!(
                "--- p-pass: 日志超过 {}MB（本次运行），已截断——防止某个失败循环把磁盘写满 ---\n",
                SINK_CAP_BYTES / (1024 * 1024)
            );
            self.raw_write(marker.as_bytes());
            *written = marker.len();
        }
        *written += buf.len();
        self.raw_write(buf);
    }

    fn raw_write(&self, buf: &[u8]) {
        match &*self.sink {
            Sink::Stderr => {
                let _ = io::stderr().write_all(buf);
            }
            Sink::File(f) => {
                let mut f = f.lock().expect("log file lock");
                let _ = f.write_all(buf);
                let _ = f.flush();
            }
        }
    }

    fn truncate(&self) {
        match &*self.sink {
            Sink::Stderr => truncate_stderr(),
            Sink::File(f) => {
                let f = f.lock().expect("log file lock");
                // 以 append 模式打开的文件，下一次写入永远落在"当前文件
                // 末尾"（POSIX/Win32 append 语义），set_len(0) 之后末尾
                // 就是 0，不需要额外 seek。
                let _ = f.set_len(0);
            }
        }
    }
}

#[cfg(unix)]
fn truncate_stderr() {
    use std::os::fd::FromRawFd;
    // fd 2 就是我们自己的 stderr——launchd/systemd 等把真正的 `.err`
    // 文件 open() 之后 dup2 到 fd 2 才 exec 我们，所以对 fd 2
    // set_len(0)+seek(0) 动的就是那个文件本身。ManuallyDrop：这只是
    // 借用 fd 2 的视角，这里把它 drop 掉会把 stderr 从整个进程手里
    // 关掉。
    let mut file = std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(2) });
    let _ = file.set_len(0);
    let _ = io::Seek::seek(&mut *file, io::SeekFrom::Start(0));
}

#[cfg(not(unix))]
fn truncate_stderr() {
    // Windows 等平台：还没接 fd 级别的 truncate（需要 SetEndOfFile 之
    // 类的 Win32 调用）。计数器照样清零（不会每行都重复触发这个分
    // 支），但底层文件不会真的变小——已知缺口，不装作修好了。上面的
    // 折叠才是所有平台共同的主防线。
}

/// 从一条已格式化的日志行里去掉行首的时间戳（唯一每次都会变化的部
/// 分），拿剩下的内容（level/target/message/fields）当折叠 key。
/// `tracing_subscriber` 默认 timer 的输出是不含空格的单个 token,后面
/// 紧跟一个空格再是 level——所以"找第一个空格切开"是稳的,不依赖具体
/// 时间戳格式的细节。
fn fold_key(line: &[u8]) -> &[u8] {
    let after_ts = match line.iter().position(|&b| b == b' ') {
        Some(i) => &line[i + 1..],
        None => line,
    };
    after_ts.strip_suffix(b"\n").unwrap_or(after_ts)
}

fn human_duration(d: Duration) -> String {
    let secs = d.as_secs();
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m{}s", secs / 60, secs % 60)
    } else {
        format!("{}h{}m", secs / 3600, (secs % 3600) / 60)
    }
}

/// 装进 `tracing_subscriber::fmt().with_writer(...)` 的折叠器。
#[derive(Clone)]
pub struct DedupGuard {
    state: Arc<Mutex<HashMap<Vec<u8>, KeyState>>>,
    out: BoundedSink,
    idle_gap: Duration,
}

impl DedupGuard {
    pub fn new() -> Self {
        Self::with_sink(BoundedSink::stderr(), IDLE_GAP)
    }

    /// DEVLOG-01：同一套折叠 + 上限逻辑，写向一个持久文件而不是 stderr。
    /// 目录不存在就创建；文件以 append 模式打开（多次启动的 daemon 追加
    /// 而不是每次清空——真正的容量上限由 `SINK_CAP_BYTES` truncate 兜底）。
    pub fn for_file(path: &Path) -> io::Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self::with_sink(BoundedSink::file(file), IDLE_GAP))
    }

    fn with_sink(out: BoundedSink, idle_gap: Duration) -> Self {
        Self {
            state: Arc::new(Mutex::new(HashMap::new())),
            out,
            idle_gap,
        }
    }

    #[cfg(test)]
    fn with_idle_gap(idle_gap: Duration) -> Self {
        Self::with_sink(BoundedSink::stderr(), idle_gap)
    }

    #[cfg(test)]
    fn with_idle_gap_file(idle_gap: Duration, file: File) -> Self {
        Self::with_sink(BoundedSink::file(file), idle_gap)
    }

    fn on_line(&self, buf: &[u8]) {
        let key = fold_key(buf).to_vec();
        let now = Instant::now();
        let mut state = self.state.lock().expect("dedup state lock");
        match state.get_mut(&key) {
            Some(entry) => {
                entry.count += 1;
                entry.last_seen = now;
            }
            None => {
                state.insert(
                    key.clone(),
                    KeyState {
                        first_seen: now,
                        last_seen: now,
                        count: 1,
                    },
                );
                drop(state);
                self.out.write_line(buf);
                tokio::spawn(watch_key(
                    Arc::clone(&self.state),
                    self.out.clone(),
                    key,
                    self.idle_gap,
                ));
            }
        }
    }
}

impl Default for DedupGuard {
    fn default() -> Self {
        Self::new()
    }
}

/// 一个 key 从"第一条打印"到"安静下来"期间只有这一个任务在盯着它
/// （由 [`DedupGuard::on_line`] 在插入新 key 时唯一地 spawn 一次）。
async fn watch_key(
    state: Arc<Mutex<HashMap<Vec<u8>, KeyState>>>,
    out: BoundedSink,
    key: Vec<u8>,
    idle_gap: Duration,
) {
    loop {
        tokio::time::sleep(idle_gap).await;
        let mut state_guard = state.lock().expect("dedup state lock");
        let Some(entry) = state_guard.get(&key) else {
            return;
        };
        if Instant::now().duration_since(entry.last_seen) < idle_gap {
            // 这一觉睡着的时候又来了新的——还在活跃期，继续等下一轮。
            continue;
        }
        let count = entry.count;
        let span = entry.last_seen.duration_since(entry.first_seen);
        state_guard.remove(&key);
        drop(state_guard);
        if count > 1 {
            let mut line = key.clone();
            line.extend_from_slice(
                format!(" (折叠 ×{count} over {})\n", human_duration(span)).as_bytes(),
            );
            out.write_line(&line);
        }
        return;
    }
}

pub struct DedupWriter {
    guard: DedupGuard,
}

impl Write for DedupWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.guard.on_line(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        io::stderr().flush()
    }
}

impl<'a> MakeWriter<'a> for DedupGuard {
    type Writer = DedupWriter;

    fn make_writer(&'a self) -> Self::Writer {
        DedupWriter {
            guard: self.clone(),
        }
    }
}

/// DEVLOG-01：`PPF_LOG_FILE` 环境变量启用持久化本地日志文件。纯函数
/// （只读 env，不碰文件系统），main 用它决定要不要调用
/// [`DedupGuard::for_file`]。不设 = 保持原行为，只写 stderr。
pub fn persistent_log_path_from_env() -> Option<PathBuf> {
    std::env::var_os("PPF_LOG_FILE")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fold_key_strips_only_the_leading_timestamp() {
        let line = b"2026-08-27T06:08:38.210828Z  WARN daemon::transport: tls handshake eof\n";
        assert_eq!(
            fold_key(line),
            b" WARN daemon::transport: tls handshake eof"
        );
    }

    #[test]
    fn fold_key_is_stable_across_two_timestamps_same_message() {
        let a = b"2026-08-27T06:08:38.210828Z  WARN x: same message\n";
        let b = b"2026-08-27T06:08:39.999999Z  WARN x: same message\n";
        assert_eq!(fold_key(a), fold_key(b));
    }

    #[tokio::test(start_paused = true)]
    async fn a_single_occurrence_prints_once_and_never_gets_a_summary() {
        let guard = DedupGuard::with_idle_gap(Duration::from_millis(50));
        let written = Arc::clone(&guard.out.written);
        guard.on_line(b"2026-08-27T00:00:00.000000Z  WARN x: one-off\n");
        tokio::time::sleep(Duration::from_millis(200)).await;
        // 只有第一条打印本身，没有多余的折叠汇总。
        let total = *written.lock().expect("counter lock");
        let expected = b"2026-08-27T00:00:00.000000Z  WARN x: one-off\n".len();
        assert_eq!(
            total, expected,
            "single occurrence must not grow past its own line"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_burst_prints_first_line_then_exactly_one_summary() {
        let guard = DedupGuard::with_idle_gap(Duration::from_millis(50));
        let line = b"2026-08-27T00:00:00.000000Z  WARN x: tls handshake eof\n";
        for _ in 0..92211 {
            guard.on_line(line);
            tokio::time::sleep(Duration::from_micros(500)).await;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
        let state = guard.state.lock().expect("state lock");
        assert!(
            state.is_empty(),
            "burst must be flushed and cleared once idle"
        );
        drop(state);
        let total_written = *guard.out.written.lock().expect("counter lock");
        // 首条 + 一条汇总，绝不是 92211 条——这正是本卡要修的洪水。
        assert!(
            total_written < 10 * line.len(),
            "folded burst must not scale with the repeat count, got {total_written} bytes"
        );
    }

    // DEVLOG-01: 文件 sink 走同一套折叠——持久化不是另一套逻辑。
    #[tokio::test(start_paused = true)]
    async fn file_sink_folds_and_persists_across_the_guard() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("daemon-dev.log");
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .unwrap();
        let guard = DedupGuard::with_idle_gap_file(Duration::from_millis(50), file);
        guard.on_line(b"2026-09-16T00:00:00.000000Z  INFO x: hello file\n");
        tokio::time::sleep(Duration::from_millis(200)).await;
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("hello file"), "{content}");
    }

    // DEVLOG-01: 文件 sink 也吃同一个容量上限，不会无界增长。
    #[tokio::test(start_paused = true)]
    async fn file_sink_truncates_past_the_cap() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("daemon-dev.log");
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .unwrap();
        let guard = DedupGuard::with_idle_gap_file(Duration::from_millis(10), file);
        // 每条都不同内容 → 折叠不生效，直接考验容量上限本身。
        // ⚠️ 循环上界必须是固定行数，**不能**写成
        // `while written < SINK_CAP_BYTES`：`write_line` 是在跨过上限*之前*
        // 就 truncate 并把计数器重置成 marker 长度的，那个条件恒真、死循环。
        let big_chunk = "x".repeat(1024 * 1024);
        let rounds = SINK_CAP_BYTES / big_chunk.len() + 2;
        for counter in 0..rounds {
            let line =
                format!("2026-09-16T00:00:00.000000Z  WARN x: filler {counter} {big_chunk}\n");
            guard.on_line(line.as_bytes());
        }
        let written = *guard.out.written.lock().unwrap();
        assert!(
            written < SINK_CAP_BYTES,
            "byte counter must reset after truncation, got {written}"
        );
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(
            content.contains("已截断"),
            "truncation marker must be in the file: {content}"
        );
    }

    // 环境变量读取：不设/空串都视为"不启用"，绝不猜默认路径。
    #[test]
    fn persistent_log_path_from_env_reads_the_env_var() {
        // SAFETY: 测试进程单线程串行跑这一组 env 断言，不与其它测试并发改
        // 同一个变量（cargo test 默认每个 #[test] 一个线程，但同一 crate
        // 内的 env var 是进程级共享状态——这里只在本测试函数内部设置和
        // 清理，不留痕迹给后续测试）。
        unsafe {
            std::env::remove_var("PPF_LOG_FILE");
        }
        assert_eq!(persistent_log_path_from_env(), None);
        unsafe {
            std::env::set_var("PPF_LOG_FILE", "/tmp/ppf-dev.log");
        }
        assert_eq!(
            persistent_log_path_from_env(),
            Some(PathBuf::from("/tmp/ppf-dev.log"))
        );
        unsafe {
            std::env::set_var("PPF_LOG_FILE", "");
        }
        assert_eq!(persistent_log_path_from_env(), None);
        unsafe {
            std::env::remove_var("PPF_LOG_FILE");
        }
    }
}
