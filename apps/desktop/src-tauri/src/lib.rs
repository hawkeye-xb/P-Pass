//! P-Pass tray shell (T-041, ADR-012): zero business logic — every
//! command is a thin forward to the daemon's local IPC.

mod daemon_logs;
mod ipc;

use serde_json::{json, Value};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
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
    use platform::PlatformAdapter as _;
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
        "platform": if cfg!(windows) { "windows" } else if cfg!(target_os = "macos") { "macos" } else { "linux" },
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
    use platform::PlatformAdapter as _;
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
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open")
            .arg("x-apple.systempreferences:com.apple.Battery-Settings.extension")
            .spawn();
    }
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("cmd")
            .args(["/C", "start", "ms-settings:powersleep"])
            .spawn();
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
#[tauri::command]
fn disable_auto_sleep() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("osascript")
            .args([
                "-e",
                "do shell script \"pmset -a sleep 0\" with administrator privileges",
            ])
            .output()
            .map_err(|e| format!("无法执行系统命令：{e}"))?;
        if out.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&out.stderr);
            if stderr.contains("User canceled") || stderr.contains("-128") {
                Err("已取消授权".into())
            } else {
                Err(format!("设置失败：{}", stderr.trim()))
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("这台电脑暂不支持一键设置，请用「去系统设置」手动关闭".into())
    }
}

/// Write the initial config.toml (T-042 step 1) into the platform dir.
#[tauri::command]
fn write_config(library_dir: String) -> Result<(), String> {
    use platform::PlatformAdapter as _;
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

/// Install the bundled daemon as a resident service (T-040 autostart:
/// launchd/registry — starts now, at every boot, and restarts on
/// crash). Falls back to a one-shot spawn if registration fails, so
/// the wizard never dead-ends. 基础服务不该手动启动、不该会停。
#[tauri::command]
fn start_daemon() -> Result<String, String> {
    use platform::PlatformAdapter as _;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let sidecar = exe.parent().ok_or("no parent dir")?.join(if cfg!(windows) {
        "ppf-daemon.exe"
    } else {
        "ppf-daemon"
    });
    if !sidecar.is_file() {
        return Err(format!("找不到内置后台服务：{}", sidecar.display()));
    }
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
    use platform::PlatformAdapter as _;
    // 1) Unregister first — otherwise KeepAlive revives it immediately.
    let _ = platform::adapter().uninstall_autostart();
    // 2) Best-effort: kill the bundled daemon process. launchctl bootout
    //    (inside uninstall_autostart) already stopped the managed one;
    //    this also covers a one-shot fallback spawn.
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("pkill")
            .args(["-f", "ppf-daemon"])
            .output();
    }
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("taskkill")
            .args(["/F", "/IM", "ppf-daemon.exe"])
            .output();
    }
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
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("pkill")
            .args(["-f", "ppf-daemon"])
            .output();
    }
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("taskkill")
            .args(["/F", "/IM", "ppf-daemon.exe"])
            .output();
    }
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
    let sidecar = exe.parent().ok_or("no parent dir")?.join(if cfg!(windows) {
        "ppf-daemon.exe"
    } else {
        "ppf-daemon"
    });
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
    #[cfg(unix)]
    {
        let out = std::process::Command::new("pkill")
            .args(["-f", "ppf-daemon"])
            .output()
            .map_err(|e| format!("杀掉旧后台服务进程失败：{e}"))?;
        // pkill 退出码 1 = 没有匹配进程（服务本来就没在跑）——不 panic，
        // 继续走轮询（launchd 会把它拉起来）。
        if !out.status.success() && out.status.code() != Some(1) {
            return Err(format!(
                "杀掉旧后台服务进程失败：pkill 退出码 {:?}",
                out.status.code()
            ));
        }
    }
    #[cfg(windows)]
    {
        let out = std::process::Command::new("taskkill")
            .args(["/F", "/IM", "ppf-daemon.exe"])
            .output()
            .map_err(|e| format!("杀掉旧后台服务进程失败：{e}"))?;
        // Windows 没有 launchd KeepAlive 复活语义——杀掉后必须显式重新
        // 拉起（start_daemon 的一次性 spawn fallback 分支）。
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let sidecar = exe.parent().ok_or("no parent dir")?.join("ppf-daemon.exe");
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
    // 3) 轮询 status 直到复活（每 500ms，最长 12s——实测信号杀 4~5s
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
    use platform::PlatformAdapter as _;
    let env = ExportEnv {
        platform_dir: platform::adapter().data_dir(),
        home: daemon_logs::home_dir(),
        plist: daemon_logs::plist_path(),
    };
    // daemon 可达就把它那三份要过来（它写出来的 zip 先整份读进内存，
    // 之后才允许覆盖同名文件）；不可达只记原因，收集继续。
    let daemon = match ipc::DaemonHandle::discover() {
        Ok(handle) => {
            let version = handle
                .call("status", json!({}))
                .ok()
                .and_then(|v| v["version"].as_str().map(str::to_string));
            match handle.call("logs.export", json!({})) {
                Ok(v) => {
                    let daemon_zip = v["zip"].as_str().unwrap_or_default().to_string();
                    match daemon_logs::read_zip_entries(std::path::Path::new(&daemon_zip)) {
                        Ok(entries) => Ok(DaemonParts { version, entries }),
                        Err(e) => Err(format!("后台服务的日志包读不出来：{e}")),
                    }
                }
                Err(e) => Err(format!("后台服务拒绝了 logs.export：{e}")),
            }
        }
        // 版本号仍然要有：直接问内置的服务程序自己（真机事故里正是
        // `ppf-daemon --version` 一句话拿到了真相）。
        Err(e) => Err(e),
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

/// 组装并落盘。**daemon 那部分是 `Result`，Err 不是失败路径**——它只是
/// 少了三份文件、多一份 `daemon-unreachable.txt`，zip 照出。这个函数里
/// 一行 `return Err` 都不能因为 daemon 不可达而触发（DESK-10 的核心）。
fn assemble_export(
    env: &ExportEnv,
    daemon: Result<DaemonParts, String>,
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
        ..Default::default()
    };
    match daemon {
        Ok(parts) => {
            inputs.daemon_version = parts.version;
            inputs.daemon_entries = parts.entries;
        }
        Err(reason) => {
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
    let sidecar = exe.parent()?.join(if cfg!(windows) {
        "ppf-daemon.exe"
    } else {
        "ppf-daemon"
    });
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
    tauri::Builder::default()
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
                .icon_as_template(cfg!(target_os = "macos"))
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(win) = app.get_webview_window("main") {
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
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

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
            Err("找不到运行中的 P-Pass 后台服务（ipc.token 不存在）".into()),
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
        let res = assemble_export(&env, Ok(parts), || None).unwrap();
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

    // MOB-47 安全契约：软链可指向目录——canonicalize 后必须仍判普通文件，
    // 不能用「resolve 前是文件」这类假判据放行。
    #[cfg(unix)]
    #[test]
    fn validate_asset_file_rejects_symlink_to_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("realdir");
        std::fs::create_dir_all(&dir).unwrap();
        let link = tmp.path().join("tricky.mp4");
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        // 软链指向目录 → 即使按名字像个文件，也必须拒绝。
        assert!(validate_asset_file(&link).is_err());
    }
}
