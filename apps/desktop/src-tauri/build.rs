// #1120：网页能调的应用命令逐个声明（Tauri 2 官方机制 `AppManifest::commands`）。
//
// 列在这里的命令会生成 `allow-<命令>` 权限，网页只能调用 capabilities 里明确
// 授权的那些；没列的命令一律调不到。这份名单、`lib.rs` 的 `generate_handler!`、
// `capabilities/default.json` 三者必须一致——由 `lib.rs` 的
// `command_lists_agree` 测试钉住，加命令只改一处会红。
const APP_COMMANDS: &[&str] = &[
    "daemon_status",
    "daemon_low_space_ack",
    "daemon_pairing_start",
    "daemon_pairing_pending",
    "daemon_pairing_confirm",
    "daemon_devices_list",
    "daemon_device_watermarks",
    "daemon_device_revoke",
    "daemon_device_rename",
    "daemon_device_folder",
    "daemon_audit_list",
    "daemon_timeline_page",
    "daemon_thumb_get",
    "daemon_asset_original",
    "daemon_asset_path",
    "service_state",
    "wizard_state",
    "platform_ux",
    "update_failure_key",
    "power_hint",
    "open_power_settings",
    "disable_auto_sleep",
    "write_config",
    "set_library_dir",
    "start_daemon",
    "daemon_startup_error",
    "stop_daemon",
    "pause_daemon_for_update",
    "pending_shell_version",
    "relaunch_shell",
    "self_heal_daemon",
    "resume_after_failed_update",
    "update_failure_state",
    "clear_update_failure",
    "restart_daemon_process",
    "kernel_convergence_phase",
    "export_logs_bundle",
    "library_dir",
    "allow_media_scope",
    "notify_system",
    "set_tray_locale",
    "update_download",
    "update_install",
];

fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(APP_COMMANDS)),
    )
    .expect("tauri-build failed");
}
