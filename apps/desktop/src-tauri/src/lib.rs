//! P-Pass tray shell (T-041, ADR-012): zero business logic — every
//! command is a thin forward to the daemon's local IPC.

mod daemon_logs;
mod ipc;

// QA-09 迁移（#211）：桌面壳现在有 9 个地方要调 platform 的能力，
// 每个函数各写一遍 `use ... as _` 已经不划算；提到文件级。
use platform::PlatformAdapter as _;
use serde_json::{json, Value};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::Emitter;
use tauri::Manager;

// UPD-01: updater plugin（pubkey/endpoints 在 tauri.conf.json；
// build 期 updater artifact 签名需 TAURI_SIGNING_PRIVATE_KEY——CI 由
// UPDATE_SIGNING_KEY 提供，本地无 key 路径跳过 .sig 生成）。
// 注意：tauri-plugin-updater 2.10 的 build() 返回带 Config 的 TauriPlugin，
// 需内联注册（独立函数标注单参数类型会类型不匹配）。

/// Forward one IPC method. The frontend does the rest.
// MOB-47: 视频弹窗走 asset 协议从磁盘直接 streaming 播放，避免把整段
// 视频 base64 拉进内存。安全契约（L2 审查修）：
// - 渲染进程只传资产 hash，绝不传文件系统路径；
// - 后端用该 hash 走 daemon 可信的 `asset.path`（记录查找 → 库根 + rel_path），
//   拿到路径后 canonicalize（解析软链）并核对是真实存在的普通文件；
// - 只授权这一个文件（`allow_file`），不授权目录、不授权父目录，
//   不留任意路径提权口子。
// 返回值是 canonicalized 后的绝对路径（前端 convertFileSrc 用）。
// 失败返回 Err → 前端落到 thumb.get 缩略图兜底。
//
// 注意：tauri::Manager::asset_protocol_scope 是 #[cfg(feature =
// "protocol-asset")]（不在 default），需在 src-tauri/Cargo.toml 显式
// 声明该 feature（已在 MOB-47 加）。
#[tauri::command]
fn allow_media_scope(app: tauri::AppHandle, hash: String) -> Result<String, String> {
    use tauri::Manager;
    // 路径只能来自 daemon 按 hash 的记录查找，杜绝渲染进程传入任意路径。
    let resp = ipc::DaemonHandle::discover()?
        .call("asset.path", json!({ "hash": hash }))
        .map_err(|e| format!("取资产路径失败：{e}"))?;
    let raw = resp
        .get("path")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "后台服务未返回资产路径".to_string())?;
    let file = validate_asset_file(std::path::Path::new(raw))?;
    // 只放开这一个文件（不是目录层、不是父目录）。
    app.asset_protocol_scope()
        .allow_file(&file)
        .map_err(|e| format!("授权媒体文件失败：{e}"))?;
    Ok(file.to_string_lossy().into_owned())
}

/// 授权前校验：canonicalize（解析软链）+ 必须是普通文件。路径必须来自
/// daemon 的 `asset.path`（记录查找），本函数从不接受渲染进程直接给的路径。
fn validate_asset_file(path: &std::path::Path) -> Result<std::path::PathBuf, String> {
    let canon = std::fs::canonicalize(path).map_err(|e| format!("资产文件不可达：{e}"))?;
    if !canon.is_file() {
        return Err("资产路径不是普通文件".to_string());
    }
    Ok(canon)
}

/// Forward one IPC method. The frontend does the rest.
#[tauri::command]
fn daemon_call(method: String, params: Value) -> Result<Value, String> {
    ipc::DaemonHandle::discover()?.call(&method, params)
}

/// Daemon reachable? (tray tooltip + frontend banner)
#[tauri::command]
fn daemon_online() -> bool {
    ipc::DaemonHandle::discover()
        .and_then(|d| d.call("status", json!({})))
        .is_ok()
}

/// IPC-02: 长连接事件订阅——daemon 事件经 Tauri event `daemon-event`
/// 转发给前端（前端 `listen("daemon-event", …)` 按事件类型即时刷新）。
/// 断线 2s 退避自动重连；订阅握手失败（老 daemon）静默降级——前端
/// 60s 兜底轮询仍在，功能不丢。
#[tauri::command]
fn start_event_stream(app: tauri::AppHandle) {
    std::thread::spawn(move || loop {
        match ipc::DaemonHandle::discover() {
            Ok(handle) => {
                let app = app.clone();
                let _ = handle.subscribe_events(move |ev| {
                    let _ = app.emit("daemon-event", ev);
                });
                // 连接断开（daemon 重启/退出）——退避后重连。
            }
            Err(_) => {
                // daemon 还没起——继续探测。
            }
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    });
}

/// First-run wizard state (T-042): configured = a config.toml exists in
/// the platform data dir; installed = the daemon has been registered as
/// a resident service. A config without an installed service means the
/// wizard was abandoned mid-way — route back into the wizard instead of
/// dumping the user on a bare "start the service" screen (xixi 实测反馈 3).
/// T-042b: `configured_library_dir` prefills the wizard's folder step from
/// the existing config, so a oneshot-degraded user (autostart registration
/// failed → fallback spawn; lib.rs start_daemon Err branch) who bounces back
/// into the wizard does NOT re-point the library to a fresh empty folder
/// (orphaned-library risk) — the wizard shows what's already configured.
#[tauri::command]
fn wizard_state() -> Value {
    let dir = platform::adapter().data_dir();
    // Photos must land somewhere a person can FIND (real walkthrough:
    // "传到哪儿了" had no answer while the library hid in ~/Library).
    let pictures = dirs_pictures().join("P-Pass 家庭照片库");
    let installed = platform::adapter().autostart_installed().unwrap_or(false);
    let configured_dir = ipc::read_config_data_dir(&dir);
    json!({
        "configured": dir.join("config.toml").exists(),
        "installed": installed,
        "default_dir": pictures.to_string_lossy(),
        // Some of the library, if the config already points somewhere —
        // the wizard prefills this so re-running it never orphans the
        // existing library (T-042b).
        "configured_library_dir": configured_dir,
        // W1 (2026-08-26): wizard copy hard-coded macOS-only wording
        // (Finder, TCC-protected 桌面/文稿, "macOS 拦截时右键打开") on
        // every platform — a Windows real-box run surfaced this as
        // "onboarding 说明都是 macOS 的". Expose the platform so the
        // frontend can branch copy instead of guessing from user agent.
        "platform": platform::adapter().platform_name(),
    })
}

fn dirs_pictures() -> std::path::PathBuf {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| ".".into());
    std::path::PathBuf::from(home).join("Pictures")
}

/// Current sleep policy, humanized for the wizard.
#[tauri::command]
fn power_hint() -> Value {
    match platform::adapter().power_hint() {
        platform::PowerHint::NeverSleeps => json!({ "kind": "never" }),
        platform::PowerHint::SleepsWhenIdle { minutes } => {
            json!({ "kind": "sleeps", "minutes": minutes })
        }
        platform::PowerHint::Unknown => json!({ "kind": "unknown" }),
    }
}

/// Open the OS power settings pane (the wizard's manual fallback —
/// backup-time wakefulness is handled automatically by the daemon's
/// AwakeGuard; this is for users who want always-on and don't want to
/// grant the one-click fix admin rights).
#[tauri::command]
fn open_power_settings() {
    // QA-09 迁移（#211）：「哪个 URI」是平台知识，搬进了 platform crate；
    // 「怎么打开」留在这里，因为那是 Tauri 层的事，不是系统知识。
    //
    // DESK-19 (#168) 的教训必须留在这儿：原来 Windows 走 `cmd /C start`，
    // 而 cmd.exe 是 console 子系统程序（本机实测 PE Subsystem = 3）。桌面壳
    // 自己是 GUI 子系统、手上没有控制台，Windows 只能为它新分配一个 ⇒
    // 每次点都闪一下黑窗。
    //
    // opener 插件构造上就不会分配控制台：`tauri-plugin-opener` 声明依赖时开了
    // `open` 的 `shellexecute-on-windows`（桌面壳 lockfile 里 `open` 带着
    // `dunce` 就是这个 feature 拉进来的），于是 `open::that_detached()` 走的是
    // **`ShellExecuteExW`**，**根本不起子进程**——没有进程可言，自然没有控制台。
    //
    // ⚠️ 这里原来写的是「候选命令条条带 CREATE_NO_WINDOW」。那描述的是
    // `open::commands()` 那条 powershell / explorer 分支，**本仓走不到**。
    // 结论（不闪窗）没错，理由是错的；#211 做真机验证时顺着错理由去找子进程，
    // 一个都没找到，才发现记错了。写清楚是因为这条注释有人会照着做判断。
    //
    // 2026-09-21 真机实测（#211）：点击前 SystemSettings 进程数 = 0，点击后
    // 设置页打开，全程**新增 conhost 数 = 0**。所以打开动作必须继续走它，
    // 不要改回自己起进程。
    //
    // `None` = 这个系统没有可直接跳转的设置页（Linux / headless），什么也
    // 不做；迁移前那两个平台本来就一个分支都没有，行为一致。
    if let Some(uri) = platform::adapter().power_settings_uri() {
        let _ = tauri_plugin_opener::open_url(uri, None::<&str>);
    }
}

