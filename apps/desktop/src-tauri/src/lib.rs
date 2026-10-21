//! P-Pass 桌面壳（T-041, ADR-012）：壳 = UI + 托管（#1046，S3）。
//!
//! - **UI**：把 daemon 给出的结论呈现出来、接收输入；业务判断不在这里（经本机
//!   IPC 与 daemon 的一次性 `config` / `diag` 子命令调用核心）。
//! - **托管**：mac / Windows 的发行层——拉起 daemon、开机自启登记、用户停服标记、
//!   更新后新壳启动对账、自动换内核。判据与动作在 [`distribution`]（纯 Rust，不依赖
//!   Tauri），Tauri command 只负责调用；核心里没有托管代码（门禁 G2/G3）。

// DESK-33 (#325)：clippy.toml 禁止产品代码直接 `Command::new`；单元测试
// 里的子进程（拉起测试二进制自身等）不面向用户，统一放行。
#![cfg_attr(test, allow(clippy::disallowed_methods))]

mod daemon_cli;
mod distribution;
mod ipc;
mod service_state;

// QA-09 迁移（#211）：桌面壳现在有 9 个地方要调 platform 的能力，
// 每个函数各写一遍 `use ... as _` 已经不划算；提到文件级。
use distribution::{
    daemon_is_unmanaged, is_user_stopped, kernel_convergence_verdict,
    reconcile_autostart_registration, self_heal_allowed, set_user_stopped, should_pause_for_update,
    show_wizard, update_resume_needed, KernelFacts, KernelVerdict,
};
use platform::{HostingAdapter as _, PlatformAdapter as _};
use serde_json::{json, Value};
use service_state::{ServiceState, ServiceStateManager};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::Emitter;
use tauri::Manager;

// UPD-01: updater plugin（pubkey/endpoints 在 tauri.conf.json；
// build 期 updater artifact 签名需 TAURI_SIGNING_PRIVATE_KEY——CI 由
// UPDATE_SIGNING_KEY 提供，本地无 key 路径跳过 .sig 生成）。
// 注意：tauri-plugin-updater 2.10 的 build() 返回带 Config 的 TauriPlugin，
// 需内联注册（独立函数标注单参数类型会类型不匹配）。

// ── I18N-03 (#492)：托盘菜单文案 ───────────────────────────────────────
// 与前端同一份字典：编译期 include_str! 仓库根的 assets/i18n/*.json，不另开
// 副本。系统语言由前端报上来（`set_tray_locale`，传的就是它自己按
// navigator.language 判出来的 zh / en），所以托盘和窗口永远同一种语言；在前端
// 报到之前（启动后不到一秒，以及前端还没起来时的安装位置对话框），按平台适配器
// 的 `system_locale()` 定初值：zh* → zh，其它和读不到 → en（B6，#1043）。
const I18N_EN: &str = include_str!("../../../../assets/i18n/en.json");
const I18N_ZH: &str = include_str!("../../../../assets/i18n/zh.json");

/// #550：托盘「导出诊断包」的菜单 id——TRAY_ITEMS 与 on_menu_event 的分支
/// 共用这一个常量，拼错不会被 match 的 `_ => {}` 静默吞掉。
const TRAY_EXPORT_LOGS: &str = "export_logs";

/// 托盘菜单项 id → 字典 key（数组顺序即菜单顺序）。
const TRAY_ITEMS: [(&str, &str); 4] = [
    ("show", "ui.tray_open"),
    (TRAY_EXPORT_LOGS, "ui.tray_export_logs"),
    ("stop", "ui.stop_service"),
    ("quit", "ui.tray_quit"),
];

/// #550：托盘点「导出诊断包」时发给前端的事件名。前端收到后走窗口里原来
/// 那条 `exportLogs()`（同一个 export_logs_bundle、同一套提示文案）。
const EVENT_EXPORT_LOGS_REQUESTED: &str = "export-logs-requested";

/// DESK-28：把主窗口拉到前台——unminimize 不能省（最小化时 show() 恢复
/// 不了它，#170 真机实测）；show 管「隐藏→可见」，unminimize 管
/// 「最小化→还原」，是两件独立的事。
fn bring_main_window_to_front(app: &tauri::AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.unminimize();
        let _ = win.show();
        let _ = win.set_focus();
    }
}

/// B6（#1043）：托盘与安装位置对话框的**初始**语言（前端起来后会用
/// `set_tray_locale` 报它实际用的语言）。系统语言由平台适配器回答；只有明确是
/// 中文才用中文，读不到一律英文（改前读 `LANG`，为空时默认中文——英文 Windows
/// 与从访达启动的 macOS GUI 都拿不到 `LANG`，于是显示中文）。
fn tray_locale(system_locale: Option<&str>) -> &'static str {
    match system_locale {
        Some(tag) if tag.trim().to_lowercase().starts_with("zh") => "zh",
        _ => "en",
    }
}

/// 本机的 [`tray_locale`]。
fn system_tray_locale() -> &'static str {
    tray_locale(platform::adapter().system_locale().as_deref())
}

