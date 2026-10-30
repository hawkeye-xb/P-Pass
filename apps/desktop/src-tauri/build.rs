// #1120：网页能调的应用命令逐个声明（Tauri 2 官方机制 `AppManifest::commands`）。
//
// 列在这里的命令会生成 `allow-<命令>` 权限，网页只能调用 capabilities 里明确
// 授权的那些；没列的命令一律调不到。这份名单、`lib.rs` 的 `generate_handler!`、
// `capabilities/default.json` 三者必须一致——由 `lib.rs` 的
// `command_lists_agree` 测试钉住，加命令只改一处会红。
const APP_COMMANDS: &[&str] = &[
    "daemon_status",
    "daemon_low_space_ack",
    "daemon_library_recheck",
    "daemon_pairing_start",
    "daemon_pairing_stop",
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
    "relocate_library",
    "start_daemon",
    "daemon_startup_error",
    "stop_daemon",
    "pause_daemon_for_update",
    "pending_shell_version",
    "relaunch_shell",
    "self_heal_daemon",
    "resume_after_failed_update",
    "update_failure_state",
    "resident_hosting",
    "clear_update_failure",
    "restart_daemon_process",
    "kernel_convergence_phase",
    "export_logs_bundle",
    "reveal_library",
    "reveal_asset",
    "reveal_device_folder",
    "pick_library_dir",
    "use_default_library_dir",
    "is_test_build",
    "pair_qr_svg",
    "allow_media_scope",
    "notify_system",
    "set_tray_locale",
    "set_library_alert",
    "update_download",
    "update_install",
];

/// Windows 应用清单（声明依赖 Common-Controls v6）。内容与 tauri-build 默认的那份一致。
const WINDOWS_APP_MANIFEST: &str = "windows-app-manifest.xml";

fn main() {
    let mut attrs = tauri_build::Attributes::new()
        .app_manifest(tauri_build::AppManifest::new().commands(APP_COMMANDS));

    // Windows（MSVC）：清单改由链接器嵌入，对**所有**链接目标生效，包括 `cargo test` 的
    // lib 测试程序。tauri-build 默认经 embed-resource 嵌入，只走 `rustc-link-arg-bins`，
    // 测试程序拿不到清单就用 ComCtl32 v5；而 tauri 默认开着 common-controls-v6，muda 的
    // `TaskDialogIndirect`（v6 才有）一旦被测试编进来（mock 运行时搭 App 时会），测试程序
    // 一启动就 0xc0000139 STATUS_ENTRYPOINT_NOT_FOUND。这是 Tauri 自己仓库的同款做法
    // （tauri/build.rs `embed_manifest_for_tests`，tauri-apps/tauri#4383）。
    // 资源里就不再放一份，免得两份清单冲突。
    // 用构建脚本的环境变量判目标平台，不是 `#[cfg]` 分叉（构建脚本跑在宿主机上）。
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    if target_os == "windows" && target_env == "msvc" {
        let manifest = std::path::Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap())
            .join(WINDOWS_APP_MANIFEST);
        println!("cargo:rerun-if-changed={}", manifest.display());
        println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
        println!("cargo:rustc-link-arg=/MANIFESTINPUT:{}", manifest.display());
        attrs =
            attrs.windows_attributes(tauri_build::WindowsAttributes::new_without_app_manifest());
    }

    tauri_build::try_build(attrs).expect("tauri-build failed");
}
