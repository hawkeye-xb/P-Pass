//! DESK-63 (#946): one owner for the background service's run state.
//!
//! Why this module exists: the frontend used to derive "service is running"
//! from a single `status` call inside `refresh()`. Two separate failures —
//! the first probe after an update (the daemon is still booting), or ANY
//! later call in the same `try` (notably `devices.list`) — flipped that
//! boolean to false, so the overview said "not running" while the service
//! was alive. `online` was doing two jobs: "can I reach the service" and
//! "did this whole data refresh succeed".
//!
//! The state lives here, in the shared desktop shell, because the daemon is
//! a separate process (on Windows it is started by Task Scheduler, not by
//! the shell). The shell cannot read the daemon's memory; its authoritative
//! local fact is the IPC connection itself. The event stream's handshake is
//! the readiness signal: subscribe opened => running, connection ended =>
//! unreachable, user stopped => stopped. The service manager (launchd /
//! Task Scheduler) only answers "should it be running / is it registered";
//! it cannot say "the daemon has finished initialising".
//!
//! `not_configured` and `starting` are first-class states, so the UI can
//! show "starting" instead of a false "not running" during the window
//! between shell start and daemon readiness.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

/// Keep the shell log small; rotate to `desktop.log.1` when it grows past
/// this. The file is diagnostic only, never a data source.
pub(crate) const MAX_LOG_BYTES: u64 = 2 * 1024 * 1024;
/// Do not write the same connection failure every two seconds while the
/// daemon is down — that is 40k identical lines a day. State changes are
/// always logged; repeated failures are throttled.
pub(crate) const FAILURE_LOG_INTERVAL_MS: i64 = 30_000;

/// The desktop shell's view of the background service.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceState {
    /// The first-run wizard has not completed; there is nothing to start yet.
    NotConfigured,
    /// Configured, but the resident service is not registered (or the user
    /// explicitly stopped it). Starting is a user action, not self-heal.
    Stopped,
    /// Configured and expected to run, but the IPC handshake has not
    /// succeeded yet. This is the state the old boolean could not express.
    Starting,
    /// The event stream handshake succeeded; the app can talk to the daemon.
    Running,
    /// Expected to run (not user-stopped), but no connection after the
    /// startup grace, or an established connection was lost.
    Unreachable,
}

impl ServiceState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotConfigured => "not_configured",
            Self::Stopped => "stopped",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Unreachable => "unreachable",
        }
    }

    /// Pure initial-state rule (unit-tested): the user's explicit stop first,
    /// then whether onboarding finished. #1115 起向导第 1 步就会写 config.toml
    /// （库位置由 daemon 写），所以「有 config」不再等于向导走完：走完 = 常驻服务
    /// 已登记（向导第 3 步「完成」才登记）。没登记又不是用户停的 = 向导没走完。
    pub fn initial(configured: bool, installed: bool, user_stopped: bool) -> Self {
        if configured && user_stopped {
            Self::Stopped
        } else if configured && installed {
            Self::Starting
        } else {
            Self::NotConfigured
        }
    }

    /// Pure connection rule (unit-tested). 向导没走完时连上的 daemon 只是向导
    /// 为写库位置临时拉起的一次性进程，不是常驻服务：状态留在 NotConfigured，
    /// 否则「服务在线」会把人踢出向导、它退出后又触发自愈（统一回归首启实测）。
    ///
    /// #1253：「向导走没走完」不能只看壳启动那一刻——那时服务可能还没起来、登记也可能还没落，
    /// 判成 NotConfigured 后就再也不重判，服务后来起来了、报的是「已配置」或「找不到照片库」，
    /// 窗口仍停在向导。所以每次连上都按**此刻**的事实重判一次（[`Self::initial`] 同一张表，
    /// 由调用方算好传进 `onboarded`）：向导真没走完（库位置没写 / 常驻服务没登记）仍留在
    /// NotConfigured，走完了就跟着服务走。
    pub fn after_connection(self, onboarded: bool) -> Self {
        match self {
            Self::NotConfigured if !onboarded => Self::NotConfigured,
            _ => Self::Running,
        }
    }
}