/// 取一条托盘文案；key 缺失时退回 key 本身（与前端 t() 同一兜底）。
fn tray_text(locale: &str, key: &str) -> String {
    let raw = if locale == "zh" { I18N_ZH } else { I18N_EN };
    serde_json::from_str::<Value>(raw)
        .ok()
        .and_then(|v| v.get(key).and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_else(|| key.to_string())
}

/// DESK-68 (#996)：本进程是不是从正式安装位置启动的；不是就弹系统对话框说明
/// 怎么办，返回 `false`。判据在平台层（`HostingAdapter::is_install_location`）。
///
/// 用 rfd 直接弹（tauri-plugin-dialog 的底层，已在依赖树里）：这时 Tauri 还没
/// 起来，也不该为一个提示把整个应用跑起来。读不到自身路径时放行——拦了用户
/// 也无从照提示去做。
fn running_from_install_location() -> bool {
    let adapter = platform::hosting();
    let Ok(exe) = std::env::current_exe() else {
        return true;
    };
    if adapter.is_install_location(&exe) {
        return true;
    }
    let locale = system_tray_locale();
    rfd::MessageDialog::new()
        .set_level(rfd::MessageLevel::Warning)
        .set_title(tray_text(locale, "ui.install_location_required_title"))
        .set_description(tray_text(locale, adapter.install_location_hint_key()))
        .set_buttons(rfd::MessageButtons::Ok)
        .show();
    false
}

/// 已建好的托盘菜单项（key, item），`set_tray_locale` 据此改字。
struct TrayMenuItems(Vec<(&'static str, MenuItem<tauri::Wry>)>);

/// 前端启动时报一次它用的语言，托盘菜单跟着换字。
#[tauri::command]
fn set_tray_locale(app: tauri::AppHandle, lang: String) {
    let locale = tray_locale(Some(&lang));
    if let Some(items) = app.try_state::<TrayMenuItems>() {
        for (key, item) in &items.0 {
            let _ = item.set_text(tray_text(locale, key));
        }
    }
}

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
/// #413 §7: desktop system notification (the low-space warning). The shell
/// only relays already-localized text; the "when" rule lives in the
/// daemon (`crates/daemon/src/low_space.rs`, #1044), the "how" in the platform adapter
/// (macOS: osascript, best effort; Windows: toast, DESK-17).
#[tauri::command]
fn notify_system(title: String, body: String) {
    platform::adapter().notify(&title, &body);
}

#[tauri::command]
fn daemon_call(app: tauri::AppHandle, method: String, params: Value) -> Result<Value, String> {
    match ipc::DaemonHandle::discover().and_then(|d| d.call(&method, params)) {
        Ok(value) => Ok(value),
        Err(e) => {
            // DESK-63 (#946): the shell used to send this straight to the
            // webview console and keep nothing. A failed data call must not
            // change the service state (see service_state), but it must be
            // in the diagnostic bundle.
            app.state::<ServiceStateManager>()
                .log_call_failure(&method, &e);
            Err(e)
        }
    }
}

/// Daemon reachable?（壳内部探测用；#1041 起不再注册成前端 command——前端从不 invoke）
fn daemon_online() -> bool {
    ipc::DaemonHandle::discover()
        .and_then(|d| d.call("status", json!({})))
        .is_ok()
}

/// DESK-63 (#946): the shell's initial service state, derived from the same
/// three facts `wizard_state` reads. Keeping it next to the marker helpers
/// means "user stopped" cannot mean one thing to the wizard and another to
/// the state machine.
fn initial_service_state() -> ServiceState {
    let dir = platform::adapter().data_dir();
    let configured = dir.join("config.toml").exists();
    let installed = platform::hosting().autostart_installed().unwrap_or(false);
    ServiceState::initial(configured, installed, is_user_stopped(&dir))
}

/// DESK-63 (#946): snapshot for the frontend's first paint. The event stream
/// also emits on every transition; this covers the window where the UI is
/// not listening yet.
#[tauri::command]
fn service_state(app: tauri::AppHandle) -> Value {
    app.state::<ServiceStateManager>().snapshot()
}

/// IPC-02: 长连接事件订阅——daemon 事件经 Tauri event `daemon-event`
/// 转发给前端（前端 `listen("daemon-event", …)` 按事件类型即时刷新）。
/// 断线 2s 退避自动重连；订阅握手失败（老 daemon）降级为慢速 status 探针。
///
/// DESK-63 (#946): this thread is also the **only owner** of the service
/// run state. `subscribe_events_with_open`'s handshake means "the daemon is
/// ready to talk"; a dropped/failed connection means "not reachable"; the
/// user's stop marker wins over both. The frontend no longer decides this
/// from a single `status` call inside `refresh()`.
///
/// #1041：只由 `setup` 调一次，不再注册成前端 command——重复 invoke 会再起一条订阅线程、
/// 让事件重复（`mark_stream_started` 只是兜底）。
fn start_event_stream(app: tauri::AppHandle) {
    let manager = app.state::<ServiceStateManager>().inner().clone();
    if !manager.mark_stream_started() {
        return;
    }
    std::thread::spawn(move || {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;
        use std::time::{Duration, Instant};

        let started = Instant::now();
        // Long enough for a cold daemon start; after this a failure is a
        // fact, not "still booting". The event stream keeps reconnecting,
        // so recovering later still flips the UI to running.
        let startup_grace = Duration::from_secs(15);
        let mut had_connection = manager.current() == ServiceState::Running;

        loop {
            match ipc::DaemonHandle::discover() {
                Ok(handle) => {
                    let opened = Arc::new(AtomicBool::new(false));
                    let opened_for_open = Arc::clone(&opened);
                    let app_for_open = app.clone();
                    let manager_for_open = manager.clone();
                    let app_for_event = app.clone();
                    let result = handle.subscribe_events_with_open(
                        move || {
                            opened_for_open.store(true, Ordering::SeqCst);
                            manager_for_open.set(
                                &app_for_open,
                                ServiceState::Running,
                                Some("event stream open"),
                            );
                        },
                        move |ev| {
                            let _ = app_for_event.emit("daemon-event", ev);
                        },
                    );
                    if opened.load(Ordering::SeqCst) {
                        had_connection = true;
                    }
                    match result {
                        // subscribe_events_with_open only returns after the
                        // stream ends; treat it as a lost connection.
                        Ok(()) => {
                            manager.note_connection_failure("event stream ended");
                            let within_grace = !had_connection && started.elapsed() < startup_grace;
                            let next = manager.next_after_failure(had_connection, within_grace);
                            manager.set(&app, next, Some("event stream ended"));
                        }
                        // Old daemon without events.subscribe: discover() just
                        // proved `status` answers, so it is running. There is
                        // no event source, so fall back to a slow probe; this
                        // is the only timed status probe that drives state.
                        Err(e) if e == "err.unsupported" => {
                            had_connection = true;
                            manager.set(
                                &app,
                                ServiceState::Running,
                                Some("events.subscribe unsupported; status probe ok"),
                            );
                            loop {
                                std::thread::sleep(Duration::from_secs(30));
                                match ipc::DaemonHandle::discover() {
                                    Ok(_) => {}
                                    Err(e) => {
                                        manager.note_connection_failure(&e);
                                        let next = manager.next_after_failure(true, false);
                                        manager.set(&app, next, Some(&e));
                                        break;
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            manager.note_connection_failure(&e);
                            let within_grace = !had_connection && started.elapsed() < startup_grace;
                            let next = manager.next_after_failure(had_connection, within_grace);
                            manager.set(&app, next, Some(&e));
                        }
                    }
                }
                Err(e) => {
                    manager.note_connection_failure(&e);
                    let within_grace = !had_connection && started.elapsed() < startup_grace;
                    let next = manager.next_after_failure(had_connection, within_grace);
                    manager.set(&app, next, Some(&e));
                }
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    });
}

/// First-run wizard state (T-042)：直接回答「要不要显示向导」（`show_wizard`，
/// 判据见 [`show_wizard`]），外加向导自己要用的预填值。
/// T-042b: `configured_library_dir` prefills the wizard's folder step from
/// the existing config, so a oneshot-degraded user (autostart registration
/// failed → fallback spawn; lib.rs start_daemon Err branch) who bounces back
/// into the wizard does NOT re-point the library to a fresh empty folder
/// (orphaned-library risk) — the wizard shows what's already configured.
///
/// 服务状态变化时前端要重读这个命令（`service-state` 事件到了就读）——
/// `show_wizard` 依赖「服务是否在线」，那是 Rust 一侧的状态。
#[tauri::command]
fn wizard_state(app: tauri::AppHandle) -> Value {
    let dir = platform::adapter().data_dir();
    // Photos must land somewhere a person can FIND (real walkthrough:
    // "传到哪儿了" had no answer while the library hid in ~/Library).
    let pictures = default_library_dir(platform::adapter().pictures_dir());
    let installed = platform::hosting().autostart_installed().unwrap_or(false);
    let online = app.state::<ServiceStateManager>().current() == ServiceState::Running;
    json!({
        "show_wizard": show_wizard(
            dir.join("config.toml").exists(),
            installed,
            is_user_stopped(&dir),
            online,
        ),
        "default_dir": pictures.to_string_lossy(),
        // Some of the library, if the config already points somewhere —
        // the wizard prefills this so re-running it never orphans the
        // existing library (T-042b).
        "configured_library_dir": ipc::read_config_data_dir(&dir),
        // #1043：平台相关的界面决定由 `platform_ux` 命令给（适配器回答），
        // 这里不给平台名。
    })
}

/// B10（#1043）：新建库的默认目录名。固定英文、不随界面语言变——目录名会
/// 写进 config、出现在资源管理器/访达里，跟着语言变就会一台机器两个名字。
/// 只影响新建库：已有库的路径存在 config.toml 里，不动。
const DEFAULT_LIBRARY_DIR_NAME: &str = "P-Pass Library";

/// 新建库的默认位置：「图片」目录（由平台适配器回答）下的
/// [`DEFAULT_LIBRARY_DIR_NAME`]。读不到「图片」目录时退回当前目录（与改前
/// 读不到 HOME 时的 `.` 同一口径）。
fn default_library_dir(pictures: Option<std::path::PathBuf>) -> std::path::PathBuf {
    pictures
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join(DEFAULT_LIBRARY_DIR_NAME)
}

/// #1043：界面层要的平台能力，由平台适配器回答——关窗要不要提示「还在后台
/// 运行」、标题栏是不是透明 Overlay、电脑睡眠由谁负责（决定用哪份向导视图）。
/// 前端（`platformUx.js`）只读这些字段，自己不判断平台。
#[tauri::command]
fn platform_ux() -> Value {
    let a = platform::adapter();
    json!({
        "close_to_tray_hint": a.close_to_tray_hint(),
        "overlay_titlebar": a.overlay_titlebar(),
        "sleep_owner": a.sleep_owner().map(platform::SleepOwner::as_str),
    })
}

/// #1043：更新失败时给用户看哪句话（i18n key）。「文件被占用」由 Rust 侧判：
/// 从 std `io::Error` 的 Display 尾巴 `(os error N)` 取系统错误码，含义问平台
/// 适配器（`is_file_in_use_os_error`），不再在前端用正则匹配各语言的系统原文。
///
/// 注：tauri-plugin-updater 2.10 在 Windows 上把 NSIS 安装器拉起来就退出进程，
/// 安装器覆盖文件失败发生在壳退出之后，到不了这里；能到这里的只有下载 / 写
/// 临时文件阶段的 io 错误。
#[tauri::command]
fn update_failure_key(message: String) -> &'static str {
    update_failure_key_with(&message, |code| {
        platform::adapter().is_file_in_use_os_error(code)
    })
}

/// [`update_failure_key`] 的纯函数部分（判据注入，三平台都测得到）。
fn update_failure_key_with(message: &str, is_file_in_use: impl Fn(i32) -> bool) -> &'static str {
    match os_error_code(message) {
        Some(code) if is_file_in_use(code) => "ui.update_failed_file_locked",
        _ => "ui.update_failed",
    }
}

/// std `io::Error` 的 Display 以 ` (os error N)` 结尾（Rust 标准库的固定格式，
/// 与系统语言无关）；取出 N。不是这个形状 = `None`。
fn os_error_code(message: &str) -> Option<i32> {
    let rest = message.trim_end().strip_suffix(')')?;
    let start = rest.rfind("(os error ")? + "(os error ".len();
    rest[start..].parse().ok()
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
        Ok(_) => Err(ipc::ui_err("ui.err_sleep_fix_unsupported", &[])),
        Err(platform::PlatformError::Cancelled { .. }) => {
            Err(ipc::ui_err("ui.err_auth_cancelled", &[]))
        }
        Err(platform::PlatformError::Failed { detail, .. }) => {
            Err(ipc::ui_err("ui.err_sleep_fix_failed", &[("err", &detail)]))
        }
        Err(e) => Err(ipc::ui_err("ui.err_sleep_fix_failed", &[("err", &e)])),
    }
}

/// 首启向导确认库位置：config.toml 的写者是 daemon（#1042 / #1045），壳只调
/// 内置 daemon 的 `config init --library <dir>`——建库目录、写整份模板、归一
/// 路径分隔符、用真 TOML 序列化都在 daemon 一侧（`crates/daemon/src/config.rs`）。
/// 失败原样把 daemon 的错误交给前端（校验类本身就是 keyed JSON）。
#[tauri::command]
fn write_config(library_dir: String) -> Result<(), String> {
    daemon_cli::config_init(&daemon_cli::bundled_sidecar()?, &library_dir)
}

/// 更改照片库位置：同上，壳只调 `config set-library <dir>`（存在 / 可写 / 不嵌套
/// 的校验、只改 data_dir 一行、清旧库里的孤儿 config 都在 daemon）。生效时机
/// 不变——daemon 只在启动时读一次 config，重启后台服务后生效。
#[tauri::command]
fn set_library_dir(library_dir: String) -> Result<(), String> {
    daemon_cli::config_set_library(&daemon_cli::bundled_sidecar()?, &library_dir)
}

/// DESK-29 (#268)：注册开机自启**之前**，先确认这个 sidecar 真的能跑、真的是
/// 我们的 daemon。
///
/// 为什么不能只看 `is_file()`（改之前唯一的守卫）：**0 字节的文件
/// `is_file()` 返回 true**。杀毒软件把未签名的 exe 掏空、安装/更新写到一半
/// 被打断、开发机上的构建 stub——任何一种都会让一个跑不起来的文件被写进
/// 开机自启，**覆盖掉原来那条好的**，而向导报告"已启动"。
///
/// 判法是「**真的跑一次 `--version --json`**」而不是「查文件大小」：前者直接回答
/// "能不能跑"这个问题本身。#1045 起走 daemon 的机读契约（`product` 字段 +
/// schema 版本），不再匹配纯文本 `--version` 的前缀；判据与起进程见
/// `daemon_cli::{probe_version, version_reply}`。
///
/// ⚠️ Windows 上 release 的 daemon 是 GUI 子系统（`main.rs` 顶部的
/// `windows_subsystem`），不会分配控制台，所以不闪窗；起子进程走
/// `platform::command`（Windows 上带 `CREATE_NO_WINDOW`）。
fn verify_sidecar_runs(sidecar: &std::path::Path) -> Result<(), String> {
    daemon_cli::probe_version(sidecar).map(|_| ())
}

/// Install the bundled daemon as a resident service (T-040 autostart:
/// launchd/registry — starts now, at every boot, and restarts on
/// crash). Falls back to a one-shot spawn if registration fails, so
/// the wizard never dead-ends. 基础服务不该手动启动、不该会停。
#[tauri::command]
fn start_daemon(app: tauri::AppHandle) -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let sidecar = exe
        .parent()
        .ok_or("no parent dir")?
        .join(platform::hosting().daemon_executable_name());
    if !sidecar.is_file() {
        return Err(ipc::ui_err(
            "ui.err_sidecar_missing",
            &[("path", &sidecar.display())],
        ));
    }
    // DESK-29 (#268)：**先探活再注册**。顺序是这条修复的全部要害——
    // 探不过就在这里返回，`install_autostart` 根本不会被调到，所以用户
    // 原来那条好的开机自启键**不会被覆盖**。
    //
    // 也不走下面那条 "注册失败就直接 spawn" 的兜底：一个跑不起来的文件，
    // spawn 也一样跑不起来，兜底只会把错误掩成另一种错误。
    verify_sidecar_runs(&sidecar)?;
    // DESK-36 (#456)：用户点「启动服务」（或走完向导）= 撤销之前的主动停止，
    // 自愈恢复正常。放在探活之后：文件跑不起来就什么都没启动，仍算「停着」。
    set_user_stopped(&platform::adapter().data_dir(), false)?;
    let manager = app.state::<ServiceStateManager>().inner().clone();
    manager.set(&app, ServiceState::Starting, Some("user start"));
    match platform::hosting().install_autostart(&sidecar) {
        // LaunchAgent RunAtLoad+KeepAlive: starts immediately, survives
        // crashes and reboots.
        Ok(()) => Ok("resident".into()),
        Err(e) => {
            // Fall back to a one-shot spawn — still usable this session.
            match platform::command(&sidecar)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .stdin(std::process::Stdio::null())
                .spawn()
            {
                Ok(_) => Ok(format!("oneshot: {e}")),
                Err(e2) => {
                    manager.set(&app, ServiceState::Unreachable, Some("start failed"));
                    Err(ipc::ui_err(
                        "ui.err_register_and_spawn",
                        &[("err", &e), ("spawn_err", &e2)],
                    ))
                }
            }
        }
    }
}

/// 文件尾部最多 `max_bytes` 字节（日志一路累积，取尾部就够）。
fn tail_of(path: &std::path::Path, max_bytes: u64) -> Option<String> {
    use std::io::{Read as _, Seek as _, SeekFrom};
    let len = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let mut f = std::fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(len.saturating_sub(max_bytes)))
        .ok()?;
    let mut buf = Vec::new();
    f.take(max_bytes).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).to_string())
}

fn last_stderr_line(path: &std::path::Path) -> Option<String> {
    let stderr = tail_of(path, 64 * 1024)?;
    stderr
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .map(str::to_owned)
}

/// DESK-58 (#875) / #1043：daemon 启动早期 stderr 的最后一行非空内容。落点
/// 问平台适配器（`daemon_log_paths().stderr`）：Windows 是 daemon 自己接的
/// `logs\daemon.err`，macOS 是 launchd 的 `StandardErrorPath`。读不到就如实
/// 返回 `None`，不猜路径、不编失败原因。
fn daemon_startup_error_in(paths: &platform::DaemonLogPaths) -> Option<String> {
    last_stderr_line(paths.stderr.as_deref()?)
}

/// daemon 起不来时的结论（#1044）：`key` 是 daemon 认出的已知原因（i18n key），
/// `detail` 是 stderr 原文（照常给出，不许被模板文案吃掉）。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
struct StartupError {
    key: Option<String>,
    detail: String,
}

/// daemon 的 keyed 错误行是一行 JSON `{"error_key", "detail"}`
/// （`crates/daemon/src/cli.rs::startup_error_line`）；不是这个形状的行（旧内核、
/// panic 等）原样当 detail，key 为空——壳不猜原因。
fn parse_startup_error(line: String) -> StartupError {
    match serde_json::from_str::<Value>(&line) {
        Ok(v) if v.get("detail").and_then(Value::as_str).is_some() => StartupError {
            key: v["error_key"].as_str().map(str::to_owned),
            detail: v["detail"].as_str().unwrap_or_default().to_owned(),
        },
        _ => StartupError {
            key: None,
            detail: line,
        },
    }
}

/// The wizard asks only after its existing readiness wait has elapsed. This
/// exposes the daemon's own stderr unchanged (plus the daemon's keyed
/// reason, when it gave one), so the UI can explain known failures without
/// replacing actionable diagnostic text.
#[tauri::command]
fn daemon_startup_error() -> Option<StartupError> {
    let a = platform::adapter();
    daemon_startup_error_in(&a.daemon_log_paths(&a.data_dir())).map(parse_startup_error)
}

/// #1043：服务管理器接的那对 stdio 路径（macOS launchd 的
/// `StandardOutPath`/`StandardErrorPath`）——只在 stdio 归服务管理器、且已登记
/// 常驻服务时才算数（与改前「plist 在才有路径」同一口径）。daemon 自己接的
/// stderr（Windows）不在此列。
fn service_stdio_paths(
    paths: &platform::DaemonLogPaths,
    service_registered: bool,
) -> (Option<std::path::PathBuf>, Option<std::path::PathBuf>) {
    if paths.stdio_by_service_manager && service_registered {
        (paths.stdout.clone(), paths.stderr.clone())
    } else {
        (None, None)
    }
}

/// 当前机器上的 [`service_stdio_paths`]。
fn current_service_stdio_paths() -> (Option<std::path::PathBuf>, Option<std::path::PathBuf>) {
    let a = platform::adapter();
    service_stdio_paths(
        &a.daemon_log_paths(&a.data_dir()),
        platform::hosting().autostart_installed().unwrap_or(false),
    )
}

/// DESK-36 (#456)：前端发现 daemon 不可达时调这个。判据在**调用这一刻**读磁盘上
/// 的标记——前端缓存的状态可能是旧的（比如刚在托盘里点了停止），只有这里读才没有
/// 竞态。返回 true = 真的拉起了；false = 按判据跳过（不是错误）。
#[tauri::command]
fn self_heal_daemon(app: tauri::AppHandle) -> Result<bool, String> {
    // #1060：为更新暂停期间断连是本壳自己造成的，不是服务崩了——不拉，
    // 否则旧二进制在安装器替换前被拉回来，一次更新停两次。
    if app.state::<UpdatePause>().active() {
        eprintln!("#1060: 为更新暂停中，跳过自愈");
        return Ok(false);
    }
    self_heal_now(&app, "self heal")
}

/// #1060：本壳「为更新暂停了后台服务」的进程内状态。只活在发起更新的这个壳里：
/// 安装成功 → 旧壳退出、状态随之消失，新壳启动对账负责拉起新版；安装失败 →
/// `resume_after_failed_update` 清掉它再自愈。不落盘：重启后的壳本来就不在
/// 暂停窗口里。
#[derive(Default)]
struct UpdatePause(std::sync::atomic::AtomicBool);

impl UpdatePause {
    fn begin(&self) {
        self.0.store(true, std::sync::atomic::Ordering::SeqCst);
    }
    fn end(&self) {
        self.0.store(false, std::sync::atomic::Ordering::SeqCst);
    }
    fn active(&self) -> bool {
        self.0.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// #1060：下载或安装失败——结束暂停窗口，再按常规判据自愈（用户停过的不拉）。
#[tauri::command]
fn resume_after_failed_update(app: tauri::AppHandle) -> Result<bool, String> {
    app.state::<UpdatePause>().end();
    self_heal_now(&app, "update failed")
}

/// 自愈本体（前端触发的 `self_heal_daemon` 与壳启动对账共用，#1046）：配置过、且
/// 不是用户主动停的（`self_heal_allowed`，调用这一刻读盘）才拉。
fn self_heal_now(app: &tauri::AppHandle, reason: &str) -> Result<bool, String> {
    if !self_heal_allowed(&platform::adapter().data_dir()) {
        return Ok(false);
    }
    let manager = app.state::<ServiceStateManager>().inner().clone();
    manager.set(app, ServiceState::Starting, Some(reason));
    // #732：有 LaunchAgent 时交给 launchd 拉（不杀在跑的——自愈只补"没在跑"）。
    match bring_up_daemon(false) {
        Ok(_) => Ok(true),
        Err(e) => {
            manager.set(app, ServiceState::Unreachable, Some(&e));
            Err(e)
        }
    }
}

/// Stop the resident service the way a user means it: unregister the
/// autostart entry FIRST (so launchd won't respawn it), then ask the
/// running daemon to shut down. "能优雅退出"与"崩溃自动恢复"必须并存
/// (用户裁决 2026-07-31).
///
/// DESK-36 (#456)：末尾要等进程真的退掉（最长 5s），所以命令是 async、
/// 实际工作放到阻塞线程池——同步命令跑在主线程上，等待期间窗口会卡住。
#[tauri::command]
async fn stop_daemon(app: tauri::AppHandle) -> Result<(), String> {
    let manager = app.state::<ServiceStateManager>().inner().clone();
    let outcome = tauri::async_runtime::spawn_blocking(stop_daemon_now)
        .await
        .map_err(|e| ipc::ui_err("ui.err_stop_thread", &[("err", &e)]))?;
    if outcome.is_ok() {
        manager.set(&app, ServiceState::Stopped, Some("user stopped"));
    }
    outcome
}

fn stop_daemon_now() -> Result<(), String> {
    // 0) DESK-36 (#456)：先落「用户主动停止」标记，再动进程——停到一半时
    //    恰好来一次自愈 tick，它也得看见标记。落不下就不停：停了也会被
    //    自愈拉回来，不如直接告诉用户停止失败。
    set_user_stopped(&platform::adapter().data_dir(), true)?;
    // 1) Unregister first — otherwise the service manager revives it
    //    (launchd KeepAlive / the Task Scheduler watchdog).
    //    DESK-65 (#957)：结果不许丢——撤不掉登记，下次开机服务照样起来，
    //    「停止」就是假的。照样把进程停掉，但最后如实报错。
    let unregistered = platform::hosting().uninstall_autostart();
    // 2) Best-effort: kill the bundled daemon process. launchctl bootout
    //    (inside uninstall_autostart) already stopped the managed one;
    //    this also covers a one-shot fallback spawn.
    // QA-09 迁移（#211）：best-effort —— 杀不掉也继续（原来两个分支也是
    // 直接丢结果）。区别在于「什么退出码算进程本来就没在跑」这条判据
    // 现在只有一份、在 platform 里，不再是三个调用点各抄一遍。
    let _ = stop_bundled_daemon();
    // 3) DESK-36 (#456)：等它真的不可达了再返回（最长 5s）——调用方紧接着
    //    就要刷新状态点，socket 还活着的那一瞬读到「运行中」就白刷了。
    //    超时不算失败：标记已落、autostart 已卸，剩下的只是进程退得慢。
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while daemon_online() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    unregistered.map_err(|e| e.to_string())
}

/// W1 (2026-08-26)：Windows 上常驻的 `ppf-daemon.exe` 占着自己的文件，安装器
/// 覆盖不了；#1060 起两平台一致——前端**下载完成后、`install()` 之前**调这个，
/// 下载期间服务照常工作（备份不被打断）。
///
/// 这是「为更新暂停」，不是用户的停止：不写停止标记、不删开机自启登记
/// （区别于 `stop_daemon`）；用户本来就停过服务则整个不动。恢复：安装成功 →
/// 新壳启动对账（`resume_after_update`）；安装失败（旧壳还在）→ 前端走
/// `self_heal_daemon`。Best-effort：失败只记日志，不挡更新本身。
#[tauri::command]
fn pause_daemon_for_update(app: tauri::AppHandle) -> Result<(), String> {
    // #1060：用户停过服务 = 本来就停着，更新前后都保持停止——不动。
    if !should_pause_for_update(&platform::adapter().data_dir()) {
        return Ok(());
    }
    // 先进入暂停窗口、再停：停掉那一刻前端就会收到断连并请求自愈。
    app.state::<UpdatePause>().begin();
    // 先让服务管理器卸下常驻那份（登记保留、不写停止标记）：只 kill 的话 launchd
    // KeepAlive / 计划任务看门狗几秒内就用旧文件拉回来，等于没停。
    match platform::hosting().pause_resident_daemon() {
        // #1063：Windows 不需要壳暂停——安装器 PREINSTALL/POSTINSTALL/onInstFailed
        // 负责停、起、失败恢复。这里必须**连 stop_bundled_daemon 都不做**，否则又会
        // 把服务杀掉、回到「安装器没启动就没人恢复」的老问题。
        Ok(platform::ResidentPause::NotApplicable) => {
            app.state::<UpdatePause>().end();
            eprintln!("#1063: 本平台由安装器负责停/起服务，壳不暂停");
            return Ok(());
        }
        Ok(outcome) => eprintln!("#1060: 为更新暂停常驻服务：{outcome:?}"),
        Err(e) => eprintln!("#1060: 为更新暂停常驻服务失败（继续）：{e}"),
    }
    // 再清掉服务管理器管不到的（一次性 spawn 的）。QA-09 迁移（#211）：best-effort。
    let _ = stop_bundled_daemon();
    Ok(())
}

/// #1063：安装器失败标记。`.onInstFailed` 写、新壳启动读：
///   install-failed
///   version=<目标版本>
///   service=1|0（安装器是否把服务恢复运行）
/// 文件放在平台数据目录，与 `windows/installer-hooks.nsh` 是同一份契约。
const UPDATE_FAILED_MARKER: &str = "update-failed";

#[derive(Debug, Default, PartialEq, Eq, serde::Serialize)]
struct UpdateFailureState {
    failed: bool,
    version: Option<String>,
    service_restored: bool,
}

/// 读失败标记（纯函数，便于单测）。缺失/读不出/首行不是 `install-failed` 一律
/// 当作没有失败——绝不因为一个坏文件让 App 每次启动都弹横幅。
fn read_update_failure_at(dir: &std::path::Path) -> UpdateFailureState {
    let Ok(text) = std::fs::read_to_string(dir.join(UPDATE_FAILED_MARKER)) else {
        return UpdateFailureState::default();
    };
    let mut state = UpdateFailureState {
        failed: text
            .lines()
            .next()
            .is_some_and(|l| l.trim() == "install-failed"),
        ..Default::default()
    };
    for line in text.lines().skip(1) {
        let line = line.trim();
        if let Some(v) = line.strip_prefix("version=") {
            let v = v.trim();
            if !v.is_empty() {
                state.version = Some(v.to_string());
            }
        } else if let Some(v) = line.strip_prefix("service=") {
            state.service_restored = v.trim() == "1";
        }
    }
    state
}

fn clear_update_failure_at(dir: &std::path::Path) -> std::io::Result<()> {
    match std::fs::remove_file(dir.join(UPDATE_FAILED_MARKER)) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

/// 前端启动时读一次：有没有「上次更新失败」的横幅要显示。
#[tauri::command]
fn update_failure_state() -> Value {
    json!(read_update_failure_at(&platform::adapter().data_dir()))
}

/// 用户点了「重试更新」/「关闭」后清掉标记；没有标记也返回成功（幂等）。
#[tauri::command]
fn clear_update_failure() -> Result<(), String> {
    clear_update_failure_at(&platform::adapter().data_dir()).map_err(|e| e.to_string())
}

/// B7（#1043）：结束内置 daemon——两平台同一套语义，由平台端口实现
/// （`HostingAdapter::stop_daemon`）：优先结束 daemon 自报的 pid，按壳旁边
/// 那个 sidecar 的**完整路径**匹配兜底；不再 `pkill -f`（命令行里恰好带
/// `ppf-daemon` 字样的别的进程不会被杀）。
fn stop_bundled_daemon() -> Result<platform::KillOutcome, String> {
    let sidecar = bundled_daemon_path()?;
    platform::hosting()
        .stop_daemon(&sidecar, daemon_reported_pid())
        .map_err(|e| e.to_string())
}

/// 壳旁边那个内置 daemon 的路径（同目录、平台给文件名）。
fn bundled_daemon_path() -> Result<std::path::PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    Ok(exe
        .parent()
        .ok_or("no parent dir")?
        .join(platform::hosting().daemon_executable_name()))
}

/// daemon 经 IPC 自报的 pid（`status.pid`）；连不上 / 不答 = `None`。超时取短：
/// daemon 挂死时正是要结束它的时候，不能被这次询问拖住。
fn daemon_reported_pid() -> Option<u32> {
    ipc::DaemonHandle::discover()
        .ok()?
        .call_with_timeout("status", json!({}), std::time::Duration::from_secs(1))
        .ok()?
        .get("pid")?
        .as_u64()
        .and_then(|p| u32::try_from(p).ok())
}

/// #732：内核是怎么被拉起来的。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BroughtUp {
    /// 服务管理器（launchd）拉起 / 本来就在跑，pid 由它报出。
    Resident { pid: u32 },
    /// 退回了一次性 spawn（没有服务管理器语义，或它失败了）。
    OneShot,
}

/// 常驻服务登记在、且本平台由系统的服务管理器托管吗？
///
/// DESK-65 (#957)：只问平台的能力（`has_service_manager`），不认具体机制——
/// macOS 是 launchd，Windows 是任务计划程序。业务流程（自愈、更新后恢复、
/// 重启服务）因此在两个平台上走同一条路。
fn resident_service_available() -> bool {
    let a = platform::hosting();
    a.service_mode().has_service_manager() && a.autostart_installed().unwrap_or(false)
}

/// #667 / #732：把内核拉起来，**优先交给服务管理器**。
///
/// `kill_running = true`（更新后恢复 / 换版本）：
/// 1. 先让**野生实例**（在跑、但 pid ≠ launchd 的 job pid——典型是旧壳更新时
///    一次性 spawn 的那只）经 IPC `daemon.step_down` 体面退位，等 socket 断开；
///    不先退位的话，launchd 新拉的实例与它同版本时会按 DAE-01 退位（exit 0，
///    launchd 不再拉），结果仍是野生实例在岗（2026-10-08 本机实测）。
/// 2. `launchctl kickstart -k`：杀掉 launchd 自己那份、按磁盘上的文件立刻拉新的。
///
/// `kill_running = false`（自愈）：launchd 在跑就不动，没在跑才拉。
///
/// 服务管理器那条走不通（未登记 / 本平台没有 / 命令失败）⇒ 退回一次性 spawn，
/// 与改前一致。
fn bring_up_daemon(kill_running: bool) -> Result<BroughtUp, String> {
    if resident_service_available() {
        if kill_running {
            retire_unmanaged_daemon(platform::hosting().resident_daemon_pid());
        }
        match platform::hosting().restart_resident_daemon(kill_running) {
            Ok(platform::ResidentRestart::Started { pid })
            | Ok(platform::ResidentRestart::AlreadyRunning { pid }) => {
                eprintln!("#732: 内核交由服务管理器拉起 pid={pid}");
                return Ok(BroughtUp::Resident { pid });
            }
            Ok(other) => eprintln!("#732: 服务管理器没接手（{other:?}），退回一次性 spawn"),
            Err(e) => eprintln!("#732: 服务管理器拉起失败，退回一次性 spawn：{e}"),
        }
    }
    spawn_bundled_daemon_oneshot().map(|()| BroughtUp::OneShot)
}

/// 在跑的 daemon 不是服务管理器那份（pid 对不上）⇒ 请它体面退位并等它退干净
/// （最长 5s）。读不到 status = 没有可退位的，直接返回。
fn retire_unmanaged_daemon(resident_pid: Option<u32>) {
    let Ok(handle) = ipc::DaemonHandle::discover() else {
        return;
    };
    let Some(pid) = handle
        .call("status", json!({}))
        .ok()
        .and_then(|v| v.get("pid").and_then(|p| p.as_u64()))
    else {
        return;
    };
    if !daemon_is_unmanaged(Some(pid as u32), resident_pid) {
        return;
    }
    eprintln!("#732: 在跑的内核 pid={pid} 不归服务管理器（job pid={resident_pid:?}），请它退位");
    let _ = handle.call("daemon.step_down", json!({}));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while daemon_online() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
}

/// 一次性 spawn 时把 daemon 的 stdout/stderr 接到哪儿（#732 ③）。
///
/// 服务管理器登记了 stdio 落点（macOS LaunchAgent）就**追加**进同一对文件——
/// 与 launchd 托管时同一去处，排障只看一处；没有（Windows / 未登记）= 接 null，
/// 与改前一致（Windows 的 daemon 自己有落盘日志，DIAG-B1）。打不开文件也退回
/// null，不能因为日志让内核起不来。
fn oneshot_stdio() -> (std::process::Stdio, std::process::Stdio) {
    let paths = current_service_stdio_paths();
    let open = |p: Option<std::path::PathBuf>| -> std::process::Stdio {
        p.and_then(|p| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(p)
                .ok()
        })
        .map(std::process::Stdio::from)
        .unwrap_or_else(std::process::Stdio::null)
    };
    (open(paths.0), open(paths.1))
}

/// 一次性 spawn 同目录下的内置 daemon（不注册 autostart）。#732 起只是
/// `bring_up_daemon` 的退路（服务管理器接不了手时）。
///
fn spawn_bundled_daemon_oneshot() -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let sidecar = exe
        .parent()
        .ok_or("no parent dir")?
        .join(platform::hosting().daemon_executable_name());
    if !sidecar.is_file() {
        return Err(ipc::ui_err(
            "ui.err_sidecar_missing",
            &[("path", &sidecar.display())],
        ));
    }
    let mut cmd = platform::command(&sidecar);
    let (out, err) = oneshot_stdio();
    cmd.stdout(out)
        .stderr(err)
        .stdin(std::process::Stdio::null())
        .spawn()
        .map_err(|e| ipc::ui_err("ui.err_respawn", &[("err", &e)]))?;
    Ok(())
}

