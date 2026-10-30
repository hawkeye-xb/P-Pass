//! macOS adapter (§4 对照表右列).
//!
//! - Autostart: LaunchAgent plist (`RunAtLoad` + `KeepAlive` — crash
//!   restart comes free) + `launchctl bootstrap/bootout`.
//! - Awake: a `caffeinate -i` child process held RAII-style — zero FFI,
//!   visible in `pmset -g assertions` (the smoke check). IOKit
//!   assertions are the Phase-2 upgrade, interface unchanged.
//! - Power hint: `pmset -g custom` through the shared pure parser.

// DESK-33 (#325)：clippy.toml 禁止直接 `Command::new`，那条约束只为 Windows
// 的「GUI 进程拉起 console 程序会闪黑窗」而设。本文件只在 macOS 上编译，
// 没有这个问题，整文件放行；Windows 代码请走 `crate::command`。
#![allow(clippy::disallowed_methods)]

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{
    AutostartRegistration, AwakeGuard, HostingAdapter, PlatformAdapter, PlatformError, PowerHint,
    Result, ServiceMode,
};

const AGENT_LABEL: &str = "com.hawkeyexb.ppass.desktop.daemon";

pub struct MacosAdapter;

impl MacosAdapter {
    pub fn new() -> Self {
        Self
    }

    fn agent_plist_path() -> PathBuf {
        home().join(format!("Library/LaunchAgents/{AGENT_LABEL}.plist"))
    }
}

/// DAE-02: LaunchAgent plist 文本（纯函数——测试断言 KeepAlive 语义）。
///
/// KeepAlive 不是无条件 `<true/>`：主动退位（stand_down / step_down 都
/// 是 exit(0)）后 launchd 若照旧每 ~10s 重拉，退位实例会被自己的旧
/// plist 无限复活，永久空转 churn（验收人实锤：升级接管场景必现）。
/// `SuccessfulExit=false` 的语义 = 成功退出不重拉；崩溃/被杀（非零退出
/// 或信号）照样复活——pkill 复活验收不回归。
pub(crate) fn agent_plist(exec: &Path, logs: &crate::DaemonLogPaths) -> String {
    let path = |p: &Option<PathBuf>| {
        p.as_deref()
            .map(|p| p.display().to_string())
            .unwrap_or_default()
    };
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>{AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>{}</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>StandardOutPath</key><string>{}</string>
    <key>StandardErrorPath</key><string>{}</string>
</dict>
</plist>
"#,
        exec.display(),
        path(&logs.stdout),
        path(&logs.stderr),
    )
}

/// daemon 日志的全部落点（[`MacosAdapter::daemon_log_paths`] 与 LaunchAgent plist
/// 共用这一份）。#1046：launchd 接的 stdout/stderr 也落在 daemon 自己的
/// `<data_dir>/logs/` 里（`daemon.out` / `daemon.err`，与 Windows 的 `daemon.err`
/// 同名），由 daemon 管容量（`log_guard`），诊断包只读这个目录就收得全。
/// `daemon.log` 是 daemon 自己 append 的运行日志，launchd 不能也写它。
pub(crate) fn daemon_log_paths_in(data_dir: &Path) -> crate::DaemonLogPaths {
    let logs = data_dir.join("logs");
    crate::DaemonLogPaths {
        log_file: Some(logs.join("daemon.log")),
        stdout: Some(logs.join("daemon.out")),
        stderr: Some(logs.join("daemon.err")),
        stdio_by_service_manager: true,
    }
}

/// launchd 拉起的 daemon 用的是平台默认数据目录（plist 不带 `PPF_DATA_DIR`），
/// 所以登记里的日志落点按它算。
fn agent_log_paths() -> crate::DaemonLogPaths {
    daemon_log_paths_in(&MacosAdapter.data_dir())
}

/// #1046：已登记的 plist 是不是本版本 [`agent_plist`] 会写出的那一份（逐字比较）。
/// 老版本的 plist（日志落点在 `~/Library/Logs`）判为不是 ⇒ 对账重写。
pub(crate) fn plist_is_current(text: &str, exec: &Path, logs: &crate::DaemonLogPaths) -> bool {
    text == agent_plist(exec, logs)
}

/// 【DESK-42 #604】从（我们自己生成的）plist 文本里取出 `ProgramArguments`
/// 数组的第一项。纯函数，单测覆盖——真机上正是靠它发现登记被钉在备份目录。
///
/// 只认我们自己写出的那一种形状（`<array><string>…</string></array>`）：
/// 这个文件由同一份代码生成、形状可控，不为它引入 XML 依赖。
pub(crate) fn plist_program_argument(text: &str) -> Option<String> {
    let after_key = text.split("<key>ProgramArguments</key>").nth(1)?;
    let after_array = after_key.split("<array>").nth(1)?;
    let after_open = after_array.split("<string>").nth(1)?;
    let value = after_open.split("</string>").next()?.trim();
    (!value.is_empty()).then(|| value.to_string())
}

/// 【DESK-42 #604】对账闸门判据：这个可执行文件是不是在**稳定安装位置**。
///
/// 允许：`/Applications/…`、`~/Applications/…`（用户级安装）。
/// 拒绝：其余一切——dmg 挂载点 `/Volumes/…`、「下载」目录、备份目录、
/// `/private/var/folders/…/AppTranslocation/…` 随机路径、开发构建路径。
///
/// 保守方向是刻意的：**漏判的代价**是「本可自愈的旧登记没被修」（下次开机还是旧服务，
/// 用户看得见、可再修）；**误判的代价**是把登记改到一次性路径上（用户下次开机服务
/// 静默起不来，且没有任何提示）。后者严重得多，所以只放行确定稳定的两个位置。
pub(crate) fn is_stable_install_location(exec: &Path) -> bool {
    let s = exec.to_string_lossy();
    // macOS App Translocation：带 quarantine 的 App 可能跑在随机只读路径下，
    // 该路径随进程消失——即使它的外层看起来像 /Applications 也不许写。
    if s.contains("/AppTranslocation/") {
        return false;
    }
    s.starts_with("/Applications/") || s.starts_with(&format!("{}/Applications/", home().display()))
}

/// UPD-06 (#616)：**桌面壳**的 LaunchAgent 标签。
///
/// 与 daemon 那条（`AGENT_LABEL`）刻意分开：壳的这一条**只管启动、不管守卫**，
/// 存在的唯一目的是让 `kickstart -k` 有东西可控——由系统杀掉旧壳、按磁盘上
/// 已是新版本的同一个文件重新拉起来。
const SHELL_AGENT_LABEL: &str = "com.hawkeyexb.ppass.desktop.shell";

fn shell_agent_plist_path() -> PathBuf {
    home().join(format!("Library/LaunchAgents/{SHELL_AGENT_LABEL}.plist"))
}

/// 当前用户的 uid（`launchctl` 的 `gui/<uid>` 域）。
fn current_uid() -> Result<String> {
    let out = Command::new("id")
        .arg("-u")
        .output()
        .map_err(io_err("id -u"))?;
    let uid = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if uid.is_empty() {
        return Err(PlatformError::Failed {
            action: "id -u",
            detail: "读不出 uid".into(),
        });
    }
    Ok(uid)
}