/// 冷启动 daemon 的宽限期：从「这一次启动」开始算，过了还连不上才是事实上的失败。
pub const STARTUP_GRACE: Duration = Duration::from_secs(15);

/// 「这一次启动」：壳启动时，或之后每次显式启动（向导「完成」、启动服务、
/// 重启、自愈）。宽限期和「连上过没有」都只算这一次启动之内的——向导期间
/// 连过的一次性 daemon、上一轮的连接都不算（统一回归：点「完成」后先闪
/// 「不可达」并触发一次自愈，就是宽限期从壳启动算起、且沿用了旧连接）。
#[derive(Debug, Clone, Copy)]
struct StartWindow {
    since: Instant,
    connected: bool,
}

impl StartWindow {
    fn new(now: Instant) -> Self {
        Self {
            since: now,
            connected: false,
        }
    }

    /// `(had_connection, within_grace)`，喂给 [`failure_state`]。
    fn at(self, now: Instant) -> (bool, bool) {
        let within = !self.connected && now.saturating_duration_since(self.since) < STARTUP_GRACE;
        (self.connected, within)
    }
}

/// Pure failure-state rule (unit-tested). `within_grace` only matters before
/// the first successful connection: a daemon that is still booting should
/// read as `starting`, not `unreachable`.
pub fn failure_state(user_stopped: bool, had_connection: bool, within_grace: bool) -> ServiceState {
    if user_stopped {
        ServiceState::Stopped
    } else if !had_connection && within_grace {
        ServiceState::Starting
    } else {
        ServiceState::Unreachable
    }
}

/// Payload of the Tauri `service-state` event. `state` serialises to the
/// snake_case strings above; the frontend renders it directly.
#[derive(Debug, Clone, Serialize)]
pub struct ServiceStateEvent {
    pub state: ServiceState,
    pub reason: Option<String>,
    pub at_ms: i64,
}

struct StateData {
    state: ServiceState,
    since_ms: i64,
    last_failure_ms: Option<i64>,
    last_failure_reason: String,
    start: StartWindow,
}

struct ManagerInner {
    state: Mutex<StateData>,
    log_lock: Mutex<()>,
    started: AtomicBool,
    log_path: PathBuf,
}

/// Cloneable handle stored in Tauri's managed state. All mutating methods
/// take `&AppHandle` so a state change and its event are one operation.
#[derive(Clone)]
pub struct ServiceStateManager {
    inner: Arc<ManagerInner>,
}

impl ServiceStateManager {
    pub fn new(initial: ServiceState, log_path: PathBuf) -> Self {
        Self {
            inner: Arc::new(ManagerInner {
                state: Mutex::new(StateData {
                    state: initial,
                    since_ms: now_ms(),
                    last_failure_ms: None,
                    last_failure_reason: String::new(),
                    start: StartWindow::new(Instant::now()),
                }),
                log_lock: Mutex::new(()),
                started: AtomicBool::new(false),
                log_path,
            }),
        }
    }

    pub fn current(&self) -> ServiceState {
        let guard = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        guard.state
    }

    /// Only one event-stream thread per process. The command is also
    /// registered for older frontends that called it explicitly; setup
    /// already starts it.
    pub fn mark_stream_started(&self) -> bool {
        !self.inner.started.swap(true, Ordering::SeqCst)
    }

    /// The user's explicit stop is the only thing that must never be
    /// overridden by a connection failure.
    pub fn user_stopped(&self) -> bool {
        crate::distribution::ShellHome::current().user_stopped()
    }

    pub fn next_after_failure(&self, had_connection: bool, within_grace: bool) -> ServiceState {
        // A failure cannot invent a "starting" service on a machine that has
        // not finished the wizard, or on one the user stopped / never
        // installed. Those states only leave via an explicit start (or a
        // successful connection, which the caller handles separately).
        match self.current() {
            ServiceState::NotConfigured | ServiceState::Stopped => self.current(),
            _ => failure_state(self.user_stopped(), had_connection, within_grace),
        }
    }