/// UPD-06 (#616)：把壳登记成**登录项**（幂等：只写 plist，不 bootstrap——见
/// `platform::register_shell_agent` 的注释）。
///
/// **为什么必须在这里（启动时）做**，而不是"要换壳了再登记"：登录时 launchd 只加载
/// **当时已经存在**的 plist。若只在换壳那一刻才写，这台机器永远等不到 launchd 接管
/// 壳（`kickstart` 也就永远走不到），"壳是登录项"这条决定等于落空。启动时写一次，
/// **下一次登录**起壳就归 launchd 管——从那时起 `kickstart` 才是可用的常态路径。
///
/// 只写文件、绝不 `bootout`/`bootstrap`：`RunAtLoad=true` 的 job 一被 bootstrap，
/// launchd 会立刻再拉起一个实例（被 single-instance 顶掉），是一次无意义的起停。
///
/// DESK-72 (#1012)：怎么登记是平台知识（macOS 写 LaunchAgent，Windows 写 HKCU
/// `Run` 值，没有登录项的平台什么都不做），这里只调平台能力。
fn register_shell_login_item() {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    if let Err(e) = platform::hosting().register_shell_login_item(&exe) {
        // 开发构建 / 从 dmg 或下载目录直跑（非正式安装位置）被拒是**预期**的——不当错误刷屏。
        eprintln!("#616: 壳登录项未登记（{e}）——非正式安装位置时属预期");
    }
}

