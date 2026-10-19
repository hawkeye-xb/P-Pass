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
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

/// Keep the shell log small; rotate to `desktop.log.1` when it grows past
/// this. The file is diagnostic only, never a data source.
const MAX_LOG_BYTES: u64 = 2 * 1024 * 1024;
/// Do not write the same connection failure every two seconds while the
/// daemon is down — that is 40k identical lines a day. State changes are
/// always logged; repeated failures are throttled.
const FAILURE_LOG_INTERVAL_MS: i64 = 30_000;

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

    /// Pure initial-state rule (unit-tested): configuration first, then the
    /// user's explicit stop, then whether the resident service is registered.
    pub fn initial(configured: bool, installed: bool, user_stopped: bool) -> Self {
        if !configured {
            Self::NotConfigured
        } else if user_stopped {
            Self::Stopped
        } else if installed {
            Self::Starting
        } else {
            Self::Stopped
        }
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
        use platform::PlatformAdapter as _;
        crate::is_user_stopped(&platform::adapter().data_dir())
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
            ServiceState::Stopped
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
