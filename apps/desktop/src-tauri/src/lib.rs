//! P-Pass tray shell (T-041, ADR-012): zero business logic — every
//! command is a thin forward to the daemon's local IPC.

mod ipc;

use serde_json::{json, Value};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::Manager;

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

/// First-run wizard state (T-042): configured = a config.toml exists in
/// the platform data dir.
#[tauri::command]
fn wizard_state() -> Value {
    use platform::PlatformAdapter as _;
    let dir = platform::adapter().data_dir();
    json!({
        "configured": dir.join("config.toml").exists(),
        "default_dir": dir.to_string_lossy(),
    })
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

/// Open the OS power settings pane (the wizard's "fix it" action —
/// backup-time wakefulness is handled automatically by the daemon's
/// AwakeGuard; this is for users who want always-on).
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

/// Write the initial config.toml (T-042 step 1) into the platform dir.
#[tauri::command]
fn write_config(library_dir: String) -> Result<(), String> {
    use platform::PlatformAdapter as _;
    let dir = platform::adapter().data_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let config = format!(
        "data_dir = {:?}

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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            daemon_call,
            daemon_online,
            wizard_state,
            power_hint,
            open_power_settings,
            write_config,
            start_daemon
        ])
        .setup(|app| {
            let show = MenuItem::with_id(app, "show", "打开 P-Pass", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(win) = app.get_webview_window("main") {
                            let _ = win.show();
                            let _ = win.set_focus();
                        }
                    }
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