/// 壳的 LaunchAgent 文本（纯函数——测试断言"登记 ≠ 守卫"）。
///
/// ⚠️ **不许出现 `KeepAlive`**：那是 daemon 的语义（崩溃/被杀复活）。壳挂上它
/// 就等于**用户再也退不掉 App**——托盘「退出 App」会被 launchd 立刻复活。
///
/// `RunAtLoad=true`（2026-10-02 验收人拍板）：壳是**登录项**——开机/登录后自己起来
/// 常驻托盘。这么定的理由（第一性原理）：让"启动壳"归系统的服务管理器管，而不是
/// 让进程自己换自己（后者要在被替换的进程里自证无竞态，且 `kickstart -k` 只能杀
/// 服务管理器启动的进程——用户手动打开的壳它杀不动）。没有 `KeepAlive` ⇒ 用户
/// 仍然可以完全退出，只是下次登录会再起来；macOS 13+ 也会在「登录项」里显示它、
/// 允许用户自己关掉。
///
/// 日志落到 `~/Library/Logs`：由 launchd 拉起的壳看不到终端，出问题时只能靠
/// 这两个文件（"launchd 拉起的 GUI 观感是否正常"这条风险就是靠它们取证）。
pub(crate) fn shell_agent_plist(exec: &Path) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>{SHELL_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>{}</string></array>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>{}/Library/Logs/p-pass-shell.log</string>
    <key>StandardErrorPath</key><string>{}/Library/Logs/p-pass-shell.err</string>
</dict>
</plist>
"#,
        exec.display(),
        home().display(),
        home().display(),
    )
}

/// 从 `launchctl print gui/<uid>/<label>` 的输出里取**正在跑的那个实例的 pid**。
///
/// 真机输出形状（2026-10-02 在本机 `ai.hermes.gateway` 上取的样本，行首是**制表符**，
/// 下面示例里画成四个空格）：
/// ```text
/// gui/501/ai.hermes.gateway = {
///     active count = 1
///     state = running
///     ...
///     pid = 992
/// ```
/// 没在跑时 launchd 打的是 `state = not running` **且不打 `pid =` 这一行**
/// ⇒ 因此"取不到 pid"与"没在跑"是同一件事，`None` 就够了。
///
/// 纯函数：单测直接喂真机形状的样本，不依赖本机有没有装 P-Pass。
pub(crate) fn launchd_job_pid(text: &str) -> Option<u32> {
    text.lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix("pid = "))
        .and_then(|v| v.trim().parse::<u32>().ok())
}

/// `launchctl kickstart -p` 的 stdout 是新实例的 pid（真机样本：`35736\n`）。
/// 取最后一个空白分隔的 token；读不出 = `None`（调用方再用 `print` 兜一次）。
pub(crate) fn kickstart_reported_pid(stdout: &str) -> Option<u32> {
    stdout.split_whitespace().last()?.parse::<u32>().ok()
}

/// 从可执行文件路径推出它所属的 `.app`。
///
/// `…/P-Pass.app/Contents/MacOS/p-pass-desktop` → `…/P-Pass.app`。
/// 纯函数、无 IO：形状不对（不是 `.app/Contents/MacOS/x`）一律 `None`——
/// 调用方按"不知道"处理，绝不当成"版本不一致"。
pub(crate) fn bundle_root(exec: &Path) -> Option<PathBuf> {
    let macos_dir = exec.parent()?;
    if macos_dir.file_name()? != "MacOS" {
        return None;
    }
    let contents = macos_dir.parent()?;
    if contents.file_name()? != "Contents" {
        return None;
    }
    let bundle = contents.parent()?;
    if bundle.extension()? != "app" {
        return None;
    }
    Some(bundle.to_path_buf())
}

/// #1110：内置 daemon 的 helper App 目录名，位于 `P-Pass.app/Contents/Helpers/`。
///
/// daemon 要读写 data protection 钥匙串，必须带 `keychain-access-groups` 权限并由
/// 嵌入的 provisioning profile 授权；裸可执行文件没有地方放授权文件，所以组装成
/// 独立的 `.app`（bundle id `com.hawkeyexb.ppass.desktop.daemon`）。组装与签名在
/// `tools/bundle-desktop-macos.sh` / `tools/daemon-helper-macos.sh`。
pub(crate) const DAEMON_HELPER_BUNDLE: &str = "ppf-daemon.app";

/// 壳可执行文件 → 内置 daemon 可执行文件（纯函数、无 IO）。
///
/// `…/P-Pass.app/Contents/MacOS/p-pass-desktop`
/// → `…/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon`。
///
/// 只有这一条相对规则，开发构建也一样：`tauri dev` 的壳在
/// `src-tauri/target/debug/p-pass-desktop`，对应 `src-tauri/target/Helpers/…`，
/// 本地开发签名脚本就把 helper 放在那里。
pub(crate) fn bundled_daemon_path_from(shell_exe: &Path) -> Option<PathBuf> {
    let contents = shell_exe.parent()?.parent()?;
    Some(
        contents
            .join("Helpers")
            .join(DAEMON_HELPER_BUNDLE)
            .join("Contents/MacOS")
            .join(crate::DAEMON_EXECUTABLE_STEM),
    )
}

impl Default for MacosAdapter {
    fn default() -> Self {
        Self::new()
    }
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()))
}