    /// 显式启动（向导「完成」、启动服务、重启、自愈）：置 Starting，并从此刻
    /// 重新给启动宽限期。凡是要进 Starting 的启动动作都走这里，不直接 `set`。
    pub fn begin_start(&self, app: &AppHandle, reason: &str) {
        self.restart_window(Instant::now());
        self.set(app, ServiceState::Starting, Some(reason));
    }

    fn restart_window(&self, now: Instant) {
        let mut guard = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        guard.start = StartWindow::new(now);
    }

    /// 事件流握手成功（含向导期间的一次性 daemon）。
    pub fn note_connected(&self) {
        let mut guard = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        guard.start.connected = true;
    }

    /// 连接失败/断开后该进哪个状态：按「这一次启动」判宽限期。
    pub fn state_after_failure(&self) -> ServiceState {
        let (had_connection, within_grace) = self.start_window_at(Instant::now());
        self.next_after_failure(had_connection, within_grace)
    }

    fn start_window_at(&self, now: Instant) -> (bool, bool) {
        let guard = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        guard.start.at(now)
    }

    /// Record a transition and emit it. No-op when the state is unchanged,
    /// so repeated connection attempts do not spam the UI or the log.
    pub fn set(&self, app: &AppHandle, next: ServiceState, reason: Option<&str>) {
        let previous = {
            let mut guard = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
            if guard.state == next {
                return;
            }
            let previous = guard.state;
            guard.state = next;
            guard.since_ms = now_ms();
            previous
        };
        self.log_state_change(previous, next, reason);
        let _ = app.emit(
            "service-state",
            ServiceStateEvent {
                state: next,
                reason: reason.map(str::to_string),
                at_ms: now_ms(),
            },
        );
    }

    pub fn snapshot(&self) -> Value {
        let guard = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        json!({
            "state": guard.state,
            "since_ms": guard.since_ms,
        })
    }

    /// Data-call failures are not state changes, but they are exactly what
    /// the diagnostic bundle was missing in #946. Throttle identical
    /// connection failures; arbitrary method failures are rare enough to log
    /// every time.
    pub fn note_connection_failure(&self, err: &str) {
        let now = now_ms();
        let should_log = {
            let mut guard = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
            let same = guard.last_failure_reason == err;
            let recent = guard
                .last_failure_ms
                .is_some_and(|at| now.saturating_sub(at) < FAILURE_LOG_INTERVAL_MS);
            if same && recent {
                false
            } else {
                guard.last_failure_ms = Some(now);
                guard.last_failure_reason = err.to_string();
                true
            }
        };
        if should_log {
            self.append_line(&format!(
                "at_ms={now} event=connect_failed err={}",
                one_line(err)
            ));
        }
    }

    pub fn log_call_failure(&self, method: &str, err: &str) {
        self.append_line(&format!(
            "at_ms={} event=call_failed method={} err={}",
            now_ms(),
            one_line(method),
            one_line(err)
        ));
    }

    fn log_state_change(&self, previous: ServiceState, next: ServiceState, reason: Option<&str>) {
        self.append_line(&format!(
            "at_ms={} event=state from={} to={} reason={}",
            now_ms(),
            previous.as_str(),
            next.as_str(),
            one_line(reason.unwrap_or("-"))
        ));
    }

    /// Best-effort append. Logging must never break the UI; every error is
    /// swallowed. Rotation keeps the diagnostic bundle small.
    fn append_line(&self, line: &str) {
        let _guard = self
            .inner
            .log_lock
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let path = &self.inner.log_path;
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if std::fs::metadata(path).is_ok_and(|m| m.len() > MAX_LOG_BYTES) {
            let rotated = path.with_extension("log.1");
            let _ = std::fs::remove_file(&rotated);
            let _ = std::fs::rename(path, &rotated);
        }
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let _ = writeln!(file, "{line}");
        }
    }

    #[cfg(test)]
    fn log_path(&self) -> &Path {
        &self.inner.log_path
    }
}