/// 2026-08-17：一键关闭自动睡眠（向导第 2 步主选项）——用户实测反馈
/// 「去系统设置」打开的电池面板根本没把这个开关摆在明面上（不同 macOS
/// 版本/Mac 型号入口都不一样，本机实测 Battery 面板顶层就看不到），
/// 与其让家人自己找菜单，不如用系统原生的管理员授权弹窗（不是终端，
/// 是"输入密码/Touch ID"那种系统弹窗，很多工具类 App 都这么做）直接
/// 帮用户改。`-a`（覆盖电池+电源两种场景）而非只 `-c`（仅电源）——跟
/// `parse_pmset` 的检测口径一致（取所有场景里最小的正数 sleep 值），
/// 只改 AC 场景的话笔记本用电池时检测仍会报"还会睡眠"，勾不上✓。
/// 用户拒绝授权/找不到管理员密码时，「去系统设置」手动入口原样保留
/// 作为退路，不因为加了一键设置就删掉。
/// DESK-22 (#171) + QA-09 迁移 (#211)：平台实现已收进 `crates/platform/`，
/// 这里只剩「把三种结果翻译成给用户看的话」。
///
/// 三种结果分开呈现是刻意的：**取消不是失败**，本平台没实现也不是失败。
/// 前端（Wizard/WizardWindows 的 `fixAutoSleep`）收到 Err 就原样显示，
/// 并始终保留「去系统设置」这条手动退路。
#[tauri::command]
fn disable_auto_sleep() -> Result<(), String> {
    match platform::adapter().disable_auto_sleep() {
        Ok(platform::Applied::Done) => Ok(()),
        // Unsupported / NotApplicable 都走手动退路，文案与迁移前一致。
        Ok(_) => Err("这台电脑暂不支持一键设置，请用「去系统设置」手动关闭".into()),
        Err(platform::PlatformError::Cancelled { .. }) => Err("已取消授权".into()),
        Err(platform::PlatformError::Failed { detail, .. }) => Err(format!("设置失败：{detail}")),
        Err(e) => Err(format!("设置失败：{e}")),
    }
}

/// Write the initial config.toml (T-042 step 1) into the platform dir.
#[tauri::command]
fn write_config(library_dir: String) -> Result<(), String> {
    let dir = platform::adapter().data_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let config = format!(
        "data_dir = {:?}

# 固定端口：手机存的回连地址跨服务重启依然有效（真机教训）。
bind_addr = \"0.0.0.0:41145\"

# H-07 部署前必须为空（内置官方 relay 域名尚未上线）
relay_urls = []

[telemetry]
enabled = false
",
        library_dir
    );
    std::fs::write(dir.join("config.toml"), config).map_err(|e| e.to_string())
}

/// DESK-29 (#268)：`--version` 输出里那个"这确实是我们的 daemon"的记号。
///
/// 取的是 `crates/daemon/src/main.rs` 打印的固定前缀，**刻意不比对版本号**：
/// 桌面壳与 daemon 是两个独立 workspace（ADR-012），而 daemon 的版本还会被
/// `PPF_DAEMON_VERSION` / `PPF_BUILD_VERSION` 覆盖，比对版本号只会造出一个
/// 隔三差五自己红的判据。
///
/// ⚠️ 这是一处**跨 crate 的字符串耦合，目前没有守卫**：daemon 那边改了这句
/// 话，这里就会开始把好 daemon 判成坏的。错误方向是安全的（向导会明确报错，
/// 不是静默放行），但应该有个契约测试盯着——已开卡，本卡范围内不动 daemon。
const DAEMON_VERSION_MARKER: &str = "P-Pass daemon";

/// 探活子进程的上限。`--version` 在任何机器上都是毫秒级的事；给到 5 秒是
/// 为了「坏掉但仍能被 CreateProcess 接受」的文件——那种可能直接挂住，而
/// 向导不能跟着一起卡死。
const SIDECAR_PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// DESK-29 (#268)：把探活结果翻译成结论。
///
/// 抽成纯函数是刻意的：起子进程那半只能真机验，但**「什么才算通过」这条
/// 判据**可以单测。判据一旦松掉（比如有人图省事只看退出码），单测必须立刻红。
///
/// `code` = 子进程退出码；`None` 表示被信号/超时干掉，拿不到码。
fn sidecar_probe_verdict(code: Option<i32>, stdout: &str) -> Result<(), String> {
    match code {
        Some(0) if stdout.contains(DAEMON_VERSION_MARKER) => Ok(()),
        Some(0) => Err(format!(
            "内置后台服务能启动，但它不是 P-Pass 的 daemon（--version 输出：{}）",
            stdout.trim().chars().take(120).collect::<String>()
        )),
        Some(other) => Err(format!("内置后台服务跑不起来（--version 退出码 {other}）")),
        None => Err("内置后台服务没有在预期时间内响应 --version".into()),
    }
}

/// DESK-29 (#268)：注册开机自启**之前**，先确认这个 sidecar 真的能跑。
///
/// 为什么不能只看 `is_file()`（改之前唯一的守卫）：**0 字节的文件
/// `is_file()` 返回 true**。杀毒软件把未签名的 exe 掏空、安装/更新写到一半
/// 被打断、开发机上的构建 stub——任何一种都会让一个跑不起来的文件被写进
/// 开机自启，**覆盖掉原来那条好的**，而向导报告"已启动"。用户的备份从此
/// 不再自动运行，且他不会知道。
///
/// 判法选的是「**真的跑一次 `--version`**」而不是「查文件大小」：
/// 前者直接回答"能不能跑"这个问题本身，后者只是个代理指标，挡不住
/// 「非零但坏掉」。前置条件是现成的——daemon 的 `--version` 有实现
/// （`crates/daemon/src/cli.rs`）也有集成测试守着（`cli_flow.rs`）。
///
/// ⚠️ Windows 上 release 的 daemon 是 GUI 子系统（`main.rs` 顶部的
/// `windows_subsystem`），不会分配控制台，所以不闪窗；**debug 构建是
/// console 子系统，可能闪一下**。要彻底消掉得用 `CREATE_NO_WINDOW`，那是
/// 平台专属 API，会往本文件再加一处 cfg——而 #211 正在往外搬这些，不加。
fn verify_sidecar_runs(sidecar: &std::path::Path) -> Result<(), String> {
    let mut child = std::process::Command::new(sidecar)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        // 0 字节文件就死在这一步：CreateProcess 直接拒绝
        // （Windows 错误 193「不是有效的 Win32 应用程序」）。
        .map_err(|e| format!("内置后台服务跑不起来（{e}）：{}", sidecar.display()))?;

    let deadline = std::time::Instant::now() + SIDECAR_PROBE_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return sidecar_probe_verdict(None, "");
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(e) => return Err(format!("等不到内置后台服务的探活结果（{e}）")),
        }
    }
    // 已经退出了，这一步立即返回。`--version` 的输出只有一行，塞不满管道。
    let out = child
        .wait_with_output()
        .map_err(|e| format!("读不到内置后台服务的探活输出（{e}）"))?;
    sidecar_probe_verdict(out.status.code(), &String::from_utf8_lossy(&out.stdout))
}

/// Install the bundled daemon as a resident service (T-040 autostart:
/// launchd/registry — starts now, at every boot, and restarts on
/// crash). Falls back to a one-shot spawn if registration fails, so
/// the wizard never dead-ends. 基础服务不该手动启动、不该会停。
#[tauri::command]
fn start_daemon() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let sidecar = exe
        .parent()
        .ok_or("no parent dir")?
        .join(platform::adapter().daemon_executable_name());
    if !sidecar.is_file() {
        return Err(format!("找不到内置后台服务：{}", sidecar.display()));
    }
    // DESK-29 (#268)：**先探活再注册**。顺序是这条修复的全部要害——
    // 探不过就在这里返回，`install_autostart` 根本不会被调到，所以用户
    // 原来那条好的开机自启键**不会被覆盖**。
    //
    // 也不走下面那条 "注册失败就直接 spawn" 的兜底：一个跑不起来的文件，
    // spawn 也一样跑不起来，兜底只会把错误掩成另一种错误。
    verify_sidecar_runs(&sidecar)?;
    match platform::adapter().install_autostart(&sidecar) {
        // LaunchAgent RunAtLoad+KeepAlive: starts immediately, survives
        // crashes and reboots.
        Ok(()) => Ok("resident".into()),
        Err(e) => {
            // Fall back to a one-shot spawn — still usable this session.
            std::process::Command::new(&sidecar)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .stdin(std::process::Stdio::null())
                .spawn()
                .map_err(|e2| format!("注册服务失败（{e}）且直接启动也失败（{e2}）"))?;
            Ok(format!("oneshot: {e}"))
        }
    }
}

/// The last non-empty line written by the sidecar to the LaunchAgent stderr
/// log. The plist names the log location; if it is absent or unreadable, do
/// not guess a path or invent a failure reason.
fn daemon_startup_stderr_from(plist: &std::path::Path) -> Option<String> {
    let plist = std::fs::read_to_string(plist).ok()?;
    let (_, stderr_path) = daemon_logs::parse_plist_log_paths(&plist);
    let stderr = daemon_logs::tail(std::path::Path::new(stderr_path.as_deref()?), 64 * 1024)?;
    stderr
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .map(str::to_owned)
}