/// #809：外壳自报的版本 = 编进这只壳的 tauri `package_info().version`。
///
/// 不用 Cargo 的 `CARGO_PKG_VERSION` 宏变量：那是 Cargo.toml 里的号，发布构建不改它，test tag
/// 时与 daemon（`PPF_BUILD_VERSION` = tag 名）错开。`package_info` 取的是 tauri 配置
/// 合并后的 `version`——发布构建由 `tools/bundle-desktop-macos.sh` / release.yml 经
/// `--config` 注入 `tools/release-version.sh desktop` 的输出，与 daemon 同源；也是
/// 前端 `getVersion()`、Info.plist、updater 当前版本用的同一个值。
fn shell_version<R: tauri::Runtime>(app: &tauri::AppHandle<R>) -> String {
    app.package_info().version.to_string()
}

/// UPD-06 (#616)：磁盘上**安装包**的版本（`Contents/Info.plist`）与运行中
/// 这只壳的版本不同 ⇒ 返回磁盘上那个版本（"更新装完了、但运行中的壳还是旧的"）。
///
/// 这是确定性判据：壳的可执行文件在 `/Applications` 下跨更新路径不变，包在它
/// 下面被换掉，于是"读到的包版本 ≠ 我的编译版本"只有一种解释。同版本或读不到
/// = `None`（前端什么都不做）。#1044 B13：判「同不同」用共享的 `version_cmp`，
/// 前端不再自己比版本。
#[tauri::command]
fn pending_shell_version(app: tauri::AppHandle) -> Option<String> {
    pending_shell_version_of(
        platform::hosting().installed_bundle_version(),
        &shell_version(&app),
    )
}

fn pending_shell_version_of(installed: Option<String>, running: &str) -> Option<String> {
    installed.filter(|v| version_cmp(v, running) != std::cmp::Ordering::Equal)
}

/// UPD-06 (#616)：换壳——让**运行中的这只壳**变成磁盘上已经是新版的那一份。
///
/// 两层，每层失败都往下退化，绝不静默：
/// ① **系统路径**：登记壳的 LaunchAgent（幂等）+ **仅在"登记指向我自己"时**
///    `launchctl kickstart -kp` —— 由 launchd 杀 + 按磁盘上的新文件拉，
///    "进程自己换自己"的 single-instance 竞态在架构上消失，且 `-p` 给新 pid 可验证。
///    闸门不可省：登记指向别处时 kickstart 会把**另一份副本**（旧路径/备份目录里的
///    App）拉起来，比不重启更糟。
/// ② **退化路径**：`tauri::process::restart`（0.7.5 起在用：spawn 当前二进制 +
///    立即 exit(0)）。开发构建、从 dmg 直跑等"没有稳定安装位置"的场合只走这条。
///
/// 正常路径**不返回**（本进程被替换/被杀）；只有两层都没走成才 Err，
/// 前端据此给"手动完全退出再打开"的兜底提示。
#[tauri::command]
fn relaunch_shell(app: tauri::AppHandle) -> Result<(), String> {
    // ⚠️ 闸门一：只有**launchd 自己拉起来的**这一份壳才走系统路径。
    // `kickstart -k` 的 "kill the running instance" 只能杀服务管理器启动的进程；
    // 从访达/Dock 打开的壳，launchd 手里没有它的 pid ⇒ `-k` 无物可杀 ⇒ kickstart
    // 只会再拉一个实例，而 single-instance 会让新实例把焦点交回旧壳后自杀 ⇒
    // 用户点"重启"什么都没发生（比不重启更糟）。所以非 launchd 实例直接走退化路径。
    if let Some(label) = platform::hosting().shell_agent_label() {
        if !platform::hosting().shell_agent_started_us() {
            eprintln!(
                "#616: 本进程不是 {label} 拉起的（用户直接打开），kickstart 无物可杀，走壳自己重启"
            );
        } else {
            match std::env::current_exe() {
                Ok(exe) => match platform::hosting().register_shell_agent(&exe) {
                    Ok(()) => match platform::hosting().shell_agent_registered_exec() {
                        Ok(Some(registered)) if registered == exe => {
                            match platform::hosting().kickstart_shell_agent() {
                                Ok(pid) => {
                                    eprintln!("#616: kickstart {label} 拉起新壳 pid={pid}");
                                    return Ok(());
                                }
                                Err(e) => eprintln!("#616: kickstart 失败，退化 restart：{e}"),
                            }
                        }
                        other => eprintln!(
                            "#616: 壳登记未指向当前可执行文件（{other:?}），不用 kickstart（会拉起另一份副本）"
                        ),
                    },
                    Err(e) => eprintln!("#616: 登记壳 LaunchAgent 失败，退化 restart：{e}"),
                },
                Err(e) => eprintln!("#616: 读不出当前可执行文件，退化 restart：{e}"),
            }
        }
    }
    tauri::process::restart(&app.env());
}

/// DAE-04: 桌面壳更新后手动重启后台服务——杀掉当前运行的旧 daemon 进程，
/// 靠 launchd KeepAlive（SuccessfulExit=false，crates/platform/src/macos.rs
/// 注释：崩溃/被杀照样复活）自动拉起磁盘上已是新版本的同一个文件。
/// 与 stop_daemon 相反：本命令**绝不碰 autostart 注册**（uninstall 会
/// 阻止复活）——注册从头到尾没动过，这正是设计要点。体面退出（exit 0）
/// 反而不会被复活，所以必须是真的"杀"（信号终止），不走 step_down 那套
/// 版本协商。Windows 的计划任务（#957）同样由系统托管，走
/// `restart_resident_daemon`；只有没有服务管理器的兜底实现
/// （`ServiceMode::UserAutostart`）才杀掉后显式重新拉起一次（start_daemon
/// 的一次性 spawn 分支，不注册 autostart）。
///
/// **DESK-44 (#606) 两处修正**（2026-10-03 真机现场）：
/// ① **判据从"固定时钟"改成"可观察进度"**：旧实现"12 秒内版本必须变，否则报错"
///    在真机上必然偶发假失败——壳杀掉旧 daemon 后是 **launchd** 按 KeepAlive 重拉，
///    而 launchd 对反复退出的 job 有**重拉节流（默认 10s 量级）**；10s 节流 + 启动
///    ≈ 11–13s，正好骑在 12s 上。2026-10-03 验收人机器第一次点按钮就报了
///    「重启失败」，而 1~2 个轮询周期后 daemon 起来了、版本也确实变了。
///    ⇒ 现在只在**宽限期**（`RESTART_GRACE`，90s——它不是"多久算失败"，而是
///    "多久算彻底没救"）内等 daemon **答上 status**；答上了就算有结论，没答上就
///    如实返回 `still_starting=true`，由前端说"正在启动中"而不是"失败"。
/// ② **改 async**（照抄 stop_daemon 的决定）：同步命令跑在主线程上，等待期间
///    窗口会**整段卡住**（验收人 10-02 原话"点击立即重启，进入卡顿状态"就是这个）。
#[tauri::command]
async fn restart_daemon_process(app: tauri::AppHandle) -> Result<Value, String> {
    let manager = app.state::<ServiceStateManager>().inner().clone();
    manager.set(&app, ServiceState::Starting, Some("restart requested"));
    let outcome = tauri::async_runtime::spawn_blocking(restart_daemon_process_blocking)
        .await
        .map_err(|e| ipc::ui_err("ui.err_restart", &[("err", &e)]))?;
    if outcome.is_err() {
        manager.set(&app, ServiceState::Unreachable, Some("restart failed"));
    }
    outcome
}

/// 等它起来的**宽限期**：不是"多久算失败"，而是"多久算彻底没救"。
///
/// 现场数据（2026-10-03 真机，验收人机器 + 诊断包）：
/// - 壳杀掉旧 daemon 后由 launchd 重拉；launchd 对反复退出的 job 有重拉节流
///   （本仓 plist 没设 `ThrottleInterval` ⇒ 吃默认值，10s 量级）
/// - 新实例的 **socket 在 spawn 后 ~0.7s 就起来**（`status` 立刻可答）；其后
///   启动对账（SYNC-01/IDX-01）还要 ~18s，但**不挡 `status`**
///   ⇒ 需要的是"10s 量级 + 一点余量"，而**不是**把它当失败阈值用。
const RESTART_GRACE: std::time::Duration = std::time::Duration::from_secs(90);

fn restart_daemon_process_blocking() -> Result<Value, String> {
    // 1) 杀前读当前 daemon 版本——复活后拿它跟新版本对比。
    let old_version = ipc::DaemonHandle::discover()
        .and_then(|d| d.call("status", json!({})))
        .ok()
        .and_then(|v| {
            v.get("version")
                .and_then(|x| x.as_str())
                .map(str::to_string)
        });
    // 2) 杀进程——与停服务同一个 `stop_bundled_daemon`（B7 #1043：按 sidecar
    //    完整路径），但绝不做任何 uninstall_autostart。
    // QA-09 迁移（#211）：这处**认真判错**（另两个调用点是 best-effort）。
    // 「进程本来就没在跑」不是失败——判据在 platform 里。DESK-25 (#208)
    // 就是因为这条判据被抄散、其中一处没判，把「没杀掉」当成杀成功、
    // 紧接着去 spawn 第二个 daemon 才出的事。
    //
    // #667 / #732：有 LaunchAgent 时**不再 pkill 等 KeepAlive 复活**——那条路吃
    // launchd 的重拉节流（10s 量级，DESK-44 假失败的根），而且杀不到一次性 spawn
    // 的野生实例。改为：野生实例先退位 + `kickstart -k`（launchd 立刻按磁盘上的
    // 文件拉新的），内核从此归 launchd 托管。走不通才退回下面的老路。
    if resident_service_available() {
        bring_up_daemon(true).map_err(|e| ipc::ui_err("ui.err_restart", &[("err", &e)]))?;
    } else {
        restart_by_kill_and_respawn()?;
    }
    // 4) 等它**答上** `status`（每 500ms，最长 RESTART_GRACE）。
    //    答上 = 有结论（版本变了 or 没变）；一直没答上 = `still_starting`，
    //    **不谎报失败**——前端按"正在启动中"呈现，靠 3 秒状态轮询自然收口。
    let deadline = std::time::Instant::now() + RESTART_GRACE;
    let mut answered = false;
    let mut new_version = None;
    loop {
        if let Ok(v) = ipc::DaemonHandle::discover().and_then(|d| d.call("status", json!({}))) {
            answered = true;
            new_version = v
                .get("version")
                .and_then(|x| x.as_str())
                .map(str::to_string);
            break;
        }
        if std::time::Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    Ok(restart_outcome(
        old_version.as_deref(),
        new_version.as_deref(),
        answered,
    ))
}

/// DAE-04 原路径（没有服务管理器时，`ServiceMode::UserAutostart`）：杀进程，再显式拉一次。
fn restart_by_kill_and_respawn() -> Result<(), String> {
    stop_bundled_daemon().map_err(|e| ipc::ui_err("ui.err_kill_old", &[("err", &e)]))?;

    // 3) 被杀之后系统会不会自己把它拉回来，取决于常驻方式：
    //    LaunchAgent 的 KeepAlive 与计划任务看门狗会（macOS / Windows），
    //    `UserAutostart` 兜底实现不会——后者必须显式重新拉起一次（一次性 spawn，不碰 autostart
    //    注册，注册从头到尾没动过，这正是本命令的设计要点）。
    //
    //    ⚠️ 这一句在 Linux 上是**行为改变**，已在 PR 里登记：迁移前
    //    Linux 走的是原来那个 unix 分支、杀完不拉起，然后下面那段等待必然
    //    超时报错（Linux 没有任何东西会复活它）。桌面壳在 Linux 上不是发布
    //    形态，但既然改了就写明，不混在"纯搬家"里带过去。
    if platform::hosting().service_mode() == platform::ServiceMode::UserAutostart {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let sidecar = exe
            .parent()
            .ok_or("no parent dir")?
            .join(platform::hosting().daemon_executable_name());
        if !sidecar.is_file() {
            return Err(ipc::ui_err(
                "ui.err_sidecar_missing",
                &[("path", &sidecar.display())],
            ));
        }
        platform::command(&sidecar)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .stdin(std::process::Stdio::null())
            .spawn()
            .map_err(|e| ipc::ui_err("ui.err_restart", &[("err", &e)]))?;
    }
    Ok(())
}

/// DAE-04 + DESK-44 (#606)：组装重启结果（纯函数，单测覆盖）。
///
/// 三个事实分开说，前端才有机会**不撒谎**：
/// - `changed=true`：答上了且版本确实变了 ⇒ 真成功
/// - `still_starting=true`：宽限期内 daemon **还没答上** ⇒ **不说失败**（现场就是
///   "假失败真成功"），界面显示"正在启动中"并靠 3 秒轮询收口
/// - 两者都 false：答上了但版本没变 ⇒ 磁盘上的服务文件没更新（一种**事实**，
///   不是猜测）
fn restart_outcome(old_version: Option<&str>, new_version: Option<&str>, answered: bool) -> Value {
    json!({
        "old_version": old_version,
        "new_version": new_version,
        "changed": answered
            && match (old_version, new_version) {
                // 复活了但版本没变 → 文件没更新，不算成功。
                (Some(old), Some(new)) => old != new,
                // 杀前没读到（服务本来就没在跑）或杀后读到——重启本身有进展。
                _ => new_version.is_some(),
            },
        "still_starting": !answered,
    })
}

/// 库目录：平台 config 里的 `data_dir`，没配置则退回平台数据目录。**只读**，
/// 不依赖常驻服务在线（#1059）——「打开照片库」「诊断包落点」共用这一口径。
fn configured_library_dir(platform_dir: &std::path::Path) -> std::path::PathBuf {
    ipc::read_config_data_dir(platform_dir)
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| platform_dir.to_path_buf())
}

/// 给「打开照片库」用：库目录必须是真实存在的目录，否则 keyed 错误
/// （前端用 `errText` 翻成人话，不透出系统原文与路径）。
fn existing_library_dir(platform_dir: &std::path::Path) -> Result<String, String> {
    let dir = configured_library_dir(platform_dir);
    if dir.is_dir() {
        Ok(dir.to_string_lossy().into_owned())
    } else {
        Err(ipc::ui_err("ui.library_dir_unknown", &[]))
    }
}

/// #1059：照片库只是磁盘上的目录，打开它不需要后台服务。壳从平台 config 只读
/// 解析库目录（与服务在线时 `status.library_dir` 同源：daemon 也读这份 config），
/// 服务停止时「打开照片库」照样可用。
#[tauri::command]
fn library_dir() -> Result<String, String> {
    existing_library_dir(&platform::adapter().data_dir())
}