/// `<data_dir>/logs/desktop.log` — the shell's own log, separate from the
/// daemon's `logs/daemon.log`.
pub fn desktop_log_path(data_dir: &Path) -> PathBuf {
    data_dir.join("logs").join("desktop.log")
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Log lines must stay one line: reasons come from IPC errors and can carry
/// newlines or user paths. The diagnostic bundle scrubs paths separately.
fn one_line(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len().min(600));
    for c in raw.chars() {
        if out.len() >= 600 {
            break;
        }
        out.push(if c == '\n' || c == '\r' { ' ' } else { c });
    }
    if out.is_empty() {
        "-".into()
    } else {
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_state_matrix() {
        assert_eq!(
            ServiceState::initial(false, false, false),
            ServiceState::NotConfigured
        );
        assert_eq!(
            ServiceState::initial(true, false, false),
            ServiceState::NotConfigured,
            "config written by wizard step 1 but autostart not registered = onboarding unfinished"
        );
        assert_eq!(
            ServiceState::initial(true, true, false),
            ServiceState::Starting
        );
        assert_eq!(
            ServiceState::initial(true, true, true),
            ServiceState::Stopped,
            "the user's stop wins over an installed service"
        );
        assert_eq!(
            ServiceState::initial(true, false, true),
            ServiceState::Stopped
        );
    }

    #[test]
    fn failure_state_matrix() {
        assert_eq!(
            failure_state(true, true, true),
            ServiceState::Stopped,
            "user-stopped must never become unreachable"
        );
        assert_eq!(
            failure_state(false, false, true),
            ServiceState::Starting,
            "a daemon that is still booting is starting, not down"
        );
        assert_eq!(
            failure_state(false, false, false),
            ServiceState::Unreachable
        );
        assert_eq!(
            failure_state(false, true, true),
            ServiceState::Unreachable,
            "a lost established connection is unreachable immediately"
        );
    }

    #[test]
    fn state_names_are_stable() {
        assert_eq!(ServiceState::NotConfigured.as_str(), "not_configured");
        assert_eq!(ServiceState::Stopped.as_str(), "stopped");
        assert_eq!(ServiceState::Starting.as_str(), "starting");
        assert_eq!(ServiceState::Running.as_str(), "running");
        assert_eq!(ServiceState::Unreachable.as_str(), "unreachable");
    }

    #[test]
    fn transition_is_logged_as_one_scrubbed_line() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("logs").join("desktop.log");
        let manager = ServiceStateManager::new(ServiceState::Starting, path.clone());
        manager.log_state_change(
            ServiceState::Starting,
            ServiceState::Running,
            Some("event stream\nopen"),
        );
        let text = std::fs::read_to_string(manager.log_path()).unwrap();
        assert_eq!(text.lines().count(), 1, "one transition = one line: {text}");
        assert!(text.contains("from=starting to=running"), "{text}");
        assert!(text.contains("event stream open"), "{text}");
        assert!(!text.contains("event stream\nopen"), "{text}");
    }

    #[test]
    fn identical_failures_are_throttled() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("desktop.log");
        let manager = ServiceStateManager::new(ServiceState::Starting, path.clone());
        manager.note_connection_failure("ipc timeout: status");
        manager.note_connection_failure("ipc timeout: status");
        let text = std::fs::read_to_string(manager.log_path()).unwrap();
        assert_eq!(
            text.lines().count(),
            1,
            "the same failure every 2s must not flood the log: {text}"
        );
        assert!(text.contains("event=connect_failed"), "{text}");
    }

    /// 反证：after_connection 对没走完向导的 NotConfigured 返回 Running → 红（向导被踢出、自愈误拉）。
    #[test]
    fn connection_does_not_finish_onboarding() {
        assert_eq!(
            ServiceState::NotConfigured.after_connection(false),
            ServiceState::NotConfigured
        );
        for s in [
            ServiceState::Stopped,
            ServiceState::Starting,
            ServiceState::Running,
            ServiceState::Unreachable,
        ] {
            for onboarded in [false, true] {
                assert_eq!(s.after_connection(onboarded), ServiceState::Running);
            }
        }
    }

    /// #1253：壳启动时服务还没起来（也没登记）⇒ 判成 NotConfigured、进了向导；之后服务登记好、
    /// 起来了（报「已配置」或「找不到照片库」）——连上时按此刻事实重判，离开向导跟着服务走。
    /// 反证：NotConfigured 无论如何都留着（旧规则）⇒ 红，窗口卡在向导。
    #[test]
    fn a_service_that_comes_up_later_takes_the_window_out_of_the_wizard() {
        assert_eq!(
            ServiceState::NotConfigured.after_connection(true),
            ServiceState::Running
        );
    }

    /// 统一回归：向导期间一次性 daemon 连上过 → 点「完成」显式启动 → 一次性
    /// daemon 退出、常驻服务还在冷启动。宽限期内的失败必须仍是 Starting（不触发
    /// 自愈），宽限期过了才是 Unreachable。
    /// 反证：`restart_window` 不重置（沿用壳启动时的窗口和旧连接）→ 第一条断言红。
    #[test]
    fn explicit_start_restarts_the_grace_window() {
        let tmp = tempfile::tempdir().unwrap();
        let manager =
            ServiceStateManager::new(ServiceState::NotConfigured, tmp.path().join("a.log"));
        manager.note_connected(); // 向导里的一次性 daemon
        let t0 = Instant::now() + Duration::from_secs(60); // 壳早就启动了
        manager.restart_window(t0);
        let (had, within) = manager.start_window_at(t0 + Duration::from_secs(2));
        assert_eq!(
            failure_state(false, had, within),
            ServiceState::Starting,
            "显式启动后宽限期内的失败是「正在启动」，不是不可达"
        );
        let (had, within) = manager.start_window_at(t0 + STARTUP_GRACE + Duration::from_secs(1));
        assert_eq!(failure_state(false, had, within), ServiceState::Unreachable);

        // 这一次启动之内连上过、又断了 = 立刻不可达（原语义不变）。
        manager.note_connected();
        let (had, within) = manager.start_window_at(t0 + Duration::from_secs(3));
        assert_eq!(failure_state(false, had, within), ServiceState::Unreachable);
    }

    /// 所有进 Starting 的启动动作都必须走 `begin_start`（重新计宽限期）。
    /// 反证：把任一处改回 `manager.set(.., ServiceState::Starting, ..)` → 红。
    #[test]
    fn every_start_goes_through_begin_start() {
        let lib = include_str!("lib.rs");
        assert!(
            !lib.contains("ServiceState::Starting, Some("),
            "lib.rs 里有绕过 begin_start 直接置 Starting 的地方"
        );
        assert!(
            lib.matches(".begin_start(").count() >= 3,
            "user start / self-heal / restart"
        );
    }

    #[test]
    fn failure_never_invents_a_starting_service() {
        let tmp = tempfile::tempdir().unwrap();
        let unconfigured =
            ServiceStateManager::new(ServiceState::NotConfigured, tmp.path().join("a.log"));
        assert_eq!(
            unconfigured.next_after_failure(false, true),
            ServiceState::NotConfigured
        );
        assert_eq!(
            unconfigured.next_after_failure(false, false),
            ServiceState::NotConfigured
        );

        let stopped = ServiceStateManager::new(ServiceState::Stopped, tmp.path().join("b.log"));
        assert_eq!(
            stopped.next_after_failure(false, true),
            ServiceState::Stopped,
            "a stopped service must not become starting just because a probe failed"
        );
    }

    #[test]
    fn event_stream_start_is_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let manager =
            ServiceStateManager::new(ServiceState::Starting, tmp.path().join("desktop.log"));
        assert!(manager.mark_stream_started());
        assert!(!manager.mark_stream_started());
    }
}