/// The wizard asks only after its existing readiness wait has elapsed. This
/// exposes the daemon's own stderr unchanged, so the UI can explain known
/// failures without replacing actionable diagnostic text.
#[tauri::command]
fn daemon_startup_error() -> Option<String> {
    daemon_startup_stderr_from(&daemon_logs::plist_path())
}

/// Stop the resident service the way a user means it: unregister the
/// autostart entry FIRST (so launchd won't respawn it), then ask the
/// running daemon to shut down. "能优雅退出"与"崩溃自动恢复"必须并存
/// (用户裁决 2026-07-31).
#[tauri::command]
fn stop_daemon() -> Result<(), String> {
    // 1) Unregister first — otherwise KeepAlive revives it immediately.
    let _ = platform::adapter().uninstall_autostart();
    // 2) Best-effort: kill the bundled daemon process. launchctl bootout
    //    (inside uninstall_autostart) already stopped the managed one;
    //    this also covers a one-shot fallback spawn.
    // QA-09 迁移（#211）：best-effort —— 杀不掉也继续（原来两个分支也是
    // 直接丢结果）。区别在于「什么退出码算进程本来就没在跑」这条判据
    // 现在只有一份、在 platform 里，不再是三个调用点各抄一遍。
    let _ = platform::adapter().kill_daemon_process();
    Ok(())
}

/// W1 (2026-08-26 real-box run): the updater's downloadAndInstall() was
/// failing on Windows because `ppf-daemon.exe` — a resident background
/// process the user never explicitly stopped (closing the main window
/// only hides it to tray, by design; see the on_window_event handler
/// below) — kept the installer from overwriting its own file. Same
/// class of bug as the manual-reinstall report ("退出desktop app主进程，
/// 有后台进程，无法覆盖安装"). Unlike stop_daemon(), this must NOT
/// touch autostart registration — the update is expected to succeed
/// and the daemon should come back exactly as before, not require the
/// user to re-run the wizard. Frontend calls this before
/// update.downloadAndInstall() and calls resume_daemon_after_update()
/// after a successful install (see App.svelte checkForUpdate()).
/// Best-effort: NOT finding a running daemon is not an error (nothing
/// to pause), and this must never block the update attempt itself —
/// downloadAndInstall() still runs even if this errors, so a stuck
/// pause degrades to the pre-existing failure mode (caught, surfaced
/// with a human-readable hint) instead of blocking updates entirely.
#[tauri::command]
fn pause_daemon_for_update() -> Result<(), String> {
    // QA-09 迁移（#211）：best-effort —— 杀不掉也继续（原来两个分支也是
    // 直接丢结果）。区别在于「什么退出码算进程本来就没在跑」这条判据
    // 现在只有一份、在 platform 里，不再是三个调用点各抄一遍。
    let _ = platform::adapter().kill_daemon_process();
    Ok(())
}

/// Counterpart to pause_daemon_for_update(): re-spawn the (now updated
/// on disk) daemon after the installer finishes, one-shot (no
/// autostart touch — it was never unregistered). Best-effort; the
/// frontend degrades to "restart the app" guidance if this fails,
/// rather than silently leaving the daemon down after an update the
/// user believes succeeded.
#[tauri::command]
fn resume_daemon_after_update() -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let sidecar = exe
        .parent()
        .ok_or("no parent dir")?
        .join(platform::adapter().daemon_executable_name());
    if !sidecar.is_file() {
        return Err(format!("找不到内置后台服务：{}", sidecar.display()));
    }
    std::process::Command::new(&sidecar)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .stdin(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("重新启动后台服务失败：{e}"))?;
    Ok(())
}

