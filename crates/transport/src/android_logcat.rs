//! #584: tracing → logcat bridge for the Android process.
//!
//! Rust 侧（transport / iroh / iroh-blobs）的 tracing 事件此前在手机上没有任何
//! 输出目的地：iroh 自己做的 net report、relay 重连、pkarr 发布在 logcat 里一行
//! 都看不到，后台联网无法对账。这里实现一个最小的 `tracing::Subscriber`（不引入
//! tracing-subscriber 依赖，Cargo.lock 不变），把事件写进 logcat，tag 固定
//! [`LOGCAT_TAG`]，默认 INFO；`setprop log.tag.PPassRust DEBUG` 解锁更低级别
//! （鸿蒙同样支持 log.tag.*）。
//!
//! liblog 用 dlopen/dlsym 运行时解析，不做链接期 `#[link(name = "log")]`：
//! `android-jni` feature 会被宿主侧 CI（`cargo nextest run --all-features`）
//! 在 Linux/Windows 上编译并链接测试二进制，链接期依赖会因为没有 liblog 而
//! 直接失败；运行时解析在宿主上只是优雅退化为不写日志。
//!
//! 隐私红线沿用 #544（与桌面端 `crate::QUIET_LOG_DIRECTIVES` 同口径）：iroh 的
//! net_report 在 WARN 级别直接打印本机公网地址，这里在源头压到 ERROR。

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

use jni::objects::{JClass, JString};
use jni::JNIEnv;
use tracing::field::{Field, Visit};
use tracing::level_filters::LevelFilter;
use tracing::span::{Attributes, Id, Record};
use tracing::{Event, Level, Metadata, Subscriber};

/// logcat tag：Kotlin 侧读系统属性 `log.tag.PPassRust` 决定级别。
pub const LOGCAT_TAG: &str = "PPassRust";

/// logcat 单行上限约 4 KB，留余量截断。
const MAX_LINE_BYTES: usize = 3500;

const ANDROID_LOG_VERBOSE: libc::c_int = 2;
const ANDROID_LOG_DEBUG: libc::c_int = 3;
const ANDROID_LOG_INFO: libc::c_int = 4;
const ANDROID_LOG_WARN: libc::c_int = 5;
const ANDROID_LOG_ERROR: libc::c_int = 6;

/// `__android_log_write` 的 ABI（NDK <android/log.h>）。
type LogWrite = unsafe extern "C" fn(
    prio: libc::c_int,
    tag: *const libc::c_char,
    text: *const libc::c_char,
) -> libc::c_int;

/// 运行时解析 liblog（见模块头：不能链接期依赖，否则宿主侧 CI 链接失败）。
/// 只解析一次；宿主（非 Android）上解析失败即退化为不写日志。
fn log_write() -> Option<LogWrite> {
    static RESOLVED: OnceLock<Option<LogWrite>> = OnceLock::new();
    *RESOLVED.get_or_init(|| unsafe {
        let handle = libc::dlopen(c"liblog.so".as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL);
        if handle.is_null() {
            return None;
        }
        let symbol = libc::dlsym(handle, c"__android_log_write".as_ptr());
        if symbol.is_null() {
            None
        } else {
            // SAFETY: dlsym returned liblog's `__android_log_write`, whose ABI
            // matches `LogWrite` (NDK stable C ABI).
            Some(std::mem::transmute::<*mut libc::c_void, LogWrite>(symbol))
        }
    })
}

fn write_log(priority: libc::c_int, text: &str) {
    let Some(write) = log_write() else {
        return;
    };
    static TAG: OnceLock<std::ffi::CString> = OnceLock::new();
    let tag = TAG.get_or_init(|| std::ffi::CString::new(LOGCAT_TAG).expect("tag has no NUL"));
    let Ok(text) = std::ffi::CString::new(text.replace('\0', " ")) else {
        return;
    };
    // SAFETY: both pointers are valid NUL-terminated strings that outlive the call.
    unsafe {
        write(priority, tag.as_ptr(), text.as_ptr());
    }
}

