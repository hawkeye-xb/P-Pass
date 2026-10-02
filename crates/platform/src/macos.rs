//! macOS adapter (§4 对照表右列).
//!
//! - Autostart: LaunchAgent plist (`RunAtLoad` + `KeepAlive` — crash
//!   restart comes free) + `launchctl bootstrap/bootout`.
//! - Awake: a `caffeinate -i` child process held RAII-style — zero FFI,
//!   visible in `pmset -g assertions` (the smoke check). IOKit
//!   assertions are the Phase-2 upgrade, interface unchanged.
//! - Keys: the login Keychain via the `security` CLI (generic password).
//! - Power hint: `pmset -g custom` through the shared pure parser.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{AwakeGuard, KeyStore, PlatformAdapter, PlatformError, PowerHint, Result, ServiceMode};

const AGENT_LABEL: &str = "com.p-pass.daemon";
const KEYCHAIN_SERVICE: &str = "P-Pass";

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
pub(crate) fn agent_plist(exec: &Path) -> String {
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
    <key>StandardOutPath</key><string>{}/Library/Logs/p-pass-daemon.log</string>
    <key>StandardErrorPath</key><string>{}/Library/Logs/p-pass-daemon.err</string>
</dict>
</plist>
"#,
        exec.display(),
        home().display(),
        home().display(),
    )
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
const SHELL_AGENT_LABEL: &str = "com.p-pass.shell";

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
/// `RunAtLoad=false` 同理：登记不代表开机自启（要不要开机自启 GUI 是另一个
/// 产品决定，不许被这次改动顺手带上）。
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
    <key>RunAtLoad</key><false/>
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

impl Default for MacosAdapter {
    fn default() -> Self {
        Self::new()
    }
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()))
}

fn io_err(action: &'static str) -> impl Fn(std::io::Error) -> PlatformError {
    move |source| PlatformError::Io { action, source }
}