/// DAE-04: 桌面壳更新后手动重启后台服务——杀掉当前运行的旧 daemon 进程，
/// 靠 launchd KeepAlive（SuccessfulExit=false，crates/platform/src/macos.rs
/// 注释：崩溃/被杀照样复活）自动拉起磁盘上已是新版本的同一个文件。
/// 与 stop_daemon 相反：本命令**绝不碰 autostart 注册**（uninstall 会
/// 阻止复活）——注册从头到尾没动过，这正是设计要点。体面退出（exit 0）
/// 反而不会被复活，所以必须是真的"杀"（信号终止），不走 step_down 那套
/// 版本协商。Windows 的 autostart 是普通 Run key、没有 KeepAlive 复活
/// 语义——杀掉后显式重新拉起一次（start_daemon 的一次性 spawn 分支，
/// 不注册 autostart）。
/// 杀完轮询 status 确认进程复活且版本号确实变了（12s 超时，超时报错，
/// 不能无限等）——这是 Clash Verge Rev #5451「报告升级成功但实际没换好」
/// 的教训：验证失败必须明说，不能沉默假装成功。
#[tauri::command]
fn restart_daemon_process() -> Result<Value, String> {
    // 1) 杀前读当前 daemon 版本——复活后拿它跟新版本对比。
    let old_version = ipc::DaemonHandle::discover()
        .and_then(|d| d.call("status", json!({})))
        .ok()
        .and_then(|v| {
            v.get("version")
                .and_then(|x| x.as_str())
                .map(str::to_string)
        });
    // 2) 杀进程——照抄 stop_daemon 的 kill 逻辑（同款 pkill/taskkill），
    //    但绝不做任何 uninstall_autostart。
    // QA-09 迁移（#211）：这处**认真判错**（另两个调用点是 best-effort）。
    // 「进程本来就没在跑」不是失败——判据在 platform 里，各系统一份
    // （unix 的 pkill 退出码 1 / Windows 的 taskkill 128）。DESK-25 (#208)
    // 就是因为这条判据被抄散、其中一处没判，把「没杀掉」当成杀成功、
    // 紧接着去 spawn 第二个 daemon 才出的事。
    platform::adapter()
        .kill_daemon_process()
        .map_err(|e| format!("杀掉旧后台服务进程失败：{e}"))?;

    // 3) 被杀之后系统会不会自己把它拉回来，取决于常驻方式：
    //    LaunchAgent 的 KeepAlive 会（macOS），Run key 不会（Windows /
    //    Linux）——后者必须显式重新拉起一次（一次性 spawn，不碰 autostart
    //    注册，注册从头到尾没动过，这正是本命令的设计要点）。
    //
    //    ⚠️ 这一句在 Linux 上是**行为改变**，已在 PR 里登记：迁移前
    //    Linux 走的是原来那个 unix 分支、杀完不拉起，然后下面那个 12 秒
    //    轮询必然超时报错（Linux 没有任何东西会复活它）。桌面壳在 Linux
    //    上不是发布形态，但既然改了就写明，不混在"纯搬家"里带过去。
    if platform::adapter().service_mode() == platform::ServiceMode::UserAutostart {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let sidecar = exe
            .parent()
            .ok_or("no parent dir")?
            .join(platform::adapter().daemon_executable_name());
        if !sidecar.is_file() {
            return Err(format!("找不到内置后台服务：{}", sidecar.display()));
        }
        std::process::Command::new(&sidecar)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .stdin(std::process::Stdio::null())
            .spawn()
            .map_err(|e| format!("重启后台服务失败：{e}"))?;
    }
    // 4) 轮询 status 直到复活（每 500ms，最长 12s——实测信号杀 4~5s
    //    复活，12s 预算充裕；超时报错，绝不无限等）。
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(12);
    let new_version = loop {
        if let Ok(v) = ipc::DaemonHandle::discover().and_then(|d| d.call("status", json!({}))) {
            break v
                .get("version")
                .and_then(|x| x.as_str())
                .map(str::to_string);
        }
        if std::time::Instant::now() >= deadline {
            return Err(
                "后台服务被杀后没能自动重启（系统没有把它拉起来）。请重启电脑，或手动点「启动后台服务」。"
                    .into(),
            );
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    };
    Ok(restart_outcome(
        old_version.as_deref(),
        new_version.as_deref(),
    ))
}

/// DAE-04: 组装重启结果（纯函数，单测覆盖）。`changed=true` 才是真成功
/// （进程复活且版本号真的变了）；版本没变 = 磁盘上的服务文件其实没更新，
/// 前端必须明说失败，不能假装成功。
fn restart_outcome(old_version: Option<&str>, new_version: Option<&str>) -> Value {
    json!({
        "old_version": old_version,
        "new_version": new_version,
        "changed": match (old_version, new_version) {
            // 复活了但版本没变 → 文件没更新，不算成功。
            (Some(old), Some(new)) => old != new,
            // 杀前没读到（服务本来就没在跑）或杀后读到——重启本身有进展。
            _ => new_version.is_some(),
        },
    })
}

/// DESK-10：诊断包由**桌面壳本地组装**，不是 daemon 的 IPC 方法——
/// daemon 起不来时这个按钮必须照样工作，那正是最需要日志的场景。
/// daemon 活着时再附加它能提供的那三份（diag / devices / audit）；
/// 不可达时包里放 `daemon-unreachable.txt` 说明，其余照常收集。
/// 落盘位置与文件名沿用 daemon 原来的 `<库目录>/ppf-logs.zip`（验收人
/// 已经习惯了，不动）。
#[tauri::command]
fn export_logs_bundle() -> Result<Value, String> {
    let env = ExportEnv {
        platform_dir: platform::adapter().data_dir(),
        home: daemon_logs::home_dir(),
        plist: daemon_logs::plist_path(),
    };
    // daemon 可达就把它那三份要过来（它写出来的 zip 先整份读进内存，
    // 之后才允许覆盖同名文件）；不可达只记原因，收集继续。
    // DESK-31：版本号在 status 那一步就拿定了，必须独立于「三份日志要不
    // 要得到」传下去——logs.export 被拒 / zip 读不出时，包里印的仍是在线
    // 服务自报的版本，不是 App 自带 sidecar 的版本。
    let daemon = match ipc::DaemonHandle::discover() {
        Ok(handle) => {
            let version = handle
                .call("status", json!({}))
                .ok()
                .and_then(|v| v["version"].as_str().map(str::to_string));
            let logs =
                daemon_entries_from_logs_export(handle.call("logs.export", json!({})), |zip| {
                    daemon_logs::read_zip_entries(std::path::Path::new(zip))
                        .map_err(|e| format!("后台服务的日志包读不出来：{e}"))
                });
            match logs {
                Ok(entries) => DaemonCollection::Complete(DaemonParts { version, entries }),
                Err(reason) => DaemonCollection::LogsUnavailable { version, reason },
            }
        }
        // 版本号仍然要有：直接问内置的服务程序自己（真机事故里正是
        // `ppf-daemon --version` 一句话拿到了真相）。
        Err(e) => DaemonCollection::Unreachable(e),
    };
    assemble_export(&env, daemon, sidecar_daemon_version)
}

/// 收集时需要知道的几个目录（测试注入 tempdir——绝不碰真实照片库/真实
/// LaunchAgent plist）。
struct ExportEnv {
    /// 平台数据目录（config.toml 在这里）。
    platform_dir: std::path::PathBuf,
    /// 家目录（脱敏基准）。
    home: std::path::PathBuf,
    /// LaunchAgent plist（日志路径的唯一真相）。
    plist: std::path::PathBuf,
}

/// daemon 活着时它能给的那部分。
struct DaemonParts {
    version: Option<String>,
    entries: Vec<(String, Vec<u8>)>,
}

/// daemon 收集结果的三态（DESK-31）。`LogsUnavailable` 与 `Unreachable`
/// 必须分开：前者服务活着、只是三份日志没拿到，versions.txt 印的是
/// **在线服务自报版本**；后者服务压根没起来，才退回 sidecar 版本。
enum DaemonCollection {
    /// discover() 失败：后台服务压根没起来（DESK-10 的不可达分支）。
    Unreachable(String),
    /// 服务在线（version 已拿到或为 None），但 diag / devices / audit
    /// 三份没拿到。version 独立于日志获取成败——这是本卡的修复点。
    LogsUnavailable {
        version: Option<String>,
        reason: String,
    },
    /// 三份日志完整拿到（version 是服务自报版本，旧 daemon 可能 None）。
    Complete(DaemonParts),
}

/// logs.export 的 IPC 结果 → 三份日志条目。两条失败路径——应答被拒、
/// zip 读不出——都在这一步落成 Err(String)，版本号的去留由调用方决定。
/// 单独成函数，是为了让两条分支都能在不起真 daemon 的情况下被单测喂到。
fn daemon_entries_from_logs_export(
    export: Result<serde_json::Value, String>,
    read_zip: impl FnOnce(&str) -> Result<Vec<(String, Vec<u8>)>, String>,
) -> Result<Vec<(String, Vec<u8>)>, String> {
    match export {
        Ok(v) => {
            let daemon_zip = v["zip"].as_str().unwrap_or_default().to_string();
            read_zip(&daemon_zip)
        }
        Err(e) => Err(format!("后台服务拒绝了 logs.export：{e}")),
    }
}

/// 组装并落盘。**daemon 那部分不是失败路径**——它只是少了三份文件、
/// 多一份说明 txt，zip 照出。这个函数里一行 `return Err` 都不能因为
/// daemon 不可达而触发（DESK-10 的核心）。
fn assemble_export(
    env: &ExportEnv,
    daemon: DaemonCollection,
    sidecar_version: impl Fn() -> Option<String>,
) -> Result<Value, String> {
    let home = env.home.display().to_string();
    // 日志路径：只从 plist 读，不硬编码 ~/Library/Logs。
    let plist = std::fs::read_to_string(&env.plist).ok();
    let (out_path, err_path) = plist
        .as_deref()
        .map(daemon_logs::parse_plist_log_paths)
        .unwrap_or((None, None));

    let mut inputs = daemon_logs::BundleInputs {
        home: home.clone(),
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        plist_found: plist.is_some(),
        config_toml: std::fs::read_to_string(env.platform_dir.join("config.toml")).ok(),
        stdout_tail: out_path
            .as_deref()
            .and_then(|p| daemon_logs::tail(std::path::Path::new(p), 256 * 1024)),
        stderr_tail: err_path
            .as_deref()
            .and_then(|p| daemon_logs::tail(std::path::Path::new(p), 256 * 1024)),
        stdout_path: out_path,
        stderr_path: err_path,
        // DIAG-B1：daemon 自己的固定位置日志，不依赖 plist。
        persistent_log_tail: platform::adapter()
            .default_log_file(&env.platform_dir)
            .and_then(|p| daemon_logs::tail(&p, 1024 * 1024)),
        ..Default::default()
    };
    match daemon {
        DaemonCollection::Complete(parts) => {
            inputs.daemon_version = parts.version;
            inputs.daemon_entries = parts.entries;
        }
        // DESK-31：服务在线、日志没拿到——版本用在线自报的，不退回
        // sidecar；reachable 不是 no，单独写 daemon-logs-unavailable.txt。
        DaemonCollection::LogsUnavailable { version, reason } => {
            inputs.daemon_version = version;
            inputs.daemon_logs_unavailable = Some(reason);
        }
        DaemonCollection::Unreachable(reason) => {
            inputs.daemon_unreachable = Some(reason);
            inputs.daemon_version = sidecar_version();
        }
    }

    // 库目录：config 里的 data_dir 优先（daemon 就是往那儿写 ppf-logs.zip
    // 的），没有则退回平台数据目录。
    let data_dir = ipc::read_config_data_dir(&env.platform_dir)
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| env.platform_dir.clone());
    let zip_path = data_dir.join("ppf-logs.zip");
    let entries = daemon_logs::build_bundle(&inputs);
    daemon_logs::write_zip(&zip_path, &entries)?;
    Ok(json!({
        "zip": zip_path.display().to_string(),
        "daemon_reachable": inputs.daemon_unreachable.is_none(),
    }))
}