fn priority_of(level: &Level) -> libc::c_int {
    match *level {
        Level::ERROR => ANDROID_LOG_ERROR,
        Level::WARN => ANDROID_LOG_WARN,
        Level::INFO => ANDROID_LOG_INFO,
        Level::DEBUG => ANDROID_LOG_DEBUG,
        Level::TRACE => ANDROID_LOG_VERBOSE,
    }
}

fn parse_level(level: &str) -> LevelFilter {
    match level.trim().to_ascii_uppercase().as_str() {
        "VERBOSE" | "TRACE" => LevelFilter::TRACE,
        "DEBUG" => LevelFilter::DEBUG,
        "WARN" => LevelFilter::WARN,
        "ERROR" => LevelFilter::ERROR,
        "OFF" => LevelFilter::OFF,
        _ => LevelFilter::INFO,
    }
}

/// 最小 Subscriber：不接 span 树，只把每个事件格式化成一行写进 logcat。
/// span 载荷忽略——iroh 的关键事实（relay 状态、net report、pkarr）都在事件里。
struct LogcatSubscriber {
    max: LevelFilter,
    next_span: AtomicU64,
}

impl LogcatSubscriber {
    /// #544：iroh 的 net_report 在 WARN 级别打印本机公网地址，无论全局级别
    /// 如何都压到 ERROR。
    fn cap_for(&self, target: &str) -> LevelFilter {
        if target.starts_with("iroh::net_report") {
            LevelFilter::ERROR
        } else {
            self.max
        }
    }
}

impl Subscriber for LogcatSubscriber {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        *metadata.level() <= self.cap_for(metadata.target())
    }

    fn new_span(&self, _span: &Attributes<'_>) -> Id {
        Id::from_u64(self.next_span.fetch_add(1, Ordering::Relaxed))
    }

    fn record(&self, _span: &Id, _values: &Record<'_>) {}

    fn record_follows_from(&self, _span: &Id, _follows: &Id) {}

    fn event(&self, event: &Event<'_>) {
        let metadata = event.metadata();
        let mut fields = FieldVisitor(String::with_capacity(128));
        event.record(&mut fields);
        let mut line = format!("{}:{}", metadata.target(), fields.0);
        if line.len() > MAX_LINE_BYTES {
            let mut end = MAX_LINE_BYTES;
            while !line.is_char_boundary(end) {
                end -= 1;
            }
            line.truncate(end);
        }
        write_log(priority_of(metadata.level()), &line);
    }

    fn enter(&self, _span: &Id) {}

    fn exit(&self, _span: &Id) {}

    fn max_level_hint(&self) -> Option<LevelFilter> {
        Some(self.max)
    }
}

struct FieldVisitor(String);

impl Visit for FieldVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            let _ = write!(self.0, " {value:?}");
        } else {
            let _ = write!(self.0, " {}={value:?}", field.name());
        }
    }
}

fn install(max: LevelFilter) -> Result<(), tracing::subscriber::SetGlobalDefaultError> {
    tracing::subscriber::set_global_default(LogcatSubscriber {
        max,
        next_span: AtomicU64::new(1),
    })
}

/// #584：每个进程装一次 logcat subscriber。`level` 由 Kotlin 读系统属性
/// `log.tag.PPassRust` 传入；装过就保留第一个（iroh-android 若已装则不抢）。
#[no_mangle]
pub extern "system" fn Java_com_hawkeyexb_ppass_backup_flow_AndroidNativeIrohBlobsProvider_nativeInitLogging(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    level: JString<'_>,
) {
    let level = env
        .get_string(&level)
        .map(String::from)
        .unwrap_or_else(|_| "INFO".to_owned());
    let filter = parse_level(&level);
    match install(filter) {
        Ok(()) => {
            tracing::info!("#584: rust logging installed: tag={LOGCAT_TAG} level={filter}");
        }
        Err(_) => write_log(
            ANDROID_LOG_WARN,
            "#584: a tracing subscriber is already installed; keeping it",
        ),
    }
}