impl PlatformAdapter for MacosAdapter {
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
        let plist = agent_plist(exec);
        let path = Self::agent_plist_path();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(io_err("create LaunchAgents dir"))?;
        }
        std::fs::write(&path, plist).map_err(io_err("write LaunchAgent plist"))?;
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

    /// 【DESK-42 #604】读登记条目里的目标路径：文件不存在 = 未登记（`None`）。
    /// 读得到但解析不出路径 = 登记已损坏，同样按「读不出」报 `None`，
    /// 由对账把它重写成当前安装路径。
    fn autostart_registered_exec(&self) -> Result<Option<PathBuf>> {
        let path = Self::agent_plist_path();
        match std::fs::read_to_string(&path) {
            Ok(text) => Ok(plist_program_argument(&text).map(PathBuf::from)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(PlatformError::Io {
                action: "read LaunchAgent plist",
                source: e,
            }),
        }
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

    fn key_store(&self) -> Box<dyn KeyStore> {
        Box::new(KeychainStore)
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

    /// DIAG-B1：固定位置，与 Windows 同构（`<data_dir>/logs/daemon.log`，轮转
    /// 出 `daemon.log.1`）。跟着 data dir 走，`PPF_DATA_DIR` 隔离的一次性
    /// daemon 不会写进用户真实日志。
    fn default_log_file(&self, data_dir: &Path) -> Option<PathBuf> {
        Some(data_dir.join("logs").join("daemon.log"))
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
    fn tray_shows_menu_on_left_click(&self) -> bool {
        true
    }

    fn kill_daemon_process(&self) -> Result<crate::KillOutcome> {
        crate::unix::kill_daemon_process()
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

    /// 幂等登记。三条纪律：
    ///
    /// ① **绝不 `bootout`**：本函数会在壳**正在运行**时被调用，bootout 会当场
    ///    把壳杀掉——那是"换壳"该做的事，不是"确保登记"该做的。因此"改了内容
    ///    要重新加载"这件事对壳不成立：壳的可执行文件在 `/Applications` 下跨
    ///    更新**路径不变**，plist 内容天然稳定，写一次就够。
    /// ② 路径纪律同 daemon（`/target/`、`/tmp/`、非稳定安装位置一律拒绝）。
    /// ③ 只在 `launchctl print` 说**没加载**时才 `bootstrap`；已加载直接返回。
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
            std::fs::write(&path, want).map_err(io_err("write shell LaunchAgent plist"))?;
        }
        let uid = current_uid()?;
        let loaded = Command::new("launchctl")
            .args(["print", &format!("gui/{uid}/{SHELL_AGENT_LABEL}")])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if loaded {
            return Ok(());
        }
        let out = Command::new("launchctl")
            .args(["bootstrap", &format!("gui/{uid}")])
            .arg(&path)
            .output()
            .map_err(io_err("launchctl bootstrap (shell)"))?;
        if !out.status.success() {
            return Err(PlatformError::Failed {
                action: "launchctl bootstrap (shell)",
                detail: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        Ok(())
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
        stdout
            .split_whitespace()
            .last()
            .and_then(|s| s.parse::<u32>().ok())
            .ok_or_else(|| PlatformError::Failed {
                action: "launchctl kickstart -p",
                detail: format!("读不出新 pid: {}", stdout.trim()),
            })
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

/// Login-keychain generic passwords via the `security` CLI. Secrets are
/// stored hex-encoded (the CLI is text-oriented).
struct KeychainStore;

impl KeyStore for KeychainStore {
    fn store(&self, name: &str, secret: &[u8]) -> Result<()> {
        let hex: String = secret.iter().map(|b| format!("{b:02x}")).collect();
        let out = Command::new("security")
            .args([
                "add-generic-password",
                "-U", // update if exists
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                name,
                "-w",
                &hex,
            ])
            .output()
            .map_err(io_err("security add-generic-password"))?;
        if !out.status.success() {
            return Err(PlatformError::Failed {
                action: "keychain store",
                detail: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        Ok(())
    }

    fn load(&self, name: &str) -> Result<Option<Vec<u8>>> {
        let out = Command::new("security")
            .args([
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                name,
                "-w",
            ])
            .output()
            .map_err(io_err("security find-generic-password"))?;
        if !out.status.success() {
            return Ok(None); // not found (or locked — treated as absent)
        }
        let hex = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let mut bytes = Vec::with_capacity(hex.len() / 2);
        let raw = hex.as_bytes();
        for chunk in raw.as_chunks::<2>().0 {
            let hi = (chunk[0] as char).to_digit(16);
            let lo = (chunk[1] as char).to_digit(16);
            match (hi, lo) {
                (Some(h), Some(l)) => bytes.push(((h << 4) | l) as u8),
                _ => {
                    return Err(PlatformError::Failed {
                        action: "keychain load",
                        detail: "stored value is not hex".into(),
                    })
                }
            }
        }
        Ok(Some(bytes))
    }

    fn delete(&self, name: &str) -> Result<()> {
        let _ = Command::new("security")
            .args([
                "delete-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                name,
            ])
            .output()
            .map_err(io_err("security delete-generic-password"))?;
        Ok(())
    }
}

#[cfg(test)]
mod diag_log_tests {
    use super::*;

    // DIAG-B1：macOS daemon 日志落在固定位置、跟着 data dir 走（PPF_DATA_DIR 隔离不漏），且 tee stderr。
    // 反证：default_log_file 退回 None（改动前）→ 一次性 spawn 的 daemon 没有任何日志，红。
    #[test]
    fn daemon_log_lives_under_the_effective_data_dir_and_tees_stderr() {
        let adapter = MacosAdapter;
        let dir = Path::new("/var/ppf-isolated");
        assert_eq!(
            adapter.default_log_file(dir),
            Some(dir.join("logs").join("daemon.log"))
        );
        assert!(adapter.default_log_tees_stderr());
    }
}
