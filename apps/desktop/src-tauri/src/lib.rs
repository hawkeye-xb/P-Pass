//! P-Pass tray shell (T-041, ADR-012): zero business logic — every
//! command is a thin forward to the daemon's local IPC.

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
    let sidecar = exe
        .parent()
        .ok_or("no parent dir")?
        .join(if cfg!(windows) { "ppf-daemon.exe" } else { "ppf-daemon" });
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
            stop_daemon,
            restart_daemon_process
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
            let tray_icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray-icon.png"))
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
}