/// 【#726】把读登记文件的结果归成三种状态（纯函数，单测钉死）。
///
/// 读不出（空文件 / 写了一半 / 被改坏）必须是 `Unreadable` 而不是 `Absent`：
/// 当成「没登记」⇒ 对账不动它 ⇒ 每次开机 launchd 都加载失败，服务起不来也不会自己好。
pub(crate) fn registration_from_read(
    read: std::io::Result<String>,
) -> Result<AutostartRegistration> {
    match read {
        Ok(text) => Ok(match plist_program_argument(&text) {
            Some(p) => AutostartRegistration::At(PathBuf::from(p)),
            None => AutostartRegistration::Unreadable,
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(AutostartRegistration::Absent),
        Err(e) => Err(PlatformError::Io {
            action: "read LaunchAgent plist",
            source: e,
        }),
    }
}

/// 【#726】登记文件原子写入：先写同目录的临时文件并落盘，再一步改名换过去。
///
/// 直接 `fs::write` 写到一半断电 / 被杀 ⇒ 留下半个 plist ⇒ 开机加载失败。
/// 改名在同一卷上是原子的：中途出事只会留下旧的完整文件。写失败时删掉临时文件；
/// 进程被杀留下的临时文件，下次写入时被 `File::create` 截断覆盖。
pub(crate) fn write_atomic(path: &Path, contents: &str) -> std::io::Result<()> {
    use std::io::Write as _;
    let name = path
        .file_name()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "no file name"))?;
    let tmp = path.with_file_name(format!(".{}.tmp", name.to_string_lossy()));
    let result = (|| {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(contents.as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

fn io_err(action: &'static str) -> impl Fn(std::io::Error) -> PlatformError {
    move |source| PlatformError::Io { action, source }
}

/// #1043（B6）：NSLocale 的首选语言——`[NSLocale preferredLanguages]` 的
/// CoreFoundation 对等物（toll-free bridged）。直接链系统框架、裸 FFI，不为
/// 这一次调用引入 objc/core-foundation crate。
mod cf_locale {
    use std::ffi::{c_char, c_void};

    type CFIndex = isize;
    type CFTypeRef = *const c_void;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFLocaleCopyPreferredLanguages() -> CFTypeRef;
        fn CFArrayGetCount(array: CFTypeRef) -> CFIndex;
        fn CFArrayGetValueAtIndex(array: CFTypeRef, idx: CFIndex) -> CFTypeRef;
        fn CFStringGetCString(
            s: CFTypeRef,
            buffer: *mut c_char,
            size: CFIndex,
            encoding: u32,
        ) -> u8;
        fn CFRelease(cf: CFTypeRef);
    }

    /// 首选语言列表的第一项（如 `zh-Hans-CN`、`en-US`）；读不到 = `None`。
    pub(super) fn first_preferred_language() -> Option<String> {
        // SAFETY: Copy 规则——返回的数组归我们，函数末尾 CFRelease 一次；数组
        // 元素是 Get 规则（不持有），只在数组存活期间读。缓冲区在本栈上，
        // 长度如实传入，CFStringGetCString 保证 NUL 结尾。
        unsafe {
            let langs = CFLocaleCopyPreferredLanguages();
            if langs.is_null() {
                return None;
            }
            let mut out = None;
            if CFArrayGetCount(langs) > 0 {
                let first = CFArrayGetValueAtIndex(langs, 0);
                let mut buf = [0 as c_char; 128];
                if !first.is_null()
                    && CFStringGetCString(
                        first,
                        buf.as_mut_ptr(),
                        buf.len() as CFIndex,
                        K_CF_STRING_ENCODING_UTF8,
                    ) != 0
                {
                    out = std::ffi::CStr::from_ptr(buf.as_ptr())
                        .to_str()
                        .ok()
                        .map(str::to_owned);
                }
            }
            CFRelease(langs);
            out.filter(|t| !t.is_empty())
        }
    }
}

/// #1118：「系统设置 → 通用 → 关于本机 → 名称」——SystemConfiguration 的电脑名称。
mod sc_name {
    use std::ffi::{c_char, c_void};

    type CFIndex = isize;
    type CFTypeRef = *const c_void;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "SystemConfiguration", kind = "framework")]
    extern "C" {
        fn SCDynamicStoreCopyComputerName(store: CFTypeRef, encoding: *mut u32) -> CFTypeRef;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFStringGetCString(
            s: CFTypeRef,
            buffer: *mut c_char,
            size: CFIndex,
            encoding: u32,
        ) -> u8;
        fn CFRelease(cf: CFTypeRef);
    }

    pub(super) fn computer_name() -> Option<String> {
        // SAFETY: Copy 规则——返回的字符串归我们，读完 CFRelease 一次；store 传空 =
        // 临时会话，encoding 传空 = 不要。缓冲区在本栈上，长度如实传入，
        // CFStringGetCString 成功时保证 NUL 结尾（名字最长 63 个字符，UTF-8 不超过 256 字节）。
        unsafe {
            let name = SCDynamicStoreCopyComputerName(std::ptr::null(), std::ptr::null_mut());
            if name.is_null() {
                return None;
            }
            let mut buf = [0 as c_char; 512];
            let ok = CFStringGetCString(
                name,
                buf.as_mut_ptr(),
                buf.len() as CFIndex,
                K_CF_STRING_ENCODING_UTF8,
            ) != 0;
            CFRelease(name);
            if !ok {
                return None;
            }
            let s = std::ffi::CStr::from_ptr(buf.as_ptr()).to_str().ok()?;
            crate::clean_computer_name(s)
        }
    }
}

impl PlatformAdapter for MacosAdapter {
    fn redaction_safe_file_names(&self) -> Vec<String> {
        vec![format!("{AGENT_LABEL}.plist")]
    }

    fn computer_name(&self) -> Option<String> {
        sc_name::computer_name()
    }

    fn assert_awake(&self) -> Result<AwakeGuard> {
        let child = Command::new("caffeinate")
            .arg("-i") // prevent idle sleep while we run
            .spawn()
            .map_err(io_err("spawn caffeinate"))?;
        Ok(AwakeGuard {
            inner: CaffeinateGuard { child },
        })
    }

    fn power_hint(&self) -> PowerHint {
        match Command::new("pmset").args(["-g", "custom"]).output() {
            Ok(out) if out.status.success() => {
                crate::parse_pmset(&String::from_utf8_lossy(&out.stdout))
            }
            _ => PowerHint::Unknown,
        }
    }

    fn watch_library_root(&self, root: &Path, on_gone: Box<dyn FnOnce() + Send>) -> bool {
        match watch_vnode_gone(root) {
            Ok(wait) => std::thread::Builder::new()
                .name("ppf-library-root".into())
                .spawn(move || {
                    if wait() {
                        on_gone();
                    }
                })
                .is_ok(),
            // 打不开 / 登记不上：如实回答「没有这项能力」，由调用方记日志。
            Err(_) => false,
        }
    }

    fn approve_library_unmount(&self, root: &Path, prepare: Box<dyn Fn() + Send + Sync>) -> bool {
        crate::macos_unmount::watch(root, prepare)
    }

    fn notify(&self, title: &str, body: &str) {
        // Reliable notifications need a notarized .app (T-041/T-071);
        // best-effort osascript until then.
        let script = format!(
            "display notification \"{}\" with title \"{}\"",
            body.replace('"', "'"),
            title.replace('"', "'")
        );
        let _ = Command::new("osascript").args(["-e", &script]).output();
    }

    fn data_dir(&self) -> PathBuf {
        home().join("Library/Application Support/P-Pass")
    }

    /// #1043（B6）：NSLocale 首选语言（系统设置 → 通用 → 语言与地区的第一项）。
    /// 不读 `LANG`：从访达 / launchd 启动的 GUI 进程通常没有它。
    fn system_locale(&self) -> Option<String> {
        cf_locale::first_preferred_language()
    }

    /// launchd 接 stdio（与 [`agent_plist`] 同一份路径，#1046 起在
    /// `<data_dir>/logs/` 里）；运行日志是 `<data_dir>/logs/daemon.log`。
    fn daemon_log_paths(&self, data_dir: &Path) -> crate::DaemonLogPaths {
        daemon_log_paths_in(data_dir)
    }

    fn default_log_tees_stderr(&self) -> bool {
        true
    }

    /// DESK-22 (#211/#171)：原先长在桌面壳 `lib.rs` 的 `#[cfg(target_os =
    /// "macos")]` 分支里，这次随 Windows 侧实现一起迁进来。**行为一字未改。**
    ///
    /// 用系统原生的管理员授权弹窗（不是终端，是"输入密码 / Touch ID"那种）
    /// 直接帮用户改。`-a`（电池 + 电源两种场景）而非只 `-c`（仅电源）——跟
    /// `parse_pmset` 的检测口径一致（取所有场景里最小的正数 sleep 值），
    /// 只改 AC 的话笔记本用电池时检测仍报"还会睡眠"，勾不上 ✓。
    fn disable_auto_sleep(&self) -> Result<crate::Applied> {
        let out = Command::new("osascript")
            .args([
                "-e",
                "do shell script \"pmset -a sleep 0\" with administrator privileges",
            ])
            .output()
            .map_err(io_err("disable_auto_sleep"))?;
        if out.status.success() {
            return Ok(crate::Applied::Done);
        }
        let stderr = String::from_utf8_lossy(&out.stderr);
        // osascript 用 -128 表示"用户取消"；文案随语言变，两个都认。
        if stderr.contains("User canceled") || stderr.contains("-128") {
            return Err(PlatformError::Cancelled {
                action: "disable_auto_sleep",
            });
        }
        Err(PlatformError::Failed {
            action: "disable_auto_sleep",
            detail: stderr.trim().to_string(),
        })
    }

    // QA-09 迁移（#211）：以下四个能力 macOS 与 Linux 完全一致，实现只此
    // 一份，在 crates/platform/src/unix.rs。
    //
    // ⚠️ volume_stats 在此之前 macOS 侧是**没有**实现的（吃 trait 默认的
    // None），DAE-05 的数字靠 daemon 自己那段 `#[cfg(unix)]` statvfs 供。
    // 迁移把那段搬了过来，所以这里必须接上，否则 macOS 的磁盘水位会从
    // 「有数字」退回「null」——那是迁移改了行为，不允许。
    fn volume_stats(&self, path: &Path) -> Option<crate::VolumeStats> {
        crate::unix::volume_stats(path)
    }
    fn restrict_to_owner(&self, path: &Path) -> Result<crate::Applied> {
        crate::unix::restrict_to_owner(path)
    }
    fn grant_library_dir(&self, dir: &Path) -> Result<crate::LibraryDirGrant> {
        make_library_dir_private(dir)
    }
    fn identity_key_home(&self) -> crate::IdentityKeyHome {
        crate::IdentityKeyHome::SecureStore(Box::new(crate::keychain::KeychainIdentityStore::new()))
    }
    fn resident_ipc(&self) -> crate::ResidentIpc {
        crate::ResidentIpc::SignedSocket(self.data_dir().join("run").join("daemon.sock"))
    }
    fn prepare_private_dir(&self, path: &Path) -> Result<()> {
        crate::unix::prepare_private_dir(path)
    }
    fn library_store(&self) -> Option<Box<dyn crate::SecretBlobStore>> {
        Some(Box::new(crate::keychain::KeychainBlobStore::library()))
    }
    fn pairing_store(&self) -> Option<Box<dyn crate::SecretBlobStore>> {
        Some(Box::new(crate::keychain::KeychainBlobStore::pairings()))
    }
    fn truncate_own_stderr(&self) -> crate::Applied {
        crate::unix::truncate_own_stderr()
    }
    fn remove_stale_ipc_endpoint(&self, name: &str) -> crate::Applied {
        crate::unix::remove_stale_ipc_endpoint(name)
    }

    // ── QA-09 迁移（#211）桌面壳批次 ───────────────────────────────
    fn platform_name(&self) -> &'static str {
        "macos"
    }

    /// 「电池」设置面板。迁移前桌面壳直接 `open` 这个 URI；现在只给 URI，
    /// 打开动作由桌面壳的 opener 插件负责（理由见 trait 上的说明）。
    fn power_settings_uri(&self) -> Option<&'static str> {
        Some("x-apple.systempreferences:com.apple.Battery-Settings.extension")
    }

    /// macOS 的模板图标：单色、随系统深浅色自动反色。
    fn tray_icon_is_template(&self) -> bool {
        true
    }

    /// macOS 上托盘左键出菜单是系统习惯；Windows / Linux 左键开窗口
    /// （DESK-18 / #167）。
    /// 点红灯不退出是 macOS 常态，不用解释（#303 验收标准 3）。
    fn close_to_tray_hint(&self) -> bool {
        false
    }

    /// `titleBarStyle: "Overlay"` 只在 macOS 生效。
    fn overlay_titlebar(&self) -> bool {
        true
    }

    /// 向导第 2 步请用户关掉空闲自动睡眠（`power_hint` / `disable_auto_sleep`）。
    fn sleep_owner(&self) -> Option<crate::SleepOwner> {
        Some(crate::SleepOwner::User)
    }

    fn tray_shows_menu_on_left_click(&self) -> bool {
        true
    }
}