/// 内置服务程序自报版本（daemon 不可达时的版本来源）。取不到 → None，
/// 绝不因此让导出失败。
fn sidecar_daemon_version() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let sidecar = exe
        .parent()?
        .join(platform::adapter().daemon_executable_name());
    if !sidecar.is_file() {
        return None;
    }
    let out = std::process::Command::new(&sidecar)
        .arg("--version")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!text.is_empty()).then_some(text)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // DESK-24 (#173)：数据目录搬家，排在**一切**读 data dir 的动作之前——
    // 包括 setup 里的 start_event_stream（它会走 token_candidates() →
    // data_dir()）。搬家是幂等的：daemon 那边多半已经在登录时搬过了，
    // 这里再调一次只会得到「无遗留位置需要搬迁」。
    //
    // 桌面壳为什么也要调：升级后用户先开 App、daemon 还没被拉起来的那条
    // 路径上，第一个读 data dir 的人是它。
    //
    // ⚠️ 桌面壳没有日志落盘（release 是 GUI 子系统，stderr 无处可去），
    // 所以这里的 eprintln 只在 `just dev-desktop` 时看得见。**搬家的权威
    // 记录在 daemon 日志里**，那边有 DedupGuard 落盘。
    {
        use platform::PlatformAdapter as _;
        let outcome = platform::adapter().migrate_legacy_data_dir();
        if !outcome.is_quiet() {
            eprintln!("{outcome}");
        }
    }

    tauri::Builder::default()
        // DESK-21：单实例守卫必须是**第一个**注册的插件——它要在其余插件和
        // setup 跑起来之前就判定「我是不是第二个」，晚注册就白费了。
        //
        // 真机复现（2026-09-18，已安装的 0.4.0-test.5）：连着启动两次，
        // p-pass-desktop 进程从 0 → 1 → 2，两个都带标题为 P-Pass 的窗口。
        // 所以这不是静态分析的猜测，是实测的缺陷。
        //
        // 回调里把已有窗口 show + focus：第二次启动的语义应当是「把我已经
        // 开着的那个拿到前面来」，而不是静默什么都不做（那样用户会以为
        // 双击没生效，继续双击）。
        //
        // 不加任何平台 cfg：这个插件三个桌面平台都有实现，且整个 crate 自带
        // 那条排除 android / ios 的顶层平台断言，
        // 移动端根本不编译它。macOS 上系统本来就保证单实例，多这层守卫
        // 无害；写成平台分叉反而要往 crates/platform/ 加东西（B.2）。
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            if let Some(win) = app.get_webview_window("main") {
                // 三步缺一不可，实测得来的：
                //   unminimize —— 窗口被最小化时，单靠 show + set_focus
                //     **恢复不了**（真机实测：再启动一次之后 IsIconic 仍为
                //     true、前台窗口也不是它）。show 只管「隐藏→可见」，
                //     不管「最小化→还原」。
                //   show       —— 关窗即隐藏到托盘（DESK-23）之后要靠它。
                //   set_focus  —— 恢复可见之后还得真正拿到前台。
                let _ = win.unminimize();
                let _ = win.show();
                let _ = win.set_focus();
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            daemon_call,
            daemon_online,
            start_event_stream,
            wizard_state,
            power_hint,
            open_power_settings,
            disable_auto_sleep,
            write_config,
            start_daemon,
            daemon_startup_error,
            stop_daemon,
            pause_daemon_for_update,
            resume_daemon_after_update,
            restart_daemon_process,
            export_logs_bundle,
            allow_media_scope
        ])
        .setup(|app| {
            // IPC-02: 启动即订阅——daemon 事件驱动 UI（扫码即时切弹窗、
            // 备份落地即时刷新），不依赖前端渲染时序。
            start_event_stream(app.handle().clone());
            let show = MenuItem::with_id(app, "show", "打开 P-Pass", true, None::<&str>)?;
            let stop = MenuItem::with_id(app, "stop", "停止后台服务", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 App", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &stop, &quit])?;
            // ICON-01: 托盘用 beast 全实线纯黑版 + 模板标记——macOS 系统按
            // 深浅色自动反色（碳纹版 22px 会糊，模板图标不渲染颜色）。
            let tray_icon =
                tauri::image::Image::from_bytes(include_bytes!("../icons/tray-icon.png"))
                    .expect("tray icon bytes");
            TrayIconBuilder::with_id("main")
                .icon(tray_icon)
                .icon_as_template(platform::adapter().tray_icon_is_template())
                .menu(&menu)
                // DESK-18: 左键出菜单是 macOS 的习惯；Windows 上左键该打开
                // 主窗口（下面的 on_tray_icon_event 负责），右键才出菜单。
                // QA-09 迁移（#211）：这条习惯从 cfg! 变成了 platform 上的
                // 一个具名能力——`is_macos()` 只是把分叉挪个地方，说不出
                // 为什么要分叉；`tray_shows_menu_on_left_click` 说得出。
                .show_menu_on_left_click(platform::adapter().tray_shows_menu_on_left_click())
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button,
                        button_state,
                        ..
                    } = event
                    {
                        if tray_left_click_opens_window(
                            button,
                            button_state,
                            platform::adapter().tray_shows_menu_on_left_click(),
                        ) {
                            if let Some(win) = tray.app_handle().get_webview_window("main") {
                                // DESK-28：unminimize 不能省——窗口被最小化时
                                // show() 恢复不了它（#170 真机实测：只做
                                // show + set_focus 之后 IsIconic 仍为 true）。
                                // show 管「隐藏→可见」，unminimize 管
                                // 「最小化→还原」，是两件独立的事。
                                let _ = win.unminimize();
                                let _ = win.show();
                                let _ = win.set_focus();
                            }
                        }
                    }
                })
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(win) = app.get_webview_window("main") {
                            // DESK-28：与左键回调同一组三步，理由同上。
                            // 这条路径（右键 → 显示）比左键更常用，漏了
                            // unminimize 的话最小化的窗口点了没反应。
                            let _ = win.unminimize();
                            let _ = win.show();
                            let _ = win.set_focus();
                        }
                    }
                    "stop" => {
                        let _ = stop_daemon();
                    }
                    // Closing the App window只是隐藏；退出 App 不停后台服务
                    // （备份继续）——停服务要显式点"停止后台服务".
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window hides to tray; the tray quit item exits.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
                // DESK-23 (#172)：Windows 上点 X 就是退出，是强预期。藏到
                // 托盘却不说一声，用户会以为备份已经停了。
                //
                // 这里**只发事件，不做判断**——要不要弹、弹过没有、当前是不是
                // Windows，全交给前端。理由有两条：
                //   1. 「已提示过」是 UI 偏好，它唯一合法的落点是前端的
                //      localStorage。卡面禁止新造文件，而桌面壳其余的持久化
                //      通道要么会被 write_config 整体重写（config.toml），
                //      要么根本是 daemon 的配置（#172 里逐条核过）。
                //   2. 平台判断放前端就不用在本文件再加一处 cfg——#211 正在
                //      往外搬这些，别一边搬一边添。
                //
                // hide() 与 prevent_close() 留在 Rust 不动是刻意的：前端万一
                // 没注册上监听，最坏只是**少提示一次**，关窗行为不会退化成
                // 真退出。错误方向是「提示丢失」，不是「程序没了」。
                let _ = window.emit("hidden-to-tray", ());
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// DESK-18：左键点托盘该不该打开主窗口。
///
/// Windows 习惯：左键 = 打开应用主窗口，右键才出菜单。
/// macOS 习惯：左键 = 出菜单（由 `show_menu_on_left_click` 负责），
/// 所以 macOS 这里必须返回 false，否则会既弹菜单又开窗口。
///
/// 只认 `Up`：按下和抬起都会各来一个事件，两个都响应就会开两次窗口。
///
/// 抽成纯函数是刻意的——托盘点击在 CI 里没法模拟，但这个判定可以在**任何**
/// 平台上单测。平台差异由调用方传进来，于是两个平台的分支在每次构建里都被
/// 编译和检查，而不是只编译当前平台那一半。
///
/// QA-09 迁移（#211）：参数从「是不是 macOS」改名成「这个系统左键出不出
/// 菜单」——判定依据的是**行为**，不是系统的名字。调用方传的现在是
/// `platform::adapter().tray_shows_menu_on_left_click()`。
fn tray_left_click_opens_window(
    button: MouseButton,
    state: MouseButtonState,
    menu_on_left_click: bool,
) -> bool {
    !menu_on_left_click && button == MouseButton::Left && state == MouseButtonState::Up
}

#[cfg(test)]
mod tests {
    use super::*;

    /// DESK-28 回归锁：**每一个把窗口拉回来的入口都必须先 unminimize**。
    ///
    /// 判据依据是 #170 的真机实测：窗口最小化时只做 `show()` + `set_focus()`
    /// 恢复不了它（`IsIconic` 仍为 true），补上 `unminimize()` 才行。`show`
    /// 管「隐藏 → 可见」，`unminimize` 管「最小化 → 还原」，两件独立的事。
    ///
    /// 为什么是源码扫描：托盘点击在 CI 里模拟不了（也不在我能驱动的范围内），
    /// 但「这三行必须成组出现」这条约束可以在**任何平台**锁住——包括
    /// ci-desktop 的 ubuntu lane，那是本仓今天唯一会跑的 lane（见 #164）。
    ///
    /// #167 当初只补了托盘左键那一处、漏了右键菜单的「显示」项，就是因为
    /// 没有这样一条门禁。
    #[test]
    fn every_window_restore_unminimizes_first() {
        let src = include_str!("lib.rs");
        // 判据在运行时拼，避免这段源码自己命中自己（#168 踩过一次）。
        let show = format!("let _ = win.{}();", "show");
        let unmin = format!("win.{}()", "unminimize");

        let lines: Vec<&str> = src.lines().collect();
        let mut checked = 0usize;
        for (n, line) in lines.iter().enumerate() {
            if !line.contains(&show) {
                continue;
            }
            // 往前看几行够了：三步是紧挨着写的（中间只隔注释）。
            let from = n.saturating_sub(8);
            let preceding = lines[from..n].join("\n");
            assert!(
                preceding.contains(&unmin),
                "lib.rs:{} 处把窗口 show 出来但前面没有 unminimize——\
                 窗口被最小化时这里会点了没反应（DESK-28 / #222）。\
                 三步顺序：unminimize -> show -> set_focus。",
                n + 1
            );
            checked += 1;
        }
        // 防恒真式：今天有三处入口（单实例回调、托盘左键、托盘菜单「显示」）。
        // 少于三处说明判据没匹配上，或者有入口被删了——两种都该看一眼。
        assert!(
            checked >= 3,
            "应当至少扫到 3 处窗口恢复入口，实际只扫到 {checked} 处——判据可能失效了"
        );
    }

    /// DESK-19 回归锁：桌面壳不得再用 **console 子系统程序**去拉起系统 UI。
    ///
    /// `cmd.exe` 的 PE Subsystem 是 3（console，本机实测）。桌面壳自己是 GUI
    /// 子系统、手上没有控制台，所以从它里面 spawn 一个 console 程序时 Windows
    /// 会新分配一个控制台——那就是用户看到的黑窗一闪。同理 `powershell.exe`。
    ///
    /// 为什么是源码扫描而不是行为断言：闪窗只在真实的无控制台 GUI 进程里发生，
    /// `cargo test` 自己就跑在有控制台的进程里，行为上复现不出来。而"别再写
    /// console 启动器"这条约束可以在**任何平台**上锁住——包括 ci-desktop 的
    /// Linux lane，那是本仓今天唯一会跑的 lane（见 #164）。
    ///
    /// 要拉起系统 UI 就走 `tauri_plugin_opener`：它的候选命令条条带
    /// `CREATE_NO_WINDOW`，构造上不分配控制台。
    #[test]
    fn shell_never_launches_a_console_subsystem_program() {
        let src = include_str!("lib.rs");
        // QA-12 (#212)：只扫**产品代码**，在第一个 test 属性处截断。
        // 这道门禁要防的是「用户看到黑窗一闪」，而测试脚手架里用 console
        // 程序（比如建 junction 来验证软链提权契约）不面向用户、不在产品
        // 路径上。原判据比它自己的意图粗，这里把它对齐意图。
        let product = src.split("#[cfg(test)]").next().unwrap_or(src);
        // 判据字符串**必须在运行时拼**：直接写成字面量的话，这段源码自己就
        // 含有被禁的子串，扫描必然命中自己（第一版就是这么自己把自己判红的）。
        for prog in ["cmd", "cmd.exe", "powershell", "powershell.exe"] {
            let bad = format!("Command::new(\"{prog}\")");
            let bad = bad.as_str();
            assert!(
                !product.contains(bad),
                "{bad} 是 console 子系统程序，从 GUI 进程拉起它会闪黑窗（DESK-19 / #168）。
                 要打开系统页面/URL 请用 tauri_plugin_opener::open_url，它带 CREATE_NO_WINDOW。"
            );
        }
    }