/// 诊断包由 daemon 组装并脱敏（#1042 / #1045）：壳只调内置 daemon 的
/// `diag export --out <库目录>/ppf-logs.zip --app-version <壳版本>`。
///
/// DESK-10 的核心不变量由 daemon 一侧守：常驻服务不在线**不是失败路径**，包照出
/// （少三份 JSON、多一份说明），所以这个按钮在 daemon 起不来时照样能用——
/// `diag export` 是独立的短进程，不依赖常驻服务。脱敏规则只有 daemon 一份
/// （`crates/daemon/src/redact.rs`），壳不再二次脱敏。
///
/// 落盘位置与文件名沿用 `<库目录>/ppf-logs.zip`：库目录取 config 里的 `data_dir`，
/// 没配置则退回平台数据目录。返回值就是 daemon 的 `{"zip","daemon_reachable"}`。
#[tauri::command]
fn export_logs_bundle(app: tauri::AppHandle) -> Result<Value, String> {
    let library = configured_library_dir(&platform::adapter().data_dir());
    daemon_cli::diag_export(
        &daemon_cli::bundled_sidecar()?,
        &library.join("ppf-logs.zip"),
        &shell_version(&app),
    )
}

/// 内置服务程序自报版本（`--version --json`；kernel 对账用）。取不到 → None，
/// 绝不因此让别的流程失败。
fn sidecar_daemon_version() -> Option<String> {
    daemon_cli::probe_version(&daemon_cli::bundled_sidecar().ok()?).ok()
}

// ── #667：壳启动时自动换内核 ─────────────────────────────────────────
//
// 现场（2026-10-08 取证）：dmg 覆盖安装（替换 /Applications/P-Pass.app）后重开，
// 壳是新的、内核仍是覆盖前就在跑的旧进程——launchd 不会因为磁盘上文件换了就
// 重拉它，用户只能点「重启后台服务」。新壳启动时自己对一次账：内核比磁盘上
// 的 sidecar 旧（或不归 launchd 管，#732 ①）就自动换，不需要按钮。
//
// 两个既有语义先于"换"：
// ① 用户主动停过服务（`desktop-user-stopped`）⇒ 一律不动；
// ② 正在传输（daemon 给的 `status.transfer_active`，#1044——与设备行
//    「传输中」同一信号，NET-05）⇒ 推迟，传输停下来连续两次（~20s）才换；
//    推迟期间界面给事实句（`ui.kernel_converge_deferred`），不是失败。

/// 自动换内核的阶段（给前端呈现；`kernel-convergence` 事件 + 同名查询命令）。
static KERNEL_CONVERGENCE: std::sync::Mutex<&'static str> = std::sync::Mutex::new("idle");
const EVENT_KERNEL_CONVERGENCE: &str = "kernel-convergence";
const KERNEL_CONVERGE_POLL: std::time::Duration = std::time::Duration::from_secs(10);

fn set_kernel_phase(app: &tauri::AppHandle, phase: &'static str) {
    if let Ok(mut p) = KERNEL_CONVERGENCE.lock() {
        *p = phase;
    }
    let _ = app.emit(EVENT_KERNEL_CONVERGENCE, phase);
}

/// 前端挂载时读一次（事件可能在监听挂上之前就发过了）。
#[tauri::command]
fn kernel_convergence_phase() -> &'static str {
    KERNEL_CONVERGENCE.lock().map(|p| *p).unwrap_or("idle")
}

// #1044 B13：版本关系只有一份实现（crates/version-cmp，daemon 共用）。
use version_cmp::version_cmp;

fn gather_kernel_facts() -> KernelFacts {
    let handle = ipc::DaemonHandle::discover().ok();
    let status = handle
        .as_ref()
        .and_then(|h| h.call("status", json!({})).ok());
    KernelFacts {
        running_version: status
            .as_ref()
            .and_then(|s| s["version"].as_str().map(str::to_string)),
        running_pid: status
            .as_ref()
            .and_then(|s| s["pid"].as_u64())
            .map(|p| p as u32),
        on_disk_version: sidecar_daemon_version(),
        resident_registered: resident_service_available(),
        resident_pid: platform::hosting().resident_daemon_pid(),
        user_stopped: is_user_stopped(&platform::adapter().data_dir()),
        // #1044：是否正在传输由 daemon 给结论（status.transfer_active）。读不到
        // （旧内核没有这个字段）按「没在传」——换内核是幂等对账，Flow 可续传。
        transfer_active: status
            .as_ref()
            .and_then(|s| s["transfer_active"].as_bool())
            .unwrap_or(false),
    }
}

/// #1046（S-8 / S-11）：新壳启动时的幂等对账，一条线程里**按顺序**跑——更新流程
/// 「停 → 替换 → 重启壳 → 新壳对账」的最后一步就是它：
/// 1. 开机自启登记对账（`distribution::reconcile_autostart_registration`）：指向
///    当前安装、内容是本版本的（含 launchd 日志落点）；用户停过就只撤不写。
///    原先 daemon 接管旧实例后自己重装登记，这份职责归到这里。
/// 2. 内核对账（#667）：内核比磁盘旧 / 不归服务管理器管 ⇒ 换；一直不可达 ⇒ 按自愈
///    判据拉起（不是用户停的才拉）。原先由旧壳的 `resume_daemon_after_update` 先拉。
///
/// 先 1 后 2：登记重写（bootout + bootstrap）本身会重启 launchd 那份内核，与换内核
/// 的 `kickstart -k` 并发会连着重启两次。
fn startup_reconcile(app: tauri::AppHandle) {
    reconcile_autostart_registration();
    resume_after_update(&app);
    converge_kernel_on_startup(app);
}

/// #1060「更新后恢复」：更新前为替换文件暂停了常驻服务（登记保留），新壳起来后
/// 把它拉回来——直接就是新内核，不再经过「旧内核被 KeepAlive 拉起、再被换一次」。
/// 判据见 `update_resume_needed`（用户停过的保持停止）。排在登记对账之后：登记
/// 被重写时那一下 bootstrap 已经起了服务，这里看到在线就不动，避免并发重启。
fn resume_after_update(app: &tauri::AppHandle) {
    if !update_resume_needed(
        &platform::adapter().data_dir(),
        resident_service_available(),
        daemon_online(),
    ) {
        return;
    }
    match self_heal_now(app, "resume after update") {
        Ok(true) => eprintln!("#1060: 新壳启动，已把常驻服务拉回"),
        Ok(false) => eprintln!("#1060: 新壳启动，按判据不拉"),
        Err(e) => eprintln!("#1060: 新壳启动，拉回常驻服务失败：{e}"),
    }
}