impl HostingAdapter for MacosAdapter {
    /// 【DESK-42 #604】对账闸门：**只有稳定安装位置**里的 App 才允许改写开机自启登记。
    ///
    /// 真机风险（外部评审 2026-10-01 在 PR #611 上拦停）：Mac 用户从「下载」目录直接
    /// 打开 dmg 里的 App 是极常见操作，macOS 还会对带 quarantine 的 App 做 App
    /// Translocation（跑在 `/private/var/folders/…/AppTranslocation/…` 随机路径）——
    /// 这些都是一次性路径。若此时改登记，用户下次开机就被指向一个已消失的可执行文件，
    /// **服务静默起不来，且没有任何提示**。原缺陷要用户手点「启动后台服务」才写错，
    /// 「每次启动静默对账」不判位置的话危险面更大。
    fn autostart_reconcile_allowed(&self, expected: &Path) -> bool {
        is_stable_install_location(expected)
    }

    fn install_autostart(&self, exec: &Path) -> Result<()> {
        // DAE-01 稳定路径纪律：plist 绝不指向 target/ 开发路径或 /tmp/——
        // 指向那里的 launchd 条目会把旧构建永远钉在岗上（用户机实锤：
        // launchd 至今指向 7/31 开发构建路径）。非法路径直接拒绝，不写。
        let exec_str = exec.display().to_string();
        if exec_str.contains("/target/") || exec_str.contains("/tmp/") {
            return Err(PlatformError::Failed {
                action: "install_autostart rejects unstable path",
                detail: exec_str,
            });
        }
        let logs = agent_log_paths();
        let plist = agent_plist(exec, &logs);
        let path = Self::agent_plist_path();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(io_err("create LaunchAgents dir"))?;
        }
        // #1046：launchd 只打开 StandardOutPath/StandardErrorPath，不建父目录——
        // 日志目录不在（首启、数据目录刚搬过）时先建好，否则 stdio 接不上。
        for p in [&logs.stdout, &logs.stderr].into_iter().flatten() {
            if let Some(dir) = p.parent() {
                std::fs::create_dir_all(dir).map_err(io_err("create daemon logs dir"))?;
            }
        }
        write_atomic(&path, &plist).map_err(io_err("write LaunchAgent plist"))?;
        // Load now (idempotent-ish: bootout first, ignore its failure).
        let uid = Command::new("id")
            .arg("-u")
            .output()
            .map_err(io_err("id -u"))?;
        let uid = String::from_utf8_lossy(&uid.stdout).trim().to_string();
        let _ = Command::new("launchctl")
            .args(["bootout", &format!("gui/{uid}/{AGENT_LABEL}")])
            .output();
        let out = Command::new("launchctl")
            .args(["bootstrap", &format!("gui/{uid}")])
            .arg(&path)
            .output()
            .map_err(io_err("launchctl bootstrap"))?;
        if !out.status.success() {
            return Err(PlatformError::Failed {
                action: "launchctl bootstrap",
                detail: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        Ok(())
    }

    fn autostart_installed(&self) -> Result<bool> {
        Ok(Self::agent_plist_path().exists())
    }

    /// 【#726】文件不存在 = 没登记；读得到但解析不出路径 = 损坏，由对账重写。
    fn autostart_registration(&self) -> Result<AutostartRegistration> {
        registration_from_read(std::fs::read_to_string(Self::agent_plist_path()))
    }

    /// #1046：plist 全文与本版本会写出的一致（日志落点等），才算「登记是新的」。
    fn autostart_registration_current(&self, expected: &Path) -> Result<bool> {
        let text = std::fs::read_to_string(Self::agent_plist_path())
            .map_err(io_err("read LaunchAgent plist"))?;
        Ok(plist_is_current(&text, expected, &agent_log_paths()))
    }

    fn uninstall_autostart(&self) -> Result<()> {
        let uid = Command::new("id")
            .arg("-u")
            .output()
            .map_err(io_err("id -u"))?;
        let uid = String::from_utf8_lossy(&uid.stdout).trim().to_string();
        let _ = Command::new("launchctl")
            .args(["bootout", &format!("gui/{uid}/{AGENT_LABEL}")])
            .output();
        let path = Self::agent_plist_path();
        if path.exists() {
            std::fs::remove_file(&path).map_err(io_err("remove LaunchAgent plist"))?;
        }
        Ok(())
    }

    fn service_mode(&self) -> ServiceMode {
        ServiceMode::LaunchAgent
    }

    fn stop_daemon(&self, exe: &Path, pid_hint: Option<u32>) -> Result<crate::KillOutcome> {
        crate::unix::stop_processes_at(exe, pid_hint)
    }

    /// #1110：daemon 是嵌套 helper App，见 [`bundled_daemon_path_from`]。
    fn bundled_daemon_path(&self, shell_exe: &Path) -> Option<PathBuf> {
        bundled_daemon_path_from(shell_exe)
    }

    // ── UPD-06 (#616)：壳的"按需启动"登记 + kickstart ─────────────────

    fn shell_agent_label(&self) -> Option<&'static str> {
        Some(SHELL_AGENT_LABEL)
    }

    /// launchd 拉起的进程会被设上 `XPC_SERVICE_NAME`（= job 的 Label）；从访达/
    /// Dock 打开的不带这个值 ⇒ 只能走壳自己重启（见 trait 注释里的推演）。
    fn shell_agent_started_us(&self) -> bool {
        std::env::var("XPC_SERVICE_NAME")
            .map(|v| v == SHELL_AGENT_LABEL)
            .unwrap_or(false)
    }

    /// 幂等写登录项（**只写文件，不 bootstrap**）。
    ///
    /// 为什么不在登记时顺手 `bootstrap`：`RunAtLoad=true` 的 job 一旦被 bootstrap，
    /// launchd 会**立刻**再拉起一个实例，而壳装了 single-instance ⇒ 新实例把焦点
    /// 交回当前这把壳后自杀（一次无意义的起停，还可能闪一下）。所以这里只写文件：
    /// 登录时 launchd 自己会加载 `~/Library/LaunchAgents` 下的 plist 并按
    /// `RunAtLoad` 启动。于是"这把壳归 launchd 管"从**下一次登录**起成立，
    /// `kickstart` 也从那时起可用；当前这一次（用户手动打开的）由调用方的闸门
    /// 判定并退化到壳自重启。
    ///
    /// 三条纪律：
    /// ① **绝不 `bootout`**：本函数会在壳**正在运行**时被调用，bootout 会当场
    ///    把壳杀掉——那是"换壳"该做的事，不是"写登录项"该做的。
    /// ② 路径纪律同 daemon（`/target/`、`/tmp/`、非稳定安装位置一律拒绝）。
    /// ③ 内容一致就一个字都不写（幂等）。
    fn register_shell_agent(&self, exec: &Path) -> Result<()> {
        let exec_str = exec.display().to_string();
        if exec_str.contains("/target/") || exec_str.contains("/tmp/") {
            return Err(PlatformError::Failed {
                action: "register_shell_agent rejects unstable path",
                detail: exec_str,
            });
        }
        if !is_stable_install_location(exec) {
            return Err(PlatformError::Failed {
                action: "register_shell_agent outside a stable install location",
                detail: exec_str,
            });
        }
        let path = shell_agent_plist_path();
        let want = shell_agent_plist(exec);
        if std::fs::read_to_string(&path).ok().as_deref() != Some(want.as_str()) {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(io_err("create LaunchAgents dir"))?;
            }
            write_atomic(&path, &want).map_err(io_err("write shell LaunchAgent plist"))?;
        }
        Ok(())
    }