    /// DESK-18 契约：左键抬起才开窗口，且 macOS 不开（那边左键出菜单）。
    /// 这四条在任何平台上都跑——托盘点击本身模拟不了，但判定可以。
    #[test]
    fn left_click_up_opens_the_window_off_macos() {
        assert!(tray_left_click_opens_window(
            MouseButton::Left,
            MouseButtonState::Up,
            false
        ));
    }

    #[test]
    fn left_click_does_not_open_on_macos_where_it_shows_the_menu() {
        assert!(!tray_left_click_opens_window(
            MouseButton::Left,
            MouseButtonState::Up,
            true
        ));
    }

    #[test]
    fn right_click_never_opens_the_window() {
        assert!(!tray_left_click_opens_window(
            MouseButton::Right,
            MouseButtonState::Up,
            false
        ));
    }

    /// 按下和抬起各来一个事件；只认 Up，否则一次点击开两次窗口。
    #[test]
    fn button_down_is_ignored_so_one_click_opens_once() {
        assert!(!tray_left_click_opens_window(
            MouseButton::Left,
            MouseButtonState::Down,
            false
        ));
    }

    /// QA-16（#326）：**向导 invoke 的是这一层，测试也必须打这一层**。
    ///
    /// 下面那条 `startup_failure_reads_the_latest_sidecar_stderr_line` 打的是
    /// 内部函数 `daemon_startup_stderr_from(plist)`；渲染进程真正调的却是
    /// `#[tauri::command] daemon_startup_error()` 这层包装。#326 的 M2 变异
    /// 把包装体强行改成 `return None`，整个 Rust 套件一条都不红——它可以
    /// 返回 None、可以读错 plist、可以被整个摘掉，没有任何测试知道。
    ///
    /// 这条测试补的正是那一段：包装层自己去找 plist（`plist_path()` →
    /// `home_dir()` → `$HOME`），所以把 HOME 指到 tempdir，在里面摆一份
    /// 真的 LaunchAgent plist 和一份真的 stderr 日志，然后**无参调用命令
    /// 本体**，断言 daemon 那行错误原样回来了。
    ///
    /// 反证：`daemon_startup_error()` 体内改成 `None` → 本测试红。
    ///
    /// ⚠️ HOME 是进程级的，cargo 的测试线程共享它，所以这里就地改、用完
    /// 还原。**全 crate 只有一条别的测试会间接读到 HOME**：
    /// `ipc::tests::candidates_include_config_data_dir` → `token_candidates_from`
    /// （ipc.rs 里那行 `env::var("HOME")`）。它不受影响——HOME 只决定候选表里
    /// `home.join("ppf-library/ipc.token")` 那一项，而它的两条断言查的是
    /// config 的 data_dir 和注入的 cfg_dir，跟 HOME 无关。
    /// 将来谁加一条**断言到 HOME 那一项**的测试，必须跟本条一起串行化
    /// （在 tests mod 里加个共享 Mutex，别退回 `--test-threads=1`）。
    #[test]
    fn the_startup_error_command_itself_surfaces_the_daemon_stderr() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();

        let logs = home.join("Library/Logs");
        std::fs::create_dir_all(&logs).unwrap();
        let stderr_log = logs.join("p-pass-daemon.err");
        let daemon_error =
            "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";
        // 尾部空行 + 前面的正常输出：命令要给出**最后一行非空**的那条。
        std::fs::write(&stderr_log, format!("starting daemon\n{daemon_error}\n\n")).unwrap();

        let agents = home.join("Library/LaunchAgents");
        std::fs::create_dir_all(&agents).unwrap();
        std::fs::write(
            agents.join("com.p-pass.daemon.plist"),
            format!(
                "<plist><dict><key>StandardErrorPath</key><string>{}</string></dict></plist>",
                stderr_log.display()
            ),
        )
        .unwrap();

        let saved_home = std::env::var_os("HOME");
        std::env::set_var("HOME", home);
        // 命令本体，无参——与渲染进程 `invoke("daemon_startup_error")` 同一条路。
        let got = daemon_startup_error();
        match saved_home {
            Some(h) => std::env::set_var("HOME", h),
            None => std::env::remove_var("HOME"),
        }