/// 等内核答上 status，再按判据换（#667）。
fn converge_kernel_on_startup(app: tauri::AppHandle) {
    // 内核可能还没起来（登录时壳比内核先就绪）——最多等 90s。一直不答上就按自愈
    // 判据拉一次（#1046：不依赖前端是否已加载、是否已触发自愈）。
    let deadline = std::time::Instant::now() + RESTART_GRACE;
    while !daemon_online() {
        if std::time::Instant::now() >= deadline {
            // 与前端自愈同一道门：只有服务状态是 Unreachable（配置过、已登记、不是
            // 用户停的、过了启动宽限仍连不上）才拉。Stopped（向导中途退出 / 用户
            // 停过）与 NotConfigured 是用户动作的事——拉起来会把人踢出向导。
            let manager = app.state::<ServiceStateManager>().inner().clone();
            if manager.current() != ServiceState::Unreachable {
                eprintln!(
                    "#1046: 内核一直不可达，服务状态为 {}，不在启动对账里拉",
                    manager.current().as_str()
                );
                return;
            }
            match self_heal_now(&app, "startup reconcile") {
                Ok(true) => eprintln!("#1046: 内核一直不可达，启动对账已按自愈判据拉起"),
                Ok(false) => eprintln!("#1046: 内核一直不可达，按判据不拉（未配置或用户停过）"),
                Err(e) => eprintln!("#1046: 内核一直不可达，启动对账拉起失败：{e}"),
            }
            return;
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    let mut was_deferred = false;
    let mut idle_after_defer = 0u32;
    loop {
        let facts = gather_kernel_facts();
        match kernel_convergence_verdict(&facts) {
            KernelVerdict::InSync => {
                eprintln!("#667: 内核与磁盘一致（{:?}），不动", facts.running_version);
                if was_deferred {
                    set_kernel_phase(&app, "idle");
                }
                return;
            }
            KernelVerdict::Skip(why) => {
                eprintln!("#667: 不换内核：{why}（{facts:?}）");
                if was_deferred {
                    set_kernel_phase(&app, "idle");
                }
                return;
            }
            KernelVerdict::Defer => {
                eprintln!("#667: 正在传输，推迟换内核");
                was_deferred = true;
                idle_after_defer = 0;
                set_kernel_phase(&app, "deferred");
            }
            KernelVerdict::Converge(why) => {
                // 推迟过的：传输停下来要连续确认两次，避免在两张照片的间隙里下手。
                if was_deferred && idle_after_defer < 1 {
                    idle_after_defer += 1;
                } else {
                    eprintln!(
                        "#667: 自动换内核：{why}（{:?} → {:?}）",
                        facts.running_version, facts.on_disk_version
                    );
                    set_kernel_phase(&app, "restarting");
                    let outcome = restart_daemon_process_blocking();
                    let after = gather_kernel_facts();
                    let ok = kernel_convergence_verdict(&after) == KernelVerdict::InSync;
                    eprintln!(
                        "#667: 换完：{outcome:?}；对账 {}（{after:?}）",
                        if ok { "一致" } else { "仍不一致" }
                    );
                    set_kernel_phase(&app, if ok { "done" } else { "failed" });
                    return;
                }
            }
        }
        std::thread::sleep(KERNEL_CONVERGE_POLL);
    }
}

pub fn run() {
    // DESK-68 (#996)：发布版只许从正式安装位置运行——排在**一切**之前（搬数据
    // 目录、单实例、拉 daemon、写登记都在后面），不在位置就提示后退出，什么都
    // 不碰。开发构建（debug）不拦。
    if !cfg!(debug_assertions) && !running_from_install_location() {
        return;
    }

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
            service_state,
            wizard_state,
            platform_ux,
            update_failure_key,
            power_hint,
            open_power_settings,
            disable_auto_sleep,
            write_config,
            set_library_dir,
            start_daemon,
            daemon_startup_error,
            stop_daemon,
            pause_daemon_for_update,
            pending_shell_version,
            relaunch_shell,
            self_heal_daemon,
            resume_after_failed_update,
            update_failure_state,
            clear_update_failure,
            restart_daemon_process,
            kernel_convergence_phase,
            export_logs_bundle,
            library_dir,
            allow_media_scope,
            notify_system,
            set_tray_locale
        ])
        .setup(|app| {
            // DESK-63 (#946): register the state owner BEFORE the event
            // stream starts. The stream's handshake and the stop/start
            // commands all write through this one object.
            let _ = app.manage(UpdatePause::default());
            let _ = app.manage(ServiceStateManager::new(
                initial_service_state(),
                service_state::desktop_log_path(&platform::adapter().data_dir()),
            ));
            // IPC-02: 启动即订阅——daemon 事件驱动 UI（扫码即时切弹窗、
            // 备份落地即时刷新），不依赖前端渲染时序。
            start_event_stream(app.handle().clone());
            // UPD-06 (#616)：把壳登记成登录项（写 plist；下一次登录起由 launchd 接管，
            // 从那时起 kickstart 才是可用路径）。独立线程：只做一次文件读写。
            std::thread::spawn(register_shell_login_item);
            // #1046：新壳启动对账——先开机自启登记（#604，含老版本 plist 重新登记），
            // 再内核（#667 自动换 / 一直不可达按自愈判据拉起）。独立线程：会动
            // launchctl、要等内核，不该堵启动。
            {
                let app = app.handle().clone();
                std::thread::spawn(move || startup_reconcile(app));
            }
            // I18N-03 (#492)：文案取自 assets/i18n（见 TRAY_ITEMS）；前端
            // 报上语言后 set_tray_locale 会再改一次字。
            let locale = system_tray_locale();
            let mut tray_items = Vec::with_capacity(TRAY_ITEMS.len());
            for (id, key) in TRAY_ITEMS {
                let item = MenuItem::with_id(app, id, tray_text(locale, key), true, None::<&str>)?;
                tray_items.push((key, item));
            }
            // 从 TRAY_ITEMS 整体收集，不按下标手写——加一项就自动进菜单。
            let menu_refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> = tray_items
                .iter()
                .map(|(_, item)| item as &dyn tauri::menu::IsMenuItem<tauri::Wry>)
                .collect();
            let menu = Menu::with_items(app, &menu_refs)?;
            app.manage(TrayMenuItems(tray_items));
            // ICON-01: 托盘用 beast 全实线纯黑版 + 模板标记——macOS 系统按
            // 深浅色自动反色（碳纹版 22px 会糊，模板图标不渲染颜色）。
            let tray_icon =
                tauri::image::Image::from_bytes(include_bytes!("../icons/tray-icon.png"))
                    .expect("tray icon bytes");
            TrayIconBuilder::with_id("main")
                .icon(tray_icon)
                .icon_as_template(platform::adapter().tray_icon_is_template())
                // DESK-59 (#876)：Windows 上就是 NOTIFYICONDATA 的 szTip——悬停
                // 提示，也是读屏 / UI Automation 读到的名字。不设的话 Win11
                // 「隐藏的图标」折叠区里是一个没名字的图标。
                .tooltip("P-Pass")
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
                        // DESK-28：与左键回调同一组三步。这条路径（右键 →
                        // 显示）比左键更常用，漏了 unminimize 的话最小化的
                        // 窗口点了没反应。
                        bring_main_window_to_front(app);
                    }
                    id if id == TRAY_EXPORT_LOGS => {
                        // #550：诊断包入口从设置页收进托盘。先把窗口拉起来
                        // 再让前端导出——结果（路径 + 「只发给开发者」的
                        // 提醒，或失败原因）走窗口里的 toast，窗口藏着时
                        // 用户看不见；系统通知（notify_system）只承载短提醒，
                        // 不承载带路径的导出结果。导出本身仍是前端 invoke export_logs_bundle，
                        // 不另开第二条导出路径。
                        bring_main_window_to_front(app);
                        let _ = app.emit(EVENT_EXPORT_LOGS_REQUESTED, ());
                    }
                    "stop" => {
                        // DESK-36 (#456)：托盘停止和窗口里的按钮走同一个
                        // stop_daemon（同一份「用户主动停止」标记），停完
                        // 通知前端立刻刷新状态点——结果（含失败原因）一起带过去。
                        // 放到后台线程：要等进程退干净（最长 5s），不能卡住菜单事件循环。
                        let app = app.clone();
                        std::thread::spawn(move || {
                            let result = stop_daemon_now();
                            if result.is_ok() {
                                let manager = app.state::<ServiceStateManager>().inner().clone();
                                manager.set(&app, ServiceState::Stopped, Some("tray stop"));
                            }
                            let _ = app.emit("service-stopped", result.err());
                        });
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
                //   2. 要不要提示由适配器能力回答（`platform_ux`，#1043），
                //      本文件不判断平台。
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
mod business_rules_table;

#[cfg(test)]
mod tests {
    use super::*;

    /// #1060：暂停窗口只由本壳开关；默认不在窗口里（新壳启动对账照常拉起）。
    #[test]
    fn update_pause_window_opens_and_closes() {
        let p = UpdatePause::default();
        assert!(!p.active(), "新壳不在暂停窗口里");
        p.begin();
        assert!(p.active());
        p.end();
        assert!(!p.active(), "安装失败后必须能退出窗口，否则永不自愈");
    }

    /// #1060：自愈命令在暂停窗口里必须先看窗口再拉；失败恢复命令必须先关窗口。
    /// 反证：删掉 self_heal_daemon 里的 active() 判断，或 resume 里的 end() → 红。
    #[test]
    fn self_heal_respects_update_pause_window() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap();
        let heal = product.split("fn self_heal_daemon(").nth(1).unwrap();
        let heal = &heal[..heal.find("\n}\n").unwrap()];
        assert!(heal.contains("UpdatePause>().active()"));
        let resume = product
            .split("fn resume_after_failed_update(")
            .nth(1)
            .unwrap();
        let resume = &resume[..resume.find("\n}\n").unwrap()];
        let end_at = resume.find("UpdatePause>().end()").expect("先结束暂停窗口");
        assert!(end_at < resume.find("self_heal_now").unwrap());
        let pause = product.split("fn pause_daemon_for_update(").nth(1).unwrap();
        let begin_at = pause
            .find("UpdatePause>().begin()")
            .expect("暂停前进入窗口");
        assert!(begin_at < pause.find("pause_resident_daemon").unwrap());
    }

    /// #809：外壳自报版本（诊断包）只认 tauri `package_info`——
    /// 它是发布构建经 `--config` 注入、与 daemon 同源的那个号。`CARGO_PKG_VERSION`
    /// 是 Cargo.toml 里的号，发布构建不改它，test tag 时与 daemon 错开。
    #[test]
    fn shell_reports_tauri_package_version_not_cargo_pkg_version() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap();
        let banned = concat!("env!(\"CARGO_PKG", "_VERSION\")");
        assert!(
            !product.contains(banned),
            "外壳生产代码不许再用 {banned} 自报版本——改用 shell_version(app)"
        );
        assert!(product.contains("app.package_info().version.to_string()"));
    }

    // ── I18N-03 (#492)：托盘文案 + keyed 错误 ─────────────────────────

    /// 把一条 keyed 错误按某种语言渲染成整句（前端 errText 的等价物，含
    /// 参数本身是 keyed 错误时的递归）。老测试据此仍能对**中文原文**断言：
    /// 只搬字不改措辞，zh 渲染结果必须和搬迁前的 format! 逐字相同。
    fn render_err(locale: &str, e: &str) -> String {
        // 与前端 errText 同一判据：以 { 开头、能解析、带字符串 key 才算。
        let parsed = e
            .starts_with('{')
            .then(|| serde_json::from_str::<Value>(e).ok())
            .flatten();
        let Some(v) = parsed.filter(|v| v["key"].is_string()) else {
            return e.to_string();
        };
        let key = v["key"].as_str().unwrap_or_default();
        let mut out = tray_text(locale, key);
        for (name, val) in v["params"].as_object().expect("params 必须是对象") {
            let val = render_err(locale, val.as_str().expect("参数值必须是字符串"));
            out = out.replace(&format!("{{{name}}}"), &val);
        }
        out
    }

    /// B10（#1043）：新建库默认目录 =「图片」目录 + 固定英文名，与界面语言
    /// 无关。反证：名字改回「P-Pass 家庭照片库」或随语言取 → 红。
    #[test]
    fn default_library_dir_is_a_fixed_english_name_under_pictures() {
        let pictures = std::path::PathBuf::from("/Users/x/Pictures");
        assert_eq!(
            default_library_dir(Some(pictures.clone())),
            pictures.join("P-Pass Library")
        );
        // 读不到「图片」目录：退回当前目录，名字不变。
        assert_eq!(
            default_library_dir(None),
            std::path::PathBuf::from(".").join("P-Pass Library")
        );
    }

    /// B6（#1043）：只有系统语言明确是中文才用中文，读不到 / 空 / 其他语言一律
    /// 英文。反证：恢复「空串默认中文」→ `None` 与 `""` 两条红。
    #[test]
    fn tray_locale_is_chinese_only_when_the_system_says_so() {
        assert_eq!(tray_locale(None), "en");
        for (lang, want) in [
            ("zh", "zh"),
            ("zh-CN", "zh"),
            ("zh-Hans", "zh"),
            ("zh-Hans-CN", "zh"),
            ("zh_CN.UTF-8", "zh"),
            ("ZH-TW", "zh"),
            ("", "en"),
            ("en", "en"),
            ("en-US", "en"),
            ("en_US.UTF-8", "en"),
            ("ja-JP", "en"),
        ] {
            assert_eq!(tray_locale(Some(lang)), want, "{lang:?}");
        }
    }

    /// DESK-68 (#996)：位置检查必须排在 run() 的最前面——搬数据目录、单实例、
    /// 拉 daemon、写登记都得在它之后，不在正式位置时一样都不能碰。
    #[test]
    fn install_location_gate_runs_before_anything_else() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap();
        let run = &product[product.find("pub fn run() {").expect("run()")..];
        let gate = run
            .find("running_from_install_location()")
            .expect("run() 调位置检查");
        for later in ["migrate_legacy_data_dir()", "tauri::Builder::default()"] {
            let at = run
                .find(later)
                .unwrap_or_else(|| panic!("run() 里应有 {later}"));
            assert!(gate < at, "位置检查必须在 {later} 之前");
        }
        assert!(
            run[..gate].contains("!cfg!(debug_assertions)"),
            "只拦发布版，开发构建不拦"
        );
    }

    /// DESK-68 (#996)：提示文案两种语言都在共享字典里（不是 key 本身）。
    #[test]
    fn install_location_copy_comes_from_the_shared_dictionary() {
        for key in [
            "ui.install_location_required_title",
            "ui.install_location_required",
            "ui.install_location_required_win",
        ] {
            for locale in ["en", "zh"] {
                assert_ne!(tray_text(locale, key), key, "{locale}: {key}");
            }
        }
    }

    #[test]
    fn tray_menu_copy_comes_from_the_shared_dictionary() {
        for (_, key) in TRAY_ITEMS {
            for locale in ["en", "zh"] {
                let text = tray_text(locale, key);
                assert_ne!(text, key, "{locale}.json 缺托盘 key {key}");
                assert!(!text.is_empty(), "{locale}.json 的 {key} 是空串");
            }
        }
        // 中文原文逐字不变；英文不许混进中文。
        let zh: Vec<String> = TRAY_ITEMS.iter().map(|(_, k)| tray_text("zh", k)).collect();
        assert_eq!(
            zh,
            ["打开 P-Pass", "导出诊断包", "停止后台服务", "退出 App"]
        );
        for (_, key) in TRAY_ITEMS {
            let en = tray_text("en", key);
            assert!(
                !en.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)),
                "托盘英文混进了中文：{key} = {en}"
            );
        }
    }

    /// #550：托盘里有「导出诊断包」，且点击后发出的事件前端真的在听——
    /// 事件名两边各写一份字面量，改了一边另一边就静默失联，这里把两边钉在一起。
    #[test]
    fn tray_export_logs_item_is_wired_to_the_frontend() {
        let ids: Vec<&str> = TRAY_ITEMS.iter().map(|(id, _)| *id).collect();
        assert!(
            ids.contains(&TRAY_EXPORT_LOGS),
            "托盘缺导出诊断包项：{ids:?}"
        );
        let unique: std::collections::HashSet<&str> = ids.iter().copied().collect();
        assert_eq!(unique.len(), ids.len(), "托盘菜单 id 重复：{ids:?}");
        assert_eq!(tray_text("zh", "ui.tray_export_logs"), "导出诊断包");
        assert_eq!(tray_text("en", "ui.tray_export_logs"), "Export Diagnostics");

        let app = include_str!("../../src/App.svelte");
        assert!(
            app.contains(&format!("listen(\"{EVENT_EXPORT_LOGS_REQUESTED}\"")),
            "App.svelte 没有监听 {EVENT_EXPORT_LOGS_REQUESTED}，托盘点了没反应"
        );

        // 菜单必须从 TRAY_ITEMS 整体收集：按下标手写时加了项也进不了菜单，
        // 而上面的断言照样全绿。
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap();
        assert!(
            !product.contains("&tray_items[0]"),
            "托盘菜单又按下标手写了"
        );
    }

    /// 壳里每个 `ui_err("…")` 引用的 key，两份字典都得有——diag 的测试只管
    /// 「注册表 ↔ JSON」，管不到壳实际引用了哪些 key。
    #[test]
    fn every_shell_error_key_is_translated() {
        let mut keys = Vec::new();
        for src in [
            include_str!("lib.rs"),
            include_str!("ipc.rs"),
            include_str!("daemon_cli.rs"),
        ] {
            let product = src.split("#[cfg(test)]").next().unwrap_or(src);
            let mut rest = product;
            // 调用可能被 rustfmt 折成多行：`ui_err(` 之后跳过空白再取字面量。
            while let Some(i) = rest.find("ui_err(") {
                rest = rest[i + "ui_err(".len()..].trim_start();
                let Some(lit) = rest.strip_prefix('"') else {
                    continue; // 函数定义本身（`ui_err(key: &str, …)`）
                };
                let end = lit.find('"').expect("key 的收尾引号");
                keys.push(lit[..end].to_string());
                rest = &lit[end..];
            }
        }
        // 扫描本身失效（比如调用形状变了）时不许空集变绿。
        assert!(keys.len() >= 25, "只扫到 {} 个 ui_err 调用点", keys.len());
        for key in &keys {
            for locale in ["en", "zh"] {
                assert_ne!(tray_text(locale, key), *key, "{locale}.json 缺 {key}");
            }
        }
    }

    #[test]
    fn ui_err_is_the_wire_shape_the_frontend_parses() {
        let inner = ipc::ui_err("ui.err_connect", &[("err", &"refused")]);
        let e = ipc::ui_err(
            "ui.err_register_and_spawn",
            &[("err", &inner), ("spawn_err", &13)],
        );
        let v: Value = serde_json::from_str(&e).unwrap();
        assert!(
            e.starts_with('{'),
            "前端 errText 靠开头的 {{ 认出 keyed 错误：{e}"
        );
        assert_eq!(v["key"], "ui.err_register_and_spawn");
        assert_eq!(v["params"]["spawn_err"], "13");
        assert_eq!(
            render_err("zh", &e),
            "注册服务失败（连接后台服务失败: refused）且直接启动也失败（13）"
        );
        assert_eq!(
            render_err("en", &e),
            "Registering the service failed (Couldn't connect to the background service: refused), \
             and starting it directly failed too (13)"
        );
    }

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
        let src = include_str!("lib.rs").replace("\r\n", "\n");
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

    // DESK-19 (#168) 的回归锁「桌面壳不得用 console 子系统程序拉起系统 UI」
    // 原先是这里的一条源码扫描测试，只扫本文件、只拦 cmd / powershell。
    // DESK-33 (#325) 起改由 clippy 的 `disallowed-methods`（clippy.toml）
    // 守住：产品代码启动子进程一律走 `platform::command`，Windows 上带
    // CREATE_NO_WINDOW。要拉起系统 UI 仍走 `tauri_plugin_opener`（ShellExecuteExW，
    // 根本不起子进程，见 open_power_settings 的注释）。

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

    /// QA-16（#326）：**向导 invoke 的是这一层，测试也必须打这一层**——
    /// 内部函数可以对、命令本体却返回 None / 读错文件 / 被整个摘掉，只有打
    /// 命令本体的测试知道。
    ///
    /// #1043：落点向平台适配器要（`daemon_log_paths().stderr`），测试不写死
    /// 路径、不摆 plist。把适配器算路径用到的环境变量（macOS 的 HOME、Windows
    /// 的 `%LOCALAPPDATA%`/`%APPDATA%`）都指到 tempdir，用完还原；全 crate 没有
    /// 别的测试断言这些变量。
    ///
    /// 反证：`daemon_startup_error()` 体内改成 `None`（或改回读 plist）→ 本测试红。
    #[test]
    fn the_startup_error_command_itself_surfaces_the_daemon_stderr() {
        let tmp = tempfile::tempdir().unwrap();
        let keys = ["HOME", "LOCALAPPDATA", "APPDATA"];
        let saved: Vec<_> = keys.iter().map(|k| (*k, std::env::var_os(k))).collect();
        for k in keys {
            let dir = tmp.path().join(k);
            std::fs::create_dir_all(&dir).unwrap();
            std::env::set_var(k, &dir);
        }
        let a = platform::adapter();
        let err_file = a.daemon_log_paths(&a.data_dir()).stderr;
        let daemon_error =
            "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";
        let got = err_file.as_ref().map(|f| {
            std::fs::create_dir_all(f.parent().unwrap()).unwrap();
            // 尾部空行 + 前面的正常输出：命令要给出**最后一行非空**的那条。
            std::fs::write(f, format!("starting daemon\n{daemon_error}\r\n\r\n")).unwrap();
            // 命令本体，无参——与渲染进程 `invoke("daemon_startup_error")` 同一条路。
            daemon_startup_error()
        });
        for (k, v) in saved {
            match v {
                Some(v) => std::env::set_var(k, v),
                None => std::env::remove_var(k),
            }
        }
        let Some(err_file) = err_file else {
            return; // 本平台没有 stderr 落点（headless Linux 交给 systemd）。
        };
        assert!(err_file.starts_with(tmp.path()), "{}", err_file.display());
        assert_eq!(
            got.flatten(),
            Some(StartupError {
                key: None,
                detail: daemon_error.to_owned()
            })
        );
    }

    /// #1044：daemon 的 keyed 错误行拆成 key + 原文；不是这个形状的行原样
    /// 当原文、不带 key——壳不靠正则猜原因。
    #[test]
    fn keyed_startup_error_lines_are_split_and_other_lines_pass_through() {
        let keyed = r#"{"error_key":"ui.startup_migration_guidance","detail":"migration: migration 12 was previously applied but is missing in the resolved migrations"}"#;
        assert_eq!(
            parse_startup_error(keyed.to_owned()),
            StartupError {
                key: Some("ui.startup_migration_guidance".into()),
                detail: "migration: migration 12 was previously applied but is missing in the resolved migrations".into(),
            }
        );
        let unkeyed = r#"{"error_key":null,"detail":"boom"}"#;
        assert_eq!(parse_startup_error(unkeyed.to_owned()).key, None);
        let legacy = "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";
        assert_eq!(
            parse_startup_error(legacy.to_owned()),
            StartupError {
                key: None,
                detail: legacy.into()
            }
        );
    }

    #[test]
    fn startup_failure_reads_the_latest_sidecar_stderr_line() {
        let tmp = tempfile::tempdir().unwrap();
        let stderr = tmp.path().join("ppf-daemon.err");
        let daemon_error =
            "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";
        std::fs::write(&stderr, format!("starting daemon\n{daemon_error}\n")).unwrap();
        let paths = platform::DaemonLogPaths {
            stderr: Some(stderr),
            ..Default::default()
        };
        assert_eq!(
            daemon_startup_error_in(&paths).as_deref(),
            Some(daemon_error)
        );
        // 没有落点 / 文件不在：如实 None，不编原因。
        assert_eq!(
            daemon_startup_error_in(&platform::DaemonLogPaths::default()),
            None
        );
        let missing = platform::DaemonLogPaths {
            stderr: Some(tmp.path().join("nope.err")),
            ..Default::default()
        };
        assert_eq!(daemon_startup_error_in(&missing), None);
    }

    /// #1043：服务管理器接的 stdio 只在登记了常驻服务时算数（= 改前「plist 在
    /// 才有路径」）；daemon 自己接的 stderr（Windows）不算服务管理器那对。
    /// 反证：去掉 `service_registered` 判据 → 第二条红；去掉
    /// `stdio_by_service_manager` 判据 → 第三条红。
    #[test]
    fn service_stdio_paths_need_a_registered_service_manager() {
        let launchd = platform::DaemonLogPaths {
            log_file: Some("/d/logs/daemon.log".into()),
            stdout: Some("/h/Library/Logs/p-pass-daemon.log".into()),
            stderr: Some("/h/Library/Logs/p-pass-daemon.err".into()),
            stdio_by_service_manager: true,
        };
        assert_eq!(
            service_stdio_paths(&launchd, true),
            (launchd.stdout.clone(), launchd.stderr.clone())
        );
        assert_eq!(service_stdio_paths(&launchd, false), (None, None));
        let self_captured = platform::DaemonLogPaths {
            stderr: Some(r"C:\d\logs\daemon.err".into()),
            stdio_by_service_manager: false,
            ..launchd.clone()
        };
        assert_eq!(service_stdio_paths(&self_captured, true), (None, None));
    }

    /// 接线：启动时跑对账；换内核先让野生实例退位、再交给服务管理器；手动「立即重启」
    /// 有 LaunchAgent 时也走同一条；一次性 spawn 的日志不再接 null（#732 ③）。
    #[test]
    fn kernel_convergence_is_wired() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap_or(&src);
        let body = |name: &str| {
            let start = product
                .find(&format!("fn {name}("))
                .unwrap_or_else(|| panic!("找不到 fn {name}"));
            let rest = &product[start..];
            rest[..rest.find("\n}\n").expect("函数结尾")].to_string()
        };
        assert!(product.contains("std::thread::spawn(move || startup_reconcile(app));"));
        // #1046：同一条线程先对账登记、再对账内核（登记重写会重启内核，并发会连着重启两次）。
        let startup = body("startup_reconcile");
        let reg = startup
            .find("reconcile_autostart_registration();")
            .expect("先对账登记");
        let kernel = startup
            .find("converge_kernel_on_startup(app);")
            .expect("再对账内核");
        assert!(reg < kernel);
        assert!(
            !product.contains("std::thread::spawn(reconcile_autostart_registration)"),
            "登记对账不许再单开一条与换内核并发的线程"
        );
        assert!(
            product.contains("kernel_convergence_phase,"),
            "查询命令要注册"
        );
        let up = body("bring_up_daemon");
        let retire = up.find("retire_unmanaged_daemon(").expect("先退位野生实例");
        let restart = up
            .find("restart_resident_daemon(kill_running)")
            .expect("再交给服务管理器");
        assert!(retire < restart);
        let manual = body("restart_daemon_process_blocking");
        assert!(manual.contains("if resident_service_available() {"));
        assert!(manual.contains("bring_up_daemon(true)"));
        let oneshot = body("spawn_bundled_daemon_oneshot");
        assert!(oneshot.contains("oneshot_stdio()"));
        assert!(
            !oneshot.contains(".stdout(std::process::Stdio::null())")
                && !oneshot.contains(".stderr(std::process::Stdio::null())"),
            "#732 ③：一次性 spawn 的 stdout/stderr 不许再直接接 null"
        );
    }

    // DAE-04: 版本真的变了 → changed=true（真成功，前端报「已重启」）。
    #[test]
    fn restart_outcome_marks_version_change() {
        let v = restart_outcome(Some("v0.3.3-test.1"), Some("0.3.4"), true);
        assert_eq!(v["changed"], true);
        assert_eq!(v["still_starting"], false);
        assert_eq!(v["old_version"], "v0.3.3-test.1");
        assert_eq!(v["new_version"], "0.3.4");
    }

    // DAE-04: 复活但版本没变 = 磁盘上的服务文件其实没更新——必须报为
    // 未变更，前端明说（Clash Verge Rev #5451 的教训），不假装成功。
    #[test]
    fn restart_outcome_same_version_is_not_a_change() {
        let v = restart_outcome(Some("0.3.3"), Some("0.3.3"), true);
        assert_eq!(v["changed"], false);
        assert_eq!(v["still_starting"], false, "答上了就不是「还在启动」");
    }

    // DAE-04: 杀前 daemon 没在跑（读不到版本）、杀后起来了 → 也算
    // 有进展（前端报「已启动」）。
    #[test]
    fn restart_outcome_starts_an_offline_daemon() {
        let v = restart_outcome(None, Some("0.3.3"), true);
        assert_eq!(v["changed"], true);
        assert_eq!(v["old_version"], Value::Null);
    }

    // DAE-04: 杀后没读到版本 = 无法验证，不算成功（防御分支——轮询
    // 结束已在上游拦掉，这里兜底语义）。
    #[test]
    fn restart_outcome_without_new_version_is_not_verified() {
        let v = restart_outcome(Some("0.3.3"), None, true);
        assert_eq!(v["changed"], false);
        assert_eq!(v["new_version"], Value::Null);
    }

    /// DESK-44 (#606) 的核心判据：**宽限期内 daemon 还没答上**时，
    /// 不许把它报成"失败"——2026-10-03 真机现场就是"假失败真成功"
    /// （12s 固定预算 vs launchd ~10s 重拉节流 + 启动）。必须分开成
    /// `still_starting=true`，让前端说"正在启动中"。
    ///
    /// 反证：把 `still_starting: !answered` 改成 `false`（或把 changed 写成
    /// `!answered → not changed`）→ 本测试必须红。
    #[test]
    fn restart_outcome_not_answered_yet_is_still_starting_not_a_failure() {
        let v = restart_outcome(Some("0.7.5"), None, false);
        assert_eq!(v["changed"], false);
        assert_eq!(
            v["still_starting"], true,
            "没答上 = 还在启动中，不是失败（#606 现场：假失败真成功）"
        );
        // 杀前也没读到、且始终没答上——同样只是"还在启动中"。
        let v2 = restart_outcome(None, None, false);
        assert_eq!(v2["changed"], false);
        assert_eq!(v2["still_starting"], true);
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
        // 一律带 .exe 后缀：平台 cfg 只许在 crates/platform（arch-check B.2），
        // 本文件不加。Windows 上 spawn 直接被拒（不是有效的
        // Win32 程序），unix 上没有执行位同样被拒——两边都走 Err。
        let fake = tmp.path().join("ppf-daemon.exe");
        std::fs::write(&fake, b"").unwrap();

        assert!(
            fake.is_file(),
            "前提：0 字节文件 is_file() 为真，旧守卫正是这样被绕过的"
        );
        assert_eq!(std::fs::metadata(&fake).unwrap().len(), 0);

        let err = verify_sidecar_runs(&fake).unwrap_err();
        assert!(
            render_err("zh", &err).contains("跑不起来"),
            "错误信息要说清跑不起来：{err}"
        );
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

    /// DESK-59 (#876)：托盘必须有名字——Windows 折叠区里认图标、读屏、回归
    /// SOP 用 UI Automation 找托盘，靠的都是它。
    #[test]
    fn the_tray_icon_has_a_tooltip_name() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap_or(&src);
        let builder = product
            .split("TrayIconBuilder::with_id(\"main\")")
            .nth(1)
            .expect("托盘构建处");
        let chain = builder.split(".build(").next().unwrap();
        assert!(
            chain.contains(".tooltip(\"P-Pass\")"),
            "托盘没设 tooltip（#876）"
        );
    }

    /// stop_daemon / start_daemon 本体走真实 adapter，测试里不能调；这里钉
    /// 接线：停止先落标记（在卸 autostart、杀进程之前，且落不下就返回错误），
    /// 启动清标记。
    #[test]
    fn stop_marks_before_touching_the_process_and_start_clears() {
        // 先归一行尾（#297）：Windows 检出可能是 CRLF，下面按 "\n}\n" 找函数结尾。
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap_or(&src);
        let body = |name: &str| {
            let start = product
                .find(&format!("fn {name}("))
                .unwrap_or_else(|| panic!("找不到 fn {name}"));
            let rest = &product[start..];
            &rest[..rest.find("\n}\n").expect("函数结尾")]
        };
        let stop = body("stop_daemon_now");
        let mark = stop
            .find("set_user_stopped(&platform::adapter().data_dir(), true)?;")
            .expect("stop_daemon_now 必须落「用户主动停止」标记，且失败要返回错误");
        let unregister = stop.find("uninstall_autostart()").expect("卸 autostart");
        let kill = stop.find("stop_bundled_daemon()").expect("杀进程");
        assert!(mark < unregister && mark < kill, "标记必须先于停进程落下");
        // DESK-65 (#957)：撤登记的结果不许丢——真机上 Run 值没删掉、下次开机服务又起来了。
        assert!(
            !stop.contains("let _ = platform::hosting().uninstall_autostart()"),
            "撤销开机自启失败必须报给用户"
        );
        assert!(body("start_daemon")
            .contains("set_user_stopped(&platform::adapter().data_dir(), false)?;"));
        // 托盘停止与窗口按钮必须是同一个实现（同一份标记）。
        assert!(product.contains("let result = stop_daemon_now();"));
    }

    /// #1043：`platform_ux` 原样转述适配器的能力，字段名是与 platformUx.js 的
    /// 契约；且注册进了 invoke_handler（漏注册 = 前端拿不到、向导永远不出现）。
    #[test]
    fn platform_ux_forwards_the_adapter_capabilities() {
        let a = platform::adapter();
        let got = platform_ux();
        assert_eq!(got["close_to_tray_hint"], json!(a.close_to_tray_hint()));
        assert_eq!(got["overlay_titlebar"], json!(a.overlay_titlebar()));
        assert_eq!(
            got["sleep_owner"],
            json!(a.sleep_owner().map(platform::SleepOwner::as_str))
        );
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        assert!(
            src.contains("            platform_ux,\n"),
            "platform_ux 未注册进 invoke_handler"
        );
    }

    /// #1059：库目录由壳只读解析，不经 IPC。config 有 data_dir 用它；没配置退回
    /// 平台目录；目录不存在 → keyed 错误（不含路径/系统原文）。
    /// 反证：existing_library_dir 去掉 is_dir 判断 → 第三条红；configured 不读 config → 第一条红。
    #[test]
    fn library_dir_is_read_from_config_without_the_daemon() {
        let platform = tempfile::tempdir().unwrap();
        let lib = tempfile::tempdir().unwrap();
        std::fs::write(
            platform.path().join("config.toml"),
            format!("data_dir = '{}'\n", lib.path().display()),
        )
        .unwrap();
        assert_eq!(
            existing_library_dir(platform.path()).unwrap(),
            lib.path().to_string_lossy()
        );
        let bare = tempfile::tempdir().unwrap();
        assert_eq!(
            existing_library_dir(bare.path()).unwrap(),
            bare.path().to_string_lossy()
        );
        std::fs::write(
            platform.path().join("config.toml"),
            "data_dir = '/definitely/not/here/ppass-1059'\n",
        )
        .unwrap();
        let err = existing_library_dir(platform.path()).unwrap_err();
        let v: Value = serde_json::from_str(&err).unwrap();
        assert_eq!(v["key"], "ui.library_dir_unknown");
        assert!(!err.contains("ppass-1059"), "不许透出路径: {err}");
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        assert!(
            src.contains("            library_dir,\n"),
            "library_dir 未注册进 invoke_handler"
        );
    }

    /// #1043：更新失败的「文件被占用」由 Rust 侧按系统错误码判。输入就是前端
    /// 实际拿到的那串——插件的 `Error::Io` 是 transparent，`to_string()` 即
    /// `io::Error` 的 Display。判据注入，所以在任何平台上都能测。
    /// 反证：改回匹配文案（不看错误码）→ 第三条红；判据不再问平台 → 第二条红。
    #[test]
    fn update_failure_key_reads_the_os_error_code() {
        let locked = |c: i32| c == 32;
        let io32 = std::io::Error::from_raw_os_error(32).to_string();
        assert_eq!(os_error_code(&io32), Some(32), "{io32}");
        assert_eq!(
            update_failure_key_with(&io32, locked),
            "ui.update_failed_file_locked"
        );
        let io2 = std::io::Error::from_raw_os_error(2).to_string();
        assert_eq!(update_failure_key_with(&io2, locked), "ui.update_failed");
        // 不是 io 错误（网络、签名……）：哪怕文案里提到「另一个进程」，也只给通用 key。
        assert_eq!(
            update_failure_key_with("Network error: the file is used by another process", locked),
            "ui.update_failed"
        );
        assert_eq!(os_error_code("(os error x)"), None);
        assert_eq!(os_error_code(""), None);
        // 命令本体问的是平台适配器，且注册进了 invoke_handler。
        let a = platform::adapter();
        assert_eq!(
            update_failure_key(io32.clone()),
            if a.is_file_in_use_os_error(32) {
                "ui.update_failed_file_locked"
            } else {
                "ui.update_failed"
            }
        );
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        assert!(src.contains("            update_failure_key,\n"));
    }

    /// 接线：`wizard_state` 把判据结果交给前端，且**不再**把拼判据用的三个原料
    /// 递出去（前端拿到就会忍不住再拼一份）。wizard_state() 本体读真实 data dir，
    /// 不在测试里调。
    #[test]
    fn wizard_state_hands_the_verdict_not_the_ingredients() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let body = product_fn_body(&src, "wizard_state");
        assert!(body.contains("\"show_wizard\": show_wizard("), "{body}");
        for ingredient in ["\"configured\":", "\"installed\":", "\"user_stopped\":"] {
            assert!(!body.contains(ingredient), "不许把 {ingredient} 交给前端");
        }
        assert!(
            body.contains("ServiceState::Running"),
            "在线要读 Rust 持有的服务状态"
        );
    }

    /// #1046（S-11）：更新后拉起 daemon 不再由旧壳的 `resume_daemon_after_update`
    /// 做，改由新壳启动对账（内核一直不可达 ⇒ 按自愈判据拉起）。钉接线：
    /// 命令已删、前端不再调；自愈与启动对账共用 `self_heal_now`，判据先于 spawn；
    /// 自愈不杀在跑的内核。
    #[test]
    fn update_resume_is_the_new_shells_startup_reconcile() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap_or(&src);
        let body = |name: &str| {
            let start = product
                .find(&format!("fn {name}("))
                .unwrap_or_else(|| panic!("找不到 fn {name}"));
            let rest = &product[start..];
            rest[..rest.find("\n}\n").expect("函数结尾")].to_string()
        };
        assert!(!product.contains("fn resume_daemon_after_update("));
        assert!(!include_str!("../../src/App.svelte").contains("resume_daemon_after_update"));
        let heal = body("self_heal_now");
        let gate = heal
            .find("if !self_heal_allowed(&platform::adapter().data_dir()) {")
            .expect("先读盘上的「用户主动停止」标记与配置");
        let spawn = heal
            .find("bring_up_daemon(false)")
            .expect("自愈不杀在跑的内核");
        assert!(gate < spawn, "判据必须在 spawn 之前");
        assert!(body("self_heal_daemon").contains("self_heal_now(&app, "));
        let converge = body("converge_kernel_on_startup");
        let state_gate = converge
            .find("if manager.current() != ServiceState::Unreachable {")
            .expect("启动对账兜底与前端自愈同一道门：只在 Unreachable 时拉");
        let heal_at = converge
            .find("self_heal_now(&app, \"startup reconcile\")")
            .expect("启动对账：内核一直不可达时按自愈判据拉起（不依赖前端）");
        assert!(state_gate < heal_at, "状态门必须在拉起之前");
        // 退路的一次性 spawn：不带任何参数（#1041：`--post-update` 已退役）。
        let up = body("bring_up_daemon");
        assert!(up.contains("spawn_bundled_daemon_oneshot()"));
        let oneshot = body("spawn_bundled_daemon_oneshot");
        assert!(
            !oneshot.contains(".arg("),
            "一次性 spawn 不带任何命令行参数（含已退役的 --post-update）"
        );
    }

    /// UPD-05 (#605)：App.svelte 在 downloadAndInstall 成功路径里调用
    /// relaunch_shell（装完换壳）。#1041 删掉了前端从不 invoke 的 `restart_app`
    /// 命令，这里只保留对 relaunch_shell 调用次序的钉子。
    #[test]
    fn relaunch_shell_is_called_after_install() {
        let app = include_str!("../../src/App.svelte");
        let install = app
            .find("await runUpdate(")
            .expect("App.svelte 缺 runUpdate（下载→暂停→安装）");
        // UPD-06 (#616)：换壳走 relaunch_shell（系统路径 kickstart 优先、壳自己
        // 重启兜底）。
        // ⚠️ 比的是**调用点**：`relaunchShellNow` 的定义体在文件里更靠前，比定义
        // 位置会得出反向结论（本测试第一版就是这么红的）。
        let call = app
            .find("await relaunchShellNow();")
            .expect("App.svelte 缺换壳调用点");
        assert!(call > install, "换壳必须在 runUpdate（install）之后调用");
        assert!(
            app.contains("await invoke(\"relaunch_shell\");"),
            "换壳必须调 relaunch_shell 命令"
        );
    }

    /// UPD-06 (#616)：壳的**登录项**必须在**启动时**写（幂等）。不能等到"要换壳了"
    /// 才写——登录时 launchd 只加载**当时已存在**的 plist，否则这台机器永远等不到
    /// launchd 接管壳，`kickstart` 那条系统路径等于落空。
    ///
    /// 反证：把 setup 里那句 `std::thread::spawn(register_shell_login_item);` 删掉 → 红。
    #[test]
    fn setup_registers_the_shell_login_item() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        assert!(
            src.contains("std::thread::spawn(register_shell_login_item);"),
            "启动时必须登记壳的登录项（否则 launchd 永远接管不到壳）"
        );
        let f = src
            .find("fn register_shell_login_item()")
            .expect("register_shell_login_item 缺失");
        let body: String = src[f..].chars().take(1200).collect();
        assert!(
            body.contains("platform::hosting().register_shell_login_item(&exe)"),
            "DESK-72：怎么登记交给平台层（Windows 也要登记，不能借 launchd 专用的 shell_agent_label 判断）"
        );
        assert!(
            !body.contains("shell_agent_label()"),
            "DESK-72：shell_agent_label 是 launchd 换壳专用，用它当闸门会让 Windows 永远不登记"
        );
        assert!(
            !body.contains("bootstrap"),
            "登记只写 plist、不 bootstrap（RunAtLoad 的 job 一 bootstrap 会立刻再拉一个实例）"
        );
    }

    /// UPD-07 (#617)：换壳的**闸门**测试。
    ///
    /// 两条判据必须同时成立，少一条就会出事故：
    /// ① kickstart 之前必须比对"壳登记指向的可执行文件 == 我自己"——否则会把
    ///    **另一份副本**（旧路径 / 备份目录里的 App）拉起来，比不重启更糟；
    /// ② 必须有退化路径（`tauri::process::restart`），否则开发构建、从 dmg 直跑的
    ///    机器就完全没有换壳能力。
    /// 反证：删掉 `shell_agent_registered_exec` 那句比对，或删掉末尾的
    /// `tauri::process::restart` → 本测试必须红。
    #[test]
    fn relaunch_shell_gates_kickstart_on_registration_pointing_at_us() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let start = src
            .find("fn relaunch_shell(app: tauri::AppHandle)")
            .expect("relaunch_shell 命令缺失");
        // 取函数体前 2000 个**字符**：按字节切会踩 UTF-8 边界（注释是中文）。
        let body: String = src[start..].chars().take(2000).collect();
        assert!(
            body.contains("shell_agent_registered_exec"),
            "换壳前必须先读登记路径（闸门）"
        );
        assert!(
            body.contains("shell_agent_started_us"),
            "闸门：只有 launchd 自己拉起的壳才走 kickstart（否则 -k 无物可杀，只会再拉一个实例）"
        );
        assert!(
            body.contains("Ok(Some(registered)) if registered == exe"),
            "闸门判据必须是『登记路径 == 我自己』"
        );
        assert!(
            body.contains("kickstart_shell_agent"),
            "系统路径要走 kickstart（由 launchd 杀 + 拉）"
        );
        assert!(
            body.contains("tauri::process::restart"),
            "必须有退化路径，否则没有稳定安装位置的机器无法换壳"
        );
        assert!(
            src.contains("relaunch_shell,"),
            "relaunch_shell 未注册进 invoke_handler"
        );
        assert!(
            src.contains("pending_shell_version,"),
            "pending_shell_version 未注册进 invoke_handler"
        );
    }

    /// #1044 B13：「装好的壳 ≠ 运行中的壳」按共享的 Rust 语义判（同核心的
    /// test 包与正式包算不同），同版本或读不到都不提示。
    #[test]
    fn pending_shell_version_uses_the_shared_version_rule() {
        assert_eq!(
            pending_shell_version_of(Some("0.9.8".into()), "0.9.7"),
            Some("0.9.8".into())
        );
        assert_eq!(
            pending_shell_version_of(Some("0.9.7".into()), "0.9.7"),
            None
        );
        assert_eq!(pending_shell_version_of(None, "0.9.7"), None);
        assert_eq!(
            pending_shell_version_of(Some("0.9.12".into()), "0.9.12-test.17"),
            Some("0.9.12".into())
        );
    }

    // ══ #1045：config 与诊断包的写者是 daemon，壳只调子命令 ══════════════
    //
    // 判据本身（退出码 / stdout 形状）在 `daemon_cli::tests`；写入语义（模板、
    // 归一、校验、合并）在 daemon `tests/config_cli.rs`。这里只钉「接线」：三个
    // 命令各自走对子命令，且壳里没有第二条写 config / 打包诊断的路径。
    // G4（tools/arch-check.sh）是同一条约束的门禁版，这条是编译进 cargo test
    // 的快速版。

    fn product_fn_body<'a>(src: &'a str, name: &str) -> &'a str {
        let product = src.split("#[cfg(test)]").next().unwrap();
        let start = product
            .find(&format!("fn {name}("))
            .unwrap_or_else(|| panic!("找不到 fn {name}"));
        let rest = &product[start..];
        let end = rest.find("\n}\n").expect("函数结尾");
        &rest[..end]
    }

    #[test]
    fn config_and_diag_commands_only_call_the_daemon_subcommands() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        for (cmd, call) in [
            ("write_config", "daemon_cli::config_init("),
            ("set_library_dir", "daemon_cli::config_set_library("),
            ("export_logs_bundle", "daemon_cli::diag_export("),
        ] {
            let body = product_fn_body(&src, cmd);
            assert!(body.contains(call), "{cmd} 必须调 {call}：{body}");
            for forbidden in ["fs::write", "create_dir", "OpenOptions", "zip::"] {
                assert!(
                    !body.contains(forbidden),
                    "{cmd} 不许自己 {forbidden}（config / 诊断包只有 daemon 写）"
                );
            }
        }
        // 向导的生效顺序不变：先探活再注册（DESK-29），探活走机读契约。
        assert!(
            product_fn_body(&src, "verify_sidecar_runs").contains("daemon_cli::probe_version("),
            "探活必须走 --version --json"
        );
    }

    // ── #1063：安装失败标记（安装器写、新壳读、用户处理后清）────────────

    #[test]
    fn update_failure_marker_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            read_update_failure_at(dir.path()),
            UpdateFailureState::default(),
            "没有标记 = 没有失败"
        );

        std::fs::write(
            dir.path().join(UPDATE_FAILED_MARKER),
            "install-failed\nversion=0.10.1-dev.1012\nservice=1\n",
        )
        .unwrap();
        let got = read_update_failure_at(dir.path());
        assert!(got.failed);
        assert_eq!(got.version.as_deref(), Some("0.10.1-dev.1012"));
        assert!(got.service_restored);

        clear_update_failure_at(dir.path()).unwrap();
        assert!(!read_update_failure_at(dir.path()).failed, "清掉后不再提示");
        // 幂等：没有标记时再清一次也算成功。
        clear_update_failure_at(dir.path()).unwrap();
    }

    #[test]
    fn update_failure_marker_rejects_garbage_and_service_zero() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(UPDATE_FAILED_MARKER), "hello\nversion=\n").unwrap();
        assert_eq!(
            read_update_failure_at(dir.path()),
            UpdateFailureState::default(),
            "首行不是 install-failed 就当没有失败"
        );

        std::fs::write(
            dir.path().join(UPDATE_FAILED_MARKER),
            "install-failed\nversion=\nservice=0\n",
        )
        .unwrap();
        let got = read_update_failure_at(dir.path());
        assert!(got.failed);
        assert_eq!(got.version, None, "空版本不进横幅");
        assert!(!got.service_restored, "service=0 = 用户停过，没恢复");
    }

    /// 安装器脚本和壳的契约：失败回调必须恢复服务、写标记，而且静默安装
    /// 不弹对话框（提示留给下次启动的横幅）。
    #[test]
    fn installer_hooks_fail_recovery_contract() {
        let hooks = include_str!("../windows/installer-hooks.nsh");
        for needle in [
            "Function .onInstFailed",
            "Function UpdateFailureRecover",
            "Call UpdateFailureRecover",
            "--version --json",
            "${StrStr}",
            "update-failed",
            "desktop-user-stopped",
            "\"$SYSDIR\\schtasks.exe\" /Change /TN \"P-Pass\" /ENABLE",
            "\"$SYSDIR\\schtasks.exe\" /Run /TN \"P-Pass\"",
            "${IfNot} ${Silent}",
        ] {
            assert!(hooks.contains(needle), "installer-hooks.nsh 缺 {needle}");
        }
    }

    /// #1075：安装/卸载都要先关壳、再停 daemon，否则壳会在两次 taskkill
    /// 之间把 daemon 自愈拉回来（安装时还会让文件替换失败）。反证：换回
    /// daemon 在前，本测试红。
    #[test]
    fn install_and_uninstall_kill_shell_before_daemon() {
        let hooks = include_str!("../windows/installer-hooks.nsh");
        for name in ["NSIS_HOOK_PREINSTALL", "NSIS_HOOK_PREUNINSTALL"] {
            let marker = format!("!macro {name}");
            let start = hooks
                .find(&marker)
                .unwrap_or_else(|| panic!("{name} 宏缺失"));
            let end = start
                + hooks[start..]
                    .find("!macroend")
                    .unwrap_or_else(|| panic!("{name} 宏没有结束"));
            let block = &hooks[start..end];
            let shell = block.find("p-pass-desktop.exe").expect("没有杀壳");
            let daemon = block.find("ppf-daemon.exe").expect("没有杀 daemon");
            assert!(
                shell < daemon,
                "{name} 必须先杀 p-pass-desktop 再杀 ppf-daemon（#1075）"
            );
            assert_eq!(
                block.matches("ppf-daemon.exe").count(),
                2,
                "{name} 的 daemon 要补杀一次，盖住壳退出前的短窗口"
            );
        }
    }

    #[test]
    fn update_failure_commands_are_registered() {
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        assert!(src.contains("            update_failure_state,\n"));
        assert!(src.contains("            clear_update_failure,\n"));
        // 横幅的「手动下载」走前端 openUrl，缺这条权限会被 Tauri 直接拒。
        assert!(
            include_str!("../capabilities/default.json").contains("opener:allow-open-url"),
            "capabilities/default.json 缺 opener:allow-open-url"
        );
        assert!(
            include_str!("../capabilities/default.json").contains("opener:allow-default-urls"),
            "capabilities/default.json 缺 opener:allow-default-urls（http/https 作用域）"
        );
    }
}
