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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![daemon_call, daemon_online])
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