    /// DESK-72 (#1012)：登录项就是那份 `RunAtLoad=true` 的壳 LaunchAgent。
    fn register_shell_login_item(&self, exec: &Path) -> Result<()> {
        self.register_shell_agent(exec)
    }

    fn shell_agent_registered_exec(&self) -> Result<Option<PathBuf>> {
        let path = shell_agent_plist_path();
        match std::fs::read_to_string(&path) {
            Ok(text) => Ok(plist_program_argument(&text).map(PathBuf::from)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(PlatformError::Io {
                action: "read shell LaunchAgent plist",
                source: e,
            }),
        }
    }

    /// 磁盘上**安装包**的版本（`Contents/Info.plist` 的 `CFBundleShortVersionString`）。
    ///
    /// 用 `defaults read` 而不是自己解 plist：真实 `.app` 里的 `Info.plist` 是
    /// **二进制** plist，手写文本解析会在真机上静默读空；`defaults` 是系统自带、
    /// 二进制/XML 都吃，而且与验收 SOP 用的是同一条命令（排查口径一致）。
    ///
    /// 读不到（不是 .app 布局、`defaults` 失败）= `None` = **不知道**，
    /// 由调用方按"什么都不做"处理。
    fn installed_bundle_version(&self) -> Option<String> {
        let exe = std::env::current_exe().ok()?;
        let bundle = bundle_root(&exe)?;
        let plist = bundle.join("Contents").join("Info.plist");
        let out = Command::new("defaults")
            .arg("read")
            .arg(&plist)
            .arg("CFBundleShortVersionString")
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
        (!v.is_empty()).then_some(v)
    }

    /// `kickstart -kp`：launchd **杀掉正在跑的实例、立刻用磁盘上的文件重新拉起**，
    /// `-p` 把新实例的 pid 打到 stdout——这就是"重启成功了没有"的**可验证判据**
    /// （不用时间猜；对照 Clash Verge 那条"报告升级成功但实际没换好"的教训）。
    ///
    /// ⚠️ 调用方通常就是被重启的那个壳：命令把它杀掉之后，stdout 很可能拿不到，
    /// 这是**正常路径**，不是失败。
    fn kickstart_shell_agent(&self) -> Result<u32> {
        let uid = current_uid()?;
        let out = Command::new("launchctl")
            .args([
                "kickstart",
                "-kp",
                &format!("gui/{uid}/{SHELL_AGENT_LABEL}"),
            ])
            .output()
            .map_err(io_err("launchctl kickstart"))?;
        if !out.status.success() {
            return Err(PlatformError::Failed {
                action: "launchctl kickstart",
                detail: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        kickstart_reported_pid(&stdout).ok_or_else(|| PlatformError::Failed {
            action: "launchctl kickstart -p",
            detail: format!("读不出新 pid: {}", stdout.trim()),
        })
    }

    // ── #667 / #732：常驻 daemon 归 launchd ─────────────────────────────

    /// #1060：`launchctl bootout` 把 job 从 launchd 卸下（进程收 SIGTERM、KeepAlive
    /// 随 job 一起消失），**plist 留着**——「仅仅 kill」会被 KeepAlive 3 秒内用
    /// 旧文件拉回来。恢复由 `restart_resident_daemon` 的 bootstrap 分支负责。
    fn pause_resident_daemon(&self) -> Result<crate::ResidentPause> {
        let uid = current_uid()?;
        pause_resident_with(Self::agent_plist_path().exists(), &uid, &mut |args| {
            let out = Command::new("launchctl")
                .args(args)
                .output()
                .map_err(io_err("launchctl bootout"))?;
            Ok((
                out.status.code(),
                String::from_utf8_lossy(&out.stderr).trim().to_string(),
            ))
        })
    }

    /// F7：登记文件还在、launchd 却没加载这个 job ⇒ 有人 `launchctl bootout` 了它（正常
    /// 停止）。崩溃 / 被杀时 job 仍在 launchd 手里，由 KeepAlive 拉回，不算。
    /// 窗口自己的「停止」会连登记一起撤（plist 不在），走用户停止标记那条，也不在这里。
    fn resident_stopped_on_request(&self) -> bool {
        if !Self::agent_plist_path().exists() {
            return false;
        }
        let Ok(uid) = current_uid() else {
            return false;
        };
        Command::new("launchctl")
            .args(["print", &format!("gui/{uid}/{AGENT_LABEL}")])
            .output()
            .is_ok_and(|out| !out.status.success())
    }

    fn resident_daemon_pid(&self) -> Option<u32> {
        let uid = current_uid().ok()?;
        let out = Command::new("launchctl")
            .args(["print", &format!("gui/{uid}/{AGENT_LABEL}")])
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        launchd_job_pid(&String::from_utf8_lossy(&out.stdout))
    }

    /// `launchctl kickstart [-k]p gui/<uid>/com.hawkeyexb.ppass.desktop.daemon`。
    ///
    /// 为什么不再"pkill 然后等 KeepAlive 拉回来"（DAE-04 原做法）：
    /// ① 被杀 = 非成功退出，launchd 的重拉吃节流（10s 量级，DESK-44 的假失败
    ///    就骑在这上面）；kickstart 是**立刻**按磁盘上的文件拉，且 `-p` 报新 pid。
    /// ② 一次性 spawn（更新后恢复的旧做法）出来的实例 launchd 不认，崩了不拉，
    ///    stdio 也不进 LaunchAgent 的日志（#732 ①③）。
    ///
    /// 登记文件在、但 job 没被 launchd 加载（`kickstart` 报找不到服务）⇒
    /// `bootstrap`：plist 是 `RunAtLoad=true`，加载即启动。
    fn restart_resident_daemon(&self, kill_running: bool) -> Result<crate::ResidentRestart> {
        let plist = Self::agent_plist_path();
        if !plist.exists() {
            return Ok(crate::ResidentRestart::NotRegistered);
        }
        if !kill_running {
            if let Some(pid) = self.resident_daemon_pid() {
                return Ok(crate::ResidentRestart::AlreadyRunning { pid });
            }
        }
        let uid = current_uid()?;
        let flags = if kill_running { "-kp" } else { "-p" };
        let out = Command::new("launchctl")
            .args(["kickstart", flags, &format!("gui/{uid}/{AGENT_LABEL}")])
            .output()
            .map_err(io_err("launchctl kickstart"))?;
        if out.status.success() {
            if let Some(pid) = kickstart_reported_pid(&String::from_utf8_lossy(&out.stdout))
                .or_else(|| self.resident_daemon_pid())
            {
                return Ok(crate::ResidentRestart::Started { pid });
            }
            return Err(PlatformError::Failed {
                action: "launchctl kickstart -p",
                detail: format!(
                    "读不出新 pid: {}",
                    String::from_utf8_lossy(&out.stdout).trim()
                ),
            });
        }
        let kick_err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        let boot = Command::new("launchctl")
            .args(["bootstrap", &format!("gui/{uid}")])
            .arg(&plist)
            .output()
            .map_err(io_err("launchctl bootstrap"))?;
        if !boot.status.success() {
            return Err(PlatformError::Failed {
                action: "launchctl kickstart / bootstrap",
                detail: format!(
                    "kickstart: {kick_err}; bootstrap: {}",
                    String::from_utf8_lossy(&boot.stderr).trim()
                ),
            });
        }
        for _ in 0..50 {
            if let Some(pid) = self.resident_daemon_pid() {
                return Ok(crate::ResidentRestart::Started { pid });
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        Err(PlatformError::Failed {
            action: "launchctl bootstrap",
            detail: format!("已加载但 5s 内 launchd 没报出在跑的 pid（kickstart: {kick_err}）"),
        })
    }
}

/// `launchctl bootout` 的退出码里「job 本来就没加载」的两个：3（No such process）、
/// 113（Could not find specified service）——对「要它停着」而言已达成。
const BOOTOUT_NOT_LOADED_CODES: [i32; 2] = [3, 113];

/// launchctl 执行器：收参数、回 (退出码, stderr)。
type LaunchctlRun<'a> = dyn FnMut(&[String]) -> Result<(Option<i32>, String)> + 'a;

/// [`MacosAdapter::pause_resident_daemon`] 的判据，命令执行器可注入（单测不跑真
/// launchctl）。`run` 收参数、回 (退出码, stderr)。
/// §5.3：照片库根目录设为 `0700`（只有主人能进）。目录不存在就先建出来——否则之后由
/// daemon 按默认 umask 建，得到的是别人可读的 `0755`。设完回读核对。
///
/// 卷本身不保存权限（exFAT / FAT32，或「忽略此卷上的所有权」的外接盘）时，chmod 不生效也
/// 不是错误：返回 [`crate::LibraryDirGrant::SkippedNoAcl`]，不阻断、不提示（方案 §2.2）。
pub(crate) fn make_library_dir_private(dir: &Path) -> Result<crate::LibraryDirGrant> {
    use std::os::unix::fs::PermissionsExt as _;
    let io = |action: &'static str| move |source| PlatformError::Io { action, source };
    if !dir.exists() {
        std::fs::create_dir_all(dir).map_err(io("create_library_dir"))?;
    }
    if !std::fs::metadata(dir)
        .map_err(io("stat_library_dir"))?
        .is_dir()
    {
        return Err(PlatformError::Failed {
            action: "grant_library_dir",
            detail: "选的不是目录".into(),
        });
    }
    let set = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    let mode = std::fs::metadata(dir)
        .map_err(io("stat_library_dir"))?
        .permissions()
        .mode()
        & 0o777;
    if set.is_ok() && mode == 0o700 {
        return Ok(crate::LibraryDirGrant::Granted);
    }
    if let Some(file_system) = volume_without_permissions(dir) {
        return Ok(crate::LibraryDirGrant::SkippedNoAcl { file_system });
    }
    match set {
        Err(source) => Err(PlatformError::Io {
            action: "chmod_library_dir",
            source,
        }),
        Ok(()) => Err(PlatformError::Failed {
            action: "grant_library_dir",
            detail: format!("设置后权限是 {mode:o}，应为 700"),
        }),
    }
}

/// 卷不保存 unix 权限时返回它的文件系统名（`exfat` / `msdos`，或带「忽略所有权」标记的卷）。
fn volume_without_permissions(dir: &Path) -> Option<String> {
    use std::os::unix::ffi::OsStrExt as _;
    let c = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statfs = unsafe { std::mem::zeroed() };
    // SAFETY: c 是 NUL 结尾的路径；st 是零初始化的出参。
    if unsafe { libc::statfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    // SAFETY: f_fstypename 是内核写好的 NUL 结尾字符串。
    let name = unsafe { std::ffi::CStr::from_ptr(st.f_fstypename.as_ptr()) }
        .to_string_lossy()
        .into_owned();
    let no_perms = matches!(name.as_str(), "exfat" | "msdos")
        || st.f_flags & (libc::MNT_IGNORE_OWNERSHIP as u32) != 0;
    no_perms.then_some(name)
}

#[cfg(test)]
mod library_dir_private_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt as _;

    fn mode(p: &Path) -> u32 {
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    /// 判据：库根目录设置后是 0700。反证：去掉 chmod（或改成 0755）⇒ 红。
    #[test]
    fn library_dir_private_mode_is_0700() {
        let d = tempfile::tempdir().unwrap();
        let lib = d.path().join("Photos");
        std::fs::create_dir(&lib).unwrap();
        std::fs::set_permissions(&lib, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            MacosAdapter.grant_library_dir(&lib).expect("grant"),
            crate::LibraryDirGrant::Granted
        );
        assert_eq!(mode(&lib), 0o700);
        // 幂等。
        assert_eq!(
            MacosAdapter.grant_library_dir(&lib).expect("again"),
            crate::LibraryDirGrant::Granted
        );
        assert_eq!(mode(&lib), 0o700);
    }

    /// 首启默认位置还不存在：建出来就是 0700，不留给 daemon 按 umask 建成 0755。
    #[test]
    fn library_dir_private_creates_missing_dir_as_0700() {
        let d = tempfile::tempdir().unwrap();
        let lib = d.path().join("Pictures").join("P-Pass Library");
        assert_eq!(
            MacosAdapter.grant_library_dir(&lib).expect("grant"),
            crate::LibraryDirGrant::Granted
        );
        assert!(lib.is_dir());
        assert_eq!(mode(&lib), 0o700);
    }

    /// 选的不是目录 ⇒ Err（调用方据此不把它交给 daemon）。
    #[test]
    fn library_dir_private_rejects_a_file() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("not-a-dir");
        std::fs::write(&f, b"x").unwrap();
        assert!(MacosAdapter.grant_library_dir(&f).is_err());
    }

    /// 本机系统盘（APFS）保存权限：不会误走「跳过」分支。
    #[test]
    fn library_dir_private_system_volume_keeps_permissions() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(volume_without_permissions(d.path()), None);
    }
}

pub(crate) fn pause_resident_with(
    plist_exists: bool,
    uid: &str,
    run: &mut LaunchctlRun,
) -> Result<crate::ResidentPause> {
    if !plist_exists {
        return Ok(crate::ResidentPause::NotRegistered);
    }
    let args = ["bootout".to_string(), format!("gui/{uid}/{AGENT_LABEL}")];
    match run(&args)? {
        (Some(0), _) => Ok(crate::ResidentPause::Paused),
        (Some(c), _) if BOOTOUT_NOT_LOADED_CODES.contains(&c) => Ok(crate::ResidentPause::Paused),
        (code, stderr) => Err(PlatformError::Failed {
            action: "launchctl bootout",
            detail: format!("exit {code:?}: {stderr}"),
        }),
    }
}

/// RAII wrapper over a `caffeinate -i` child: alive = system stays awake.
pub struct CaffeinateGuard {
    child: std::process::Child,
}

impl Drop for CaffeinateGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod pause_resident_tests {
    use super::*;
    use crate::ResidentPause;

    fn run_with(code: Option<i32>) -> (Vec<Vec<String>>, Result<ResidentPause>) {
        let mut calls = Vec::new();
        let r = pause_resident_with(true, "501", &mut |a| {
            calls.push(a.to_vec());
            Ok((code, "boom".into()))
        });
        (calls, r)
    }

    /// #1011：脱敏要保留的平台文件名 = daemon LaunchAgent 的 plist（与改前写死值一致）。
    #[test]
    fn redaction_keeps_the_daemon_launch_agent_plist_name() {
        assert_eq!(
            MacosAdapter.redaction_safe_file_names(),
            ["com.hawkeyexb.ppass.desktop.daemon.plist"]
        );
    }

    /// #1060：暂停 = bootout 该 job（卸载、KeepAlive 随之消失），不是 kill。
    /// 反证：把 bootout 换成别的命令 / 漏调 → 第一条红。
    #[test]
    fn pause_boots_the_job_out() {
        let (calls, r) = run_with(Some(0));
        assert_eq!(r.unwrap(), ResidentPause::Paused);
        assert_eq!(
            calls,
            vec![vec![
                "bootout".to_string(),
                format!("gui/501/{AGENT_LABEL}")
            ]]
        );
    }

    /// 没登记就什么都不跑；本来就没加载 = 已停；其余失败如实报错（不静默当成功）。
    #[test]
    fn pause_edge_cases() {
        let mut called = false;
        let r = pause_resident_with(false, "501", &mut |_| {
            called = true;
            Ok((Some(0), String::new()))
        });
        assert_eq!(r.unwrap(), ResidentPause::NotRegistered);
        assert!(!called);
        for code in [3, 113] {
            assert_eq!(run_with(Some(code)).1.unwrap(), ResidentPause::Paused);
        }
        assert!(run_with(Some(1)).1.is_err());
        assert!(run_with(None).1.is_err());
    }
}

#[cfg(test)]
mod diag_log_tests {
    use super::*;

    /// #1110：壳找内置 daemon 只认嵌套 helper，正式安装与 `tauri dev` 同一条相对规则。
    /// 反证：退回 `exe.parent().join("ppf-daemon")`（裸 sidecar）⇒ 两条都红。
    #[test]
    fn bundled_daemon_lives_in_the_nested_helper_app() {
        assert_eq!(
            MacosAdapter
                .bundled_daemon_path(Path::new("/Applications/P-Pass.app/Contents/MacOS/p-pass-desktop")),
            Some(PathBuf::from(
                "/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon"
            ))
        );
        assert_eq!(
            bundled_daemon_path_from(Path::new("/w/src-tauri/target/debug/p-pass-desktop")),
            Some(PathBuf::from(
                "/w/src-tauri/target/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon"
            ))
        );
    }

    // DIAG-B1：macOS daemon 日志落在固定位置、跟着 data dir 走（PPF_DATA_DIR 隔离不漏），且 tee stderr。
    // 反证：log_file 退回 None（DIAG-B1 之前）→ 一次性 spawn 的 daemon 没有任何日志，红。
    // #1046：launchd 接的 stdout/stderr 也在 `<data_dir>/logs/` 里，plist 与
    // daemon_log_paths 同源（逐字一致）；不许与 daemon 自己 append 的 daemon.log 同名。
    // 反证：plist 退回 `~/Library/Logs/p-pass-daemon.*` → 前两条红。
    #[test]
    fn daemon_log_lives_under_the_effective_data_dir_and_tees_stderr() {
        let adapter = MacosAdapter;
        let dir = Path::new("/var/ppf-isolated");
        let paths = adapter.daemon_log_paths(dir);
        let logs = dir.join("logs");
        assert_eq!(paths.log_file, Some(logs.join("daemon.log")));
        assert_eq!(paths.stdout, Some(logs.join("daemon.out")));
        assert_eq!(paths.stderr, Some(logs.join("daemon.err")));
        assert_ne!(
            paths.stdout, paths.log_file,
            "launchd 不能和 daemon 写同一个文件"
        );
        let plist = agent_plist(
            Path::new("/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon"),
            &paths,
        );
        let (out, err) = (paths.stdout.clone().unwrap(), paths.stderr.clone().unwrap());
        assert!(plist.contains(&format!(
            "<key>StandardOutPath</key><string>{}</string>",
            out.display()
        )));
        assert!(plist.contains(&format!(
            "<key>StandardErrorPath</key><string>{}</string>",
            err.display()
        )));
        assert!(paths.stdio_by_service_manager);
        assert!(adapter.default_log_tees_stderr());
        // #1109：常驻 daemon 只带可执行文件路径——`--ephemeral` 用内存里的
        // 随机身份，带上它常驻服务每次启动都换 NodeId。
        // 反证：ProgramArguments 里加一个 `--ephemeral`，第一条红。
        assert!(!plist.contains("--ephemeral"), "{plist}");
        assert_eq!(
            plist_program_argument(&plist).as_deref(),
            Some("/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon")
        );
    }

    /// #1046：老版本登记（exe 相同、日志落点在 `~/Library/Logs`）判为「不是本版本
    /// 的登记」⇒ 对账会重写成新路径；本版本自己写出的那份判为是（幂等）。
    #[test]
    fn a_plist_with_the_old_log_paths_is_not_current() {
        let exe = Path::new(
            "/Applications/P-Pass.app/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon",
        );
        let logs = daemon_log_paths_in(Path::new("/Users/x/Library/Application Support/P-Pass"));
        let current = agent_plist(exe, &logs);
        assert!(plist_is_current(&current, exe, &logs));
        let old = current
            .replace(
                &logs.stdout.clone().unwrap().display().to_string(),
                "/Users/x/Library/Logs/p-pass-daemon.log",
            )
            .replace(
                &logs.stderr.clone().unwrap().display().to_string(),
                "/Users/x/Library/Logs/p-pass-daemon.err",
            );
        assert_ne!(old, current);
        assert!(!plist_is_current(&old, exe, &logs));
        // exe 仍读得回同一个（所以 #604 的路径比较会判 Unchanged，必须靠内容比较发现）。
        assert_eq!(plist_program_argument(&old).as_deref(), exe.to_str());
    }
}

#[cfg(test)]
mod b10_user_dirs_tests {
    use super::*;

    /// #1043（B10）：macOS 的家目录与「图片」目录由适配器回答，与系统约定一致。
    #[test]
    fn pictures_dir_is_home_pictures() {
        let a = MacosAdapter;
        let home = a.home_dir().expect("测试环境有 HOME");
        assert_eq!(home, PathBuf::from(std::env::var("HOME").unwrap()));
        assert_eq!(a.pictures_dir(), Some(home.join("Pictures")));
    }
}

#[cfg(test)]
mod b6_system_locale_tests {
    use super::*;

    /// #1043（B6）：真调一次 CoreFoundation，读得到首选语言、不 panic。
    /// 具体值随机器而定，只断言形状（非空、不含编码后缀）。
    #[test]
    fn preferred_language_is_readable() {
        let tag = MacosAdapter.system_locale().expect("macOS 总有首选语言");
        assert!(!tag.is_empty() && !tag.contains('.'), "{tag:?}");
        println!("system_locale = {tag}");
    }
}

#[cfg(test)]
mod ux_capability_tests {
    use super::*;

    /// #1043：界面层的平台能力（原先前端按平台名 switch 判出来的三项）。
    #[test]
    fn macos_ui_capabilities() {
        let a = MacosAdapter;
        assert!(!a.close_to_tray_hint());
        assert!(a.overlay_titlebar());
        assert_eq!(a.sleep_owner(), Some(crate::SleepOwner::User));
    }
}

/// #1253：以 `O_EVTONLY` 打开 `root`，登记 kqueue `EVFILT_VNODE`（删除 / 改名 / 卷被撤销）。
/// 返回一个阻塞等待的闭包：事件到达返回 `true`；kqueue 出错返回 `false`（不当成「库没了」）。
/// 打开与登记在调用线程里做——登记失败当场报错，不留一个什么都等不到的线程。
fn watch_vnode_gone(root: &Path) -> std::io::Result<impl FnOnce() -> bool + Send> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let c_path = CString::new(root.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "路径里有 NUL"))?;
    // SAFETY: c_path 是以 NUL 结尾的合法 C 字符串；返回的 fd 由下面的闭包负责关闭。
    let fd = unsafe { libc::open(c_path.as_ptr(), libc::O_EVTONLY) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: kqueue() 无参数；失败返回 -1。
    let kq = unsafe { libc::kqueue() };
    if kq < 0 {
        let e = std::io::Error::last_os_error();
        unsafe { libc::close(fd) };
        return Err(e);
    }
    let change = libc::kevent {
        ident: fd as libc::uintptr_t,
        filter: libc::EVFILT_VNODE,
        flags: libc::EV_ADD | libc::EV_CLEAR,
        fflags: libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    // SAFETY: change 指向一个有效的 kevent；不取回事件（nevents = 0）。
    let rc = unsafe { libc::kevent(kq, &change, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
    if rc < 0 {
        let e = std::io::Error::last_os_error();
        unsafe {
            libc::close(kq);
            libc::close(fd);
        }
        return Err(e);
    }
    Ok(move || {
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        let gone = loop {
            // SAFETY: event 是可写的 kevent；无超时，阻塞到事件到达。
            let n =
                unsafe { libc::kevent(kq, std::ptr::null(), 0, &mut event, 1, std::ptr::null()) };
            if n > 0 {
                break true;
            }
            if n < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                break false;
            }
        };
        unsafe {
            libc::close(kq);
            libc::close(fd);
        }
        gone
    })
}

#[cfg(test)]
mod library_root_watch_tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    fn watch(dir: &Path) -> mpsc::Receiver<()> {
        let (tx, rx) = mpsc::channel();
        assert!(MacosAdapter.watch_library_root(dir, Box::new(move || tx.send(()).unwrap())));
        rx
    }

    // #1253：库目录被改名（挪走）→ 立刻回调；里面的文件变化不回调。
    #[test]
    fn renaming_the_root_fires_and_inner_changes_do_not() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("lib");
        std::fs::create_dir(&root).unwrap();
        let rx = watch(&root);
        std::fs::write(root.join("a.jpg"), b"x").unwrap();
        assert!(
            rx.recv_timeout(Duration::from_millis(300)).is_err(),
            "库里的文件变化不算库没了"
        );
        std::fs::rename(&root, parent.path().join("lib-renamed")).unwrap();
        rx.recv_timeout(Duration::from_secs(2))
            .expect("改名必须回调");
    }

    #[test]
    fn deleting_the_root_fires() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("lib");
        std::fs::create_dir(&root).unwrap();
        let rx = watch(&root);
        std::fs::remove_dir(&root).unwrap();
        rx.recv_timeout(Duration::from_secs(2))
            .expect("删除必须回调");
    }

    #[test]
    fn a_missing_root_reports_no_capability() {
        let parent = tempfile::tempdir().unwrap();
        assert!(!MacosAdapter.watch_library_root(&parent.path().join("nope"), Box::new(|| {})));
    }
}