        assert_eq!(got.as_deref(), Some(daemon_error));
    }

    #[test]
    fn startup_failure_reads_the_latest_sidecar_stderr_line() {
        let tmp = tempfile::tempdir().unwrap();
        let stderr = tmp.path().join("ppf-daemon.err");
        let daemon_error =
            "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";
        std::fs::write(&stderr, format!("starting daemon\n{daemon_error}\n")).unwrap();
        let plist = tmp.path().join("com.p-pass.daemon.plist");
        std::fs::write(
            &plist,
            format!(
                "<plist><dict><key>StandardErrorPath</key><string>{}</string></dict></plist>",
                stderr.display()
            ),
        )
        .unwrap();

        assert_eq!(
            daemon_startup_stderr_from(&plist).as_deref(),
            Some(daemon_error)
        );
    }

    /// DESK-10 硬判据：**daemon 不可达时点导出也必须出 zip**，且包里有
    /// daemon 的 .err/.log 与版本号。反证做法：把 `assemble_export` 改成
    /// daemon 不可达就 `return Err`（= 退回"走 daemon IPC"的老行为），
    /// 本测试立刻变红。
    ///
    /// 全程 tempdir：假 plist + 假日志 + 假 config，不碰真实照片库、
    /// 不碰真实 LaunchAgent。
    #[test]
    fn export_bundles_logs_even_when_the_daemon_is_unreachable() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let logs = home.join("Library/Logs");
        std::fs::create_dir_all(&logs).unwrap();
        let err_log = logs.join("p-pass-daemon.err");
        // 那次真实事故的 stderr（launchd KeepAlive 重复了 8 次）。
        std::fs::write(
            &err_log,
            "Error: migration: migration 2 was previously applied but is missing in the resolved migrations\n"
                .repeat(8),
        )
        .unwrap();
        let out_log = logs.join("p-pass-daemon.log");
        std::fs::write(&out_log, format!("library {} ready\n", home.display())).unwrap();

        let plist = tmp.path().join("com.p-pass.daemon.plist");
        std::fs::write(
            &plist,
            format!(
                "<plist><dict>\n<key>StandardOutPath</key><string>{}</string>\n\
                 <key>StandardErrorPath</key><string>{}</string>\n</dict></plist>\n",
                out_log.display(),
                err_log.display()
            ),
        )
        .unwrap();

        let platform_dir = tmp.path().join("support");
        let library = tmp.path().join("library");
        std::fs::create_dir_all(&platform_dir).unwrap();
        std::fs::write(
            platform_dir.join("config.toml"),
            format!(
                "data_dir = {:?}\nbind_addr = \"0.0.0.0:41145\"\n",
                library.display()
            ),
        )
        .unwrap();

        let env = ExportEnv {
            platform_dir,
            home: home.clone(),
            plist,
        };
        let res = assemble_export(
            &env,
            DaemonCollection::Unreachable(
                "找不到运行中的 P-Pass 后台服务（ipc.token 不存在）".into(),
            ),
            || Some("0.3.0".into()),
        )
        .expect("daemon 不可达也必须出包");
        assert_eq!(res["daemon_reachable"], false);

        let zip_path = res["zip"].as_str().unwrap();
        assert_eq!(zip_path, library.join("ppf-logs.zip").display().to_string());
        let entries = daemon_logs::read_zip_entries(std::path::Path::new(zip_path)).unwrap();
        let names: Vec<&str> = entries.iter().map(|(n, _)| n.as_str()).collect();
        for want in [
            "README.txt",
            "versions.txt",
            "config-summary.txt",
            "daemon-stderr.log",
            "daemon-stdout.log",
            "daemon-unreachable.txt",
        ] {
            assert!(names.contains(&want), "缺 {want}：{names:?}");
        }
        let text: String = entries
            .iter()
            .map(|(_, b)| String::from_utf8_lossy(b).to_string())
            .collect::<Vec<_>>()
            .join("\n");
        // 复现事故：真错误必须在包里，且是原文。
        assert!(
            text.contains(
                "migration 2 was previously applied but is missing in the resolved migrations"
            ),
            "{text}"
        );
        // 版本号（App + daemon）都在。
        assert!(text.contains(env!("CARGO_PKG_VERSION")), "{text}");
        assert!(text.contains("daemon_version = 0.3.0"), "{text}");
        // 脱敏不回退：家目录不出现在包里。
        assert!(!text.contains(&home.display().to_string()), "{text}");
        assert!(text.contains("<DATA>"), "{text}");
    }

    /// daemon 活着时：它那三份原样进包，且不出现"不可达"说明文件。
    #[test]
    fn export_adds_daemon_parts_when_reachable() {
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("support");
        std::fs::create_dir_all(&platform_dir).unwrap();
        let env = ExportEnv {
            platform_dir: platform_dir.clone(),
            home: tmp.path().join("home"),
            // plist 不存在 → 如实记"未注册"，不猜 ~/Library/Logs。
            plist: tmp.path().join("missing.plist"),
        };
        let parts = DaemonParts {
            version: Some("0.4.0".into()),
            entries: vec![
                ("diag_events.json".into(), b"[]".to_vec()),
                ("devices.json".into(), b"[]".to_vec()),
                ("audit.json".into(), b"[]".to_vec()),
            ],
        };
        let res = assemble_export(&env, DaemonCollection::Complete(parts), || None).unwrap();
        assert_eq!(res["daemon_reachable"], true);
        let entries =
            daemon_logs::read_zip_entries(std::path::Path::new(res["zip"].as_str().unwrap()))
                .unwrap();
        let names: Vec<&str> = entries.iter().map(|(n, _)| n.as_str()).collect();
        for want in ["diag_events.json", "devices.json", "audit.json"] {
            assert!(names.contains(&want), "缺 {want}：{names:?}");
        }
        assert!(!names.contains(&"daemon-unreachable.txt"), "{names:?}");
        let sources = entries
            .iter()
            .find(|(n, _)| n == "log-sources.txt")
            .map(|(_, b)| String::from_utf8_lossy(b).to_string())
            .unwrap();
        assert!(sources.contains("未注册"), "{sources}");
    }

    /// DESK-31 反证（logs.export 被拒那条）：服务在线（status 自报
    /// 9.9.9-fake），但 logs.export 返回 Err——versions.txt 必须印在线
    /// 版本。修复前这条真红：版本被丢、退回 sidecar 0.3.0、reachable
    /// 印 no、还多写一份 daemon-unreachable.txt。
    #[test]
    fn export_keeps_live_version_when_logs_export_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("support");
        std::fs::create_dir_all(&platform_dir).unwrap();
        let env = ExportEnv {
            platform_dir,
            home: tmp.path().join("home"),
            plist: tmp.path().join("missing.plist"),
        };
        let collection = DaemonCollection::LogsUnavailable {
            version: Some("9.9.9-fake".into()),
            reason: "后台服务拒绝了 logs.export：模拟拒绝".into(),
        };
        // 输入构造自检：status 那一步确实已拿到在线版本。
        assert!(
            matches!(
                &collection,
                DaemonCollection::LogsUnavailable { version: Some(v), .. } if v == "9.9.9-fake"
            ),
            "status 自报版本必须在输入里"
        );
        let res = assemble_export(&env, collection, || Some("0.3.0".into()))
            .expect("日志要不到也必须出包（DESK-10）");
        // 服务起来了——daemon_reachable 不得是 no。
        assert_eq!(res["daemon_reachable"], true);
        let entries =
            daemon_logs::read_zip_entries(std::path::Path::new(res["zip"].as_str().unwrap()))
                .unwrap();
        let names: Vec<&str> = entries.iter().map(|(n, _)| n.as_str()).collect();
        assert!(
            !names.contains(&"daemon-unreachable.txt"),
            "服务在线，不许写「不可达」说明：{names:?}"
        );
        assert!(
            names.contains(&"daemon-logs-unavailable.txt"),
            "缺 daemon-logs-unavailable.txt：{names:?}"
        );
        let text: String = entries
            .iter()
            .map(|(_, b)| String::from_utf8_lossy(b).to_string())
            .collect::<Vec<_>>()
            .join("\n");
        // 核心断言：版本是在线服务自报的，不是 sidecar 的。
        assert!(text.contains("daemon_version = 9.9.9-fake"), "{text}");
        assert!(!text.contains("daemon_version = 0.3.0"), "{text}");
        // 三态措辞：不得印 no。
        assert!(text.contains("daemon_reachable = partial"), "{text}");
        assert!(!text.contains("daemon_reachable = no"), "{text}");
        // 说明文件把「在线但要不到日志」和「压根没起来」区分开。
        let note = entries
            .iter()
            .find(|(n, _)| n == "daemon-logs-unavailable.txt")
            .map(|(_, b)| String::from_utf8_lossy(b).to_string())
            .unwrap();
        assert!(note.contains("在线"), "{note}");
        assert!(note.contains("两回事"), "{note}");
    }

    /// DESK-31 反证（zip 读不出来那条）：logs.export 应答了，但 zip 读
    /// 不出——同样必须保住在线版本。与上一条是两条不同的失败路径，各
    /// 一个用例。
    #[test]
    fn export_keeps_live_version_when_daemon_zip_unreadable() {
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("support");
        std::fs::create_dir_all(&platform_dir).unwrap();
        let env = ExportEnv {
            platform_dir,
            home: tmp.path().join("home"),
            plist: tmp.path().join("missing.plist"),
        };
        let res = assemble_export(
            &env,
            DaemonCollection::LogsUnavailable {
                version: Some("9.9.9-fake".into()),
                reason: "后台服务的日志包读不出来：模拟 zip 损坏".into(),
            },
            || Some("0.3.0".into()),
        )
        .expect("日志要不到也必须出包（DESK-10）");
        assert_eq!(res["daemon_reachable"], true);
        let entries =
            daemon_logs::read_zip_entries(std::path::Path::new(res["zip"].as_str().unwrap()))
                .unwrap();
        let text: String = entries
            .iter()
            .map(|(_, b)| String::from_utf8_lossy(b).to_string())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(text.contains("daemon_version = 9.9.9-fake"), "{text}");
        assert!(!text.contains("daemon_version = 0.3.0"), "{text}");
        assert!(text.contains("daemon_reachable = partial"), "{text}");
    }

    /// DESK-31 验收 (e)：新暴露的在线版本串同样过 scrub——daemon 自报
    /// 什么我们控制不了，出包的每个字节都过同一道脱敏。
    #[test]
    fn export_scrubs_live_version_string() {
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("support");
        std::fs::create_dir_all(&platform_dir).unwrap();
        let home = tmp.path().join("home");
        let env = ExportEnv {
            platform_dir,
            home: home.clone(),
            plist: tmp.path().join("missing.plist"),
        };
        let weird_version = format!("9.9.9-fake+{}", home.display());
        let res = assemble_export(
            &env,
            DaemonCollection::LogsUnavailable {
                version: Some(weird_version),
                reason: "模拟".into(),
            },
            || None,
        )
        .unwrap();
        let entries =
            daemon_logs::read_zip_entries(std::path::Path::new(res["zip"].as_str().unwrap()))
                .unwrap();
        let text: String = entries
            .iter()
            .map(|(_, b)| String::from_utf8_lossy(b).to_string())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            !text.contains(&home.display().to_string()),
            "在线版本串不许泄漏家目录：{text}"
        );
        assert!(text.contains("<DATA>"), "{text}");
    }

    /// DESK-31 接线层：logs.export 被拒那条分支（修复前位于 lib.rs 的
    /// logs.export Err 臂）——reason 原样带出，且根本不去读 zip。
    #[test]
    fn daemon_entries_from_logs_export_rejected() {
        let err = daemon_entries_from_logs_export(Err("模拟拒绝".into()), |_| {
            panic!("logs.export 被拒时不该去读 zip")
        })
        .unwrap_err();
        assert!(err.contains("后台服务拒绝了 logs.export"), "{err}");
        assert!(err.contains("模拟拒绝"), "{err}");
    }

    /// DESK-31 接线层：zip 读不出来那条分支（修复前的 read_zip_entries
    /// Err 臂）——读 zip 的错误原样带出。
    #[test]
    fn daemon_entries_from_logs_export_zip_unreadable() {
        let err = daemon_entries_from_logs_export(
            Ok(json!({ "zip": "/tmp/fake-daemon.zip" })),
            // 生产接线里由调用方的 map_err 包上「日志包读不出来」前缀，
            // 闭包按同一契约模拟。
            |zip| {
                assert_eq!(zip, "/tmp/fake-daemon.zip");
                Err("后台服务的日志包读不出来：模拟 zip 损坏".into())
            },
        )
        .unwrap_err();
        assert!(err.contains("后台服务的日志包读不出来"), "{err}");
        assert!(err.contains("模拟 zip 损坏"), "{err}");
    }

    /// DESK-31 接线层：happy path——按应答里的 zip 路径读条目。
    #[test]
    fn daemon_entries_from_logs_export_happy_path() {
        let entries =
            daemon_entries_from_logs_export(Ok(json!({ "zip": "/tmp/fake-daemon.zip" })), |_| {
                Ok(vec![("audit.json".into(), b"[]".to_vec())])
            })
            .unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "audit.json");
    }

    // DAE-04: 版本真的变了 → changed=true（真成功，前端报「已重启」）。
    #[test]
    fn restart_outcome_marks_version_change() {
        let v = restart_outcome(Some("v0.3.3-test.1"), Some("0.3.4"));
        assert_eq!(v["changed"], true);
        assert_eq!(v["old_version"], "v0.3.3-test.1");
        assert_eq!(v["new_version"], "0.3.4");
    }

    // DAE-04: 复活但版本没变 = 磁盘上的服务文件其实没更新——必须报为
    // 未变更，前端明说失败（Clash Verge Rev #5451 的教训），不假装成功。
    #[test]
    fn restart_outcome_same_version_is_not_a_change() {
        let v = restart_outcome(Some("0.3.3"), Some("0.3.3"));
        assert_eq!(v["changed"], false);
    }

    // DAE-04: 杀前 daemon 没在跑（读到不到版本）、杀后起来了 → 也算
    // 有进展（前端报「已启动」）。
    #[test]
    fn restart_outcome_starts_an_offline_daemon() {
        let v = restart_outcome(None, Some("0.3.3"));
        assert_eq!(v["changed"], true);
        assert_eq!(v["old_version"], Value::Null);
    }

    // DAE-04: 杀后没读到版本 = 无法验证，不算成功（防御分支——轮询
    // 超时已在上游拦掉，这里兜底语义）。
    #[test]
    fn restart_outcome_without_new_version_is_not_verified() {
        let v = restart_outcome(Some("0.3.3"), None);
        assert_eq!(v["changed"], false);
        assert_eq!(v["new_version"], Value::Null);
    }

    // MOB-47 安全契约（L2 审查）：授权前校验只认「真实存在的普通文件」。
    // 目录、软链指向的目录、不存在的路径都必须拒绝——asset scope 绝不
    // 放开一个目录层（那会让同一层其它文件可被读取）。
    #[test]
    fn validate_asset_file_accepts_only_real_regular_files() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("clip.mp4");
        std::fs::write(&file, b"fake video bytes").unwrap();
        // 存在的普通文件 → 通过，且返回 canonicalized 路径。
        let canon = validate_asset_file(&file).expect("regular file must pass");
        assert!(canon.is_file());
        assert_eq!(canon, file.canonicalize().unwrap());

        // 目录 → 拒绝（这正是提权点：目录授权会让同层文件可读）。
        assert!(validate_asset_file(tmp.path()).is_err());

        // 不存在的路径 → 拒绝。
        assert!(validate_asset_file(&tmp.path().join("missing.mp4")).is_err());
    }

    // ── QA-12 (#212): MOB-47 那条契约，对这台系统能造出的每一种链接 ──
    //
    // 契约：**指向目录的链接必须被拒绝**，哪怕名字叫 `tricky.mp4`。
    // 提权点在于目录授权会让同层文件全都可读。
    //
    // #287 之前这里是三条各带 `#[cfg]` 的用例（Windows junction / Windows
    // 目录符号链接 / unix 符号链接），因为"怎么造一个指向目录的链接"每个
    // 系统不一样。现在那份系统知识搬进了 `platform::test_support`——它本来
    // 就属于那儿（架构红线 B.2），本用例因此一个平台门都不需要。
    //
    // 遍历而不是挑一种：Windows 的 junction 与目录符号链接是**两种不同的
    // 机制**，在 canonicalize 下未必一致，验一种不等于验过了。

    #[test]
    fn validate_asset_file_rejects_every_kind_of_link_to_a_directory() {
        let kinds = platform::test_support::dir_link_kinds();
        assert!(
            !kinds.is_empty(),
            "这台系统一种链接形态都没有？契约将无人验证"
        );

        for (i, kind) in kinds.iter().enumerate() {
            let tmp = tempfile::tempdir().unwrap();
            let dir = tmp.path().join("realdir");
            std::fs::create_dir_all(&dir).unwrap();
            // 名字**刻意**像个视频文件：判据不许靠扩展名放行。
            let link = tmp.path().join(format!("tricky{i}.mp4"));

            match kind.make(&dir, &link) {
                Ok(()) => assert!(
                    validate_asset_file(&link).is_err(),
                    "{} 指向目录却被放行——等于把整个目录授权出去（MOB-47 / #212）",
                    kind.name
                ),
                // 需要特权的形态建不出来 ⇒ 明确跳过并打印原因，绝不静默变绿。
                // （Windows 的目录符号链接要管理员；std 的 symlink_dir 不传
                // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE，本机实测开了
                // 开发者模式也照样建不出来。）
                Err(e) if kind.may_need_privilege => eprintln!(
                    "SKIP {}: 建链失败（需要特权）：{e}。\
                     其余形态覆盖同一条契约，用例仍然有效。",
                    kind.name
                ),
                // 不需要特权却建不出来 = 真出事了，不许当跳过混过去。
                Err(e) => panic!("{} 不需要特权却建不出来：{e}", kind.name),
            }
        }
    }

    // ── DESK-29 (#268): 探活判据 ─────────────────────────────
    //
    // 起子进程那半要真机验（见 PR 里的 Run 键前后对照）；这里锁的是
    // 「什么才算通过」。改之前唯一的守卫是 `is_file()`，而 **0 字节文件
    // is_file() 返回 true** ——于是一个跑不起来的 daemon 被写进开机自启、
    // 覆盖掉好的那条，向导还报成功。

    #[test]
    fn probe_passes_only_on_exit_zero_with_our_marker() {
        assert!(sidecar_probe_verdict(Some(0), "P-Pass daemon 0.5.7-test.1\n").is_ok());
    }

    #[test]
    fn probe_rejects_a_program_that_is_not_our_daemon() {
        // 退出码 0 但不是我们的 daemon（被换成了别的 exe）。
        let e = sidecar_probe_verdict(Some(0), "Python 3.9.13\n").unwrap_err();
        assert!(e.contains("不是 P-Pass 的 daemon"), "{e}");
    }

    #[test]
    fn probe_rejects_empty_output() {
        assert!(sidecar_probe_verdict(Some(0), "").is_err());
    }

    #[test]
    fn probe_rejects_nonzero_exit() {
        let e = sidecar_probe_verdict(Some(2), "P-Pass daemon 0.5.7-test.1").unwrap_err();
        assert!(e.contains("退出码 2"), "{e}");
    }

    /// 超时/被干掉 ⇒ 拿不到退出码 ⇒ **不许当通过**。
    /// 「没法确认」不等于「没问题」——放松这条就是静默放行。
    #[test]
    fn probe_rejects_unknown_exit_status() {
        assert!(sidecar_probe_verdict(None, "P-Pass daemon 0.5.7-test.1").is_err());
    }

    /// 本机上能找到的、真的 daemon 产物。找不到就返回 None——
    /// CI 上 `binaries/` 里放的是 0 字节 stub（ci-desktop.yml 的 "Stub sidecar"
    /// 步骤造的），所以那边天然没有。
    fn locate_real_daemon() -> Option<std::path::PathBuf> {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        [
            "binaries/ppf-daemon-x86_64-pc-windows-msvc.exe",
            "binaries/ppf-daemon-x86_64-unknown-linux-gnu",
            "binaries/ppf-daemon-aarch64-apple-darwin",
            "target/debug/ppf-daemon.exe",
            "target/debug/ppf-daemon",
        ]
        .iter()
        .map(|p| root.join(p))
        .find(|p| {
            std::fs::metadata(p)
                .map(|m| m.is_file() && m.len() > 0)
                .unwrap_or(false)
        })
    }

    /// DESK-29 (#268) E1：0 字节的 sidecar 必须被挡住。
    ///
    /// 直接对着缺陷本身：改之前唯一的守卫是 `is_file()`，而
    /// **0 字节文件 `is_file()` 返回 true** —— 所以它一路通过、被写进开机
    /// 自启、覆盖掉原来那条好的，向导还报成功。下面第一条断言把这个前提
    /// 也锁住了，免得以后有人以为"旧守卫本来就拦得住"。
    #[test]
    fn verify_rejects_a_zero_byte_sidecar() {
        let tmp = tempfile::tempdir().unwrap();
        // 一律带 .exe 后缀：不为了这个测试在本文件再加一处平台 cfg
        // （#211 正在往外搬）。Windows 上 spawn 直接被拒（不是有效的
        // Win32 程序），unix 上没有执行位同样被拒——两边都走 Err。
        let fake = tmp.path().join("ppf-daemon.exe");
        std::fs::write(&fake, b"").unwrap();

        assert!(
            fake.is_file(),
            "前提：0 字节文件 is_file() 为真，旧守卫正是这样被绕过的"
        );
        assert_eq!(std::fs::metadata(&fake).unwrap().len(), 0);

        let err = verify_sidecar_runs(&fake).unwrap_err();
        assert!(err.contains("跑不起来"), "错误信息要说清跑不起来：{err}");
    }

    /// DESK-29 (#268) E1 反证：换成**真的** daemon 必须通过。
    ///
    /// 没有这一条，上面那条可能只是「总是报错」——那样虽然挡住了坏文件，
    /// 也把所有人的开机自启一起挡死了。
    #[test]
    fn verify_accepts_a_real_daemon() {
        let Some(real) = locate_real_daemon() else {
            // 绝不静默变绿：跳过了就把原因打出来。
            eprintln!(
                "⚠️ 跳过 verify_accepts_a_real_daemon：本机找不到非空的 daemon 产物。
                 CI 上 binaries/ 里是 0 字节 stub，所以这条反证只能在有真产物的
                 开发机上跑（本轮已在 Windows 真机跑过，见 PR）。"
            );
            return;
        };
        if let Err(e) = verify_sidecar_runs(&real) {
            panic!("真 daemon 被误判成坏的（{}）：{e}", real.display());
        }
    }
}
