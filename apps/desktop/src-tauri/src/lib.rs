//! P-Pass tray shell (T-041, ADR-012): zero business logic — every
//! command is a thin forward to the daemon's local IPC.

mod daemon_logs;
mod ipc;
mod redact;

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

// ── I18N-03 (#492)：托盘菜单文案 ───────────────────────────────────────
// 与前端同一份字典：编译期 include_str! 仓库根的 assets/i18n/*.json，不另开
// 副本。语言判定规则与 `src/lib/i18n.js` 的 `localeFor` 一字不差（zh* → zh，
// 其它 → en，拿不到 → zh）。系统语言由前端报上来（`set_tray_locale`，传的
// 就是它自己按 navigator.language 判出来的那个），所以托盘和窗口永远同一种
// 语言；在前端报到之前（启动后不到一秒），先按 LANG 环境变量猜一次。
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

fn tray_locale(lang: &str) -> &'static str {
    if lang.is_empty() || lang.to_lowercase().starts_with("zh") {
        "zh"
    } else {
        "en"
    }
}

/// 取一条托盘文案；key 缺失时退回 key 本身（与前端 t() 同一兜底）。
fn tray_text(locale: &str, key: &str) -> String {
    let raw = if locale == "zh" { I18N_ZH } else { I18N_EN };
    serde_json::from_str::<Value>(raw)
        .ok()
        .and_then(|v| v.get(key).and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_else(|| key.to_string())
}

/// 已建好的托盘菜单项（key, item），`set_tray_locale` 据此改字。
struct TrayMenuItems(Vec<(&'static str, MenuItem<tauri::Wry>)>);

/// 前端启动时报一次它用的语言，托盘菜单跟着换字。
#[tauri::command]
fn set_tray_locale(app: tauri::AppHandle, lang: String) {
    let locale = tray_locale(&lang);
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
/// frontend (`src/lowSpace.js`), the "how" in the platform adapter
/// (macOS: osascript, best effort; Windows: not implemented yet, no-op).
#[tauri::command]
fn notify_system(title: String, body: String) {
    platform::adapter().notify(&title, &body);
}

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
    let configured_dir = configured_library_dir(&dir);
    json!({
        "configured": dir.join("config.toml").exists(),
        "installed": installed,
        // DESK-36 (#456)：用户主动停了服务。停服会卸 autostart（installed
        // 变 false），没有这一位的话重开 App 会被当成「向导中途退出」打回
        // 完整 onboard（#155 的停服路径）；有了它，前端落回主界面给「启动服务」。
        "user_stopped": is_user_stopped(&dir),
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

/// DESK-27 (#219)：向导预填用的库目录——读回 config 后**先归一**。
///
/// 为什么读侧也要归一（写侧已经归一了）：**存量**配置在本卡合入前就已经
/// 被翻倍过，而向导要在用户重跑之前就把**正确**的路径显示出来 —— 卡面记的
/// 危害之一正是"UI 显示给用户的路径是错的"。写侧归一只能让下一次写入变好，
/// 读侧归一让这一次显示就对。两侧都归一不冗余：写侧管"不再变坏"，读侧管
/// "立刻看起来对"。
///
/// 单独提成函数是为了让测试走**和 `wizard_state` 同一条**读路径，而不是在
/// 测试里抄一份——抄的那份改坏产品代码也不会红。
fn configured_library_dir(data_dir: &std::path::Path) -> Option<String> {
    ipc::read_config_data_dir(data_dir).map(|v| normalize_separators(&v))
}

/// DESK-27 (#219)：把路径里重复的反斜杠折回单个，**但保住前导的那一对**。
///
/// 为什么需要它：`write_config` 原先用 `format!("{:?}")` 当 TOML 序列化器，
/// 而读取方（#209 修好前）不反转义 —— 于是「写→读→预填→再写」每轮把反斜杠
/// 数量翻一倍，2 → 4 → 8 → 16，没有收敛点。#209 修了读取方，本函数负责
/// **打断回路**（写入前归一，保证幂等）与**修存量**（任意 N 轮的损坏都收敛）。
///
/// ⚠️ **为什么不用 `Path::components()`** —— 那是本卡实施时实测否掉的第一版。
/// 它对被翻倍过的 UNC 路径会给出**另一个错路径**（下面用 `/` 代替反斜杠画，
/// 免得注释本身被转义规则绕晕）：
///
/// ```text
///   输入        ////server//share     （UNC 被翻倍一次）
///   components() → /server/share      ← 只剩一个前导分隔符，不再是 UNC
///   本函数       → //server/share     ← 对
/// ```
///
/// UNC（`//server/share` 形状）与 verbatim（`//?/C:/x` 形状）的**前导两个**
/// 分隔符是语义的一部分，折成一个就指向别的地方。而 Windows 会折叠**中间**的
/// 重复分隔符，所以中间折回一个是安全的 —— 这个不对称正是 `components()` 没
/// 处理好的地方。
///
/// 非 Windows 平台上路径里没有反斜杠可折，本函数是恒等变换（有测试钉住）。
fn normalize_separators(p: &str) -> String {
    const SEP: char = '\\';
    let leading = p.chars().take_while(|&c| c == SEP).count();
    let mut out = String::with_capacity(p.len());
    // 前导：>=2 一律收成 2（UNC / verbatim），1 保持 1（根相对路径），0 不加。
    match leading {
        0 => {}
        1 => out.push(SEP),
        _ => {
            out.push(SEP);
            out.push(SEP);
        }
    }
    let mut prev_sep = false;
    for ch in p[leading..].chars() {
        if ch == SEP {
            if !prev_sep {
                out.push(ch);
            }
            prev_sep = true;
        } else {
            out.push(ch);
            prev_sep = false;
        }
    }
    out
}

/// DESK-27 (#219)：把 config.toml 的内容渲染出来。
///
/// **单独提成纯函数是为了让归一那一步可被测试覆盖到调用点。** 卡面验收
/// 标准 3 要的是「把归一那步去掉必须变红」—— 如果只测 `normalize_separators`
/// 本身，删掉下面那句调用测试照样是绿的，那种反证等于没做。
///
/// 两处改动缺一不可：
/// ① **先归一**：打断「写→读→预填→再写」的翻倍回路，并顺带把已损坏的存量
///    救回来（任意 N 轮翻倍都收敛到单分隔符）。
/// ② **用真的 TOML 序列化器**，不再拿 `{:?}`（Debug）冒充。两者只在反斜杠
///    和引号上碰巧一致，而那个"碰巧"正是本缺陷的起点。实测 `toml::Value`
///    对 Windows 路径会选 literal string（单引号，TOML 里不做任何转义），
///    路径里带单引号时还会自动改用三引号 —— 那是手写转义最容易漏的边界。
fn render_config(library_dir: &str) -> String {
    let normalized = normalize_separators(library_dir);
    let data_dir_value = toml::Value::String(normalized).to_string();
    format!(
        "data_dir = {data_dir_value}

# 固定端口：手机存的回连地址跨服务重启依然有效（真机教训）。
bind_addr = \"0.0.0.0:41145\"

# H-07 部署前必须为空（内置官方 relay 域名尚未上线）
relay_urls = []

[telemetry]
enabled = false
"
    )
}

/// Write the initial config.toml (T-042 step 1) into the platform dir.
#[tauri::command]
fn write_config(library_dir: String) -> Result<(), String> {
    let dir = platform::adapter().data_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    std::fs::write(dir.join("config.toml"), render_config(&library_dir)).map_err(|e| e.to_string())
}

/// DESK-46 (#638)：更改照片库位置——平台 config.toml 的 read-modify-write。
///
/// 为什么在壳、不在 daemon：daemon 的 folder.set 是 MVP 残留的第二写者，
/// 写的是 `self.data_dir.join("config.toml")`（**当前库目录**）——一个
/// 没有任何读者的孤儿文件，自定义库下切换静默无效（本卡根因，真机
/// 取证：旧库目录里躺着只含一行 data_dir 的孤儿 config.toml）。平台
/// config 的写者只有壳这一个：write_config 管首启向导，本命令管事后更改。
///
/// 顺序：先校验（不碰盘），再写入，最后清理旧库里的孤儿 config.toml。
/// 生效时机不变——daemon 只在启动时读一次 config，重启后台服务后生效
/// （确认弹窗与保存提示的文案都这么说）。
#[tauri::command]
fn set_library_dir(library_dir: String) -> Result<(), String> {
    let dir = platform::adapter().data_dir();
    let cfg_path = dir.join("config.toml");
    let current = configured_library_dir(&dir);
    let target = std::path::Path::new(&library_dir);
    library_target_verdict(
        &library_dir,
        current.as_deref(),
        target.is_dir(),
        dir_writable(target),
    )?;
    rewrite_library_dir(&cfg_path, &library_dir)?;
    // ⑤ 孤儿清理：folder.set 时代留在旧库目录里的 config.toml 没有任何
    // 读者，留着只会误导排查。防误伤：与平台 config 是同一个文件
    // （库 == 平台目录，含大小写/拼写差异）则跳过——canonicalize 两边
    // 都落到磁盘真实路径再比。
    if let Some(old) = current {
        let orphan = std::path::Path::new(&old).join("config.toml");
        let same_file = match (orphan.canonicalize(), cfg_path.canonicalize()) {
            (Ok(a), Ok(b)) => a == b,
            _ => false,
        };
        if !same_file && orphan.is_file() {
            let _ = std::fs::remove_file(&orphan);
        }
    }
    Ok(())
}

/// DESK-49 (#710)：平台 config.toml 的 read-modify-write 本体。
///
/// 读失败必须分两档：文件不存在 ⇒ 当空配置（首次写入，正常创建）；
/// 其它读错误（权限 / 非 UTF-8 / IO）⇒ 如实报错、**不写文件**。
/// 曾经的 `unwrap_or_default()` 把后者也读成空串，写回只剩 data_dir，
/// bind_addr / relay_urls / [telemetry] 被抹掉，界面却报成功。
fn rewrite_library_dir(cfg_path: &std::path::Path, library_dir: &str) -> Result<(), String> {
    let doc = match std::fs::read_to_string(cfg_path) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(ipc::ui_err("ui.err_set_library", &[("err", &e)])),
    };
    let merged = merge_library_dir(&doc, library_dir);
    std::fs::write(cfg_path, merged).map_err(|e| ipc::ui_err("ui.err_set_library", &[("err", &e)]))
}

/// DESK-46 (#638)：换库目标的判据（纯函数——文件系统事实由调用点探测后
/// 传入，判据本身不碰盘，好做单测与反证）。错误走 keyed ui_err（前端
/// errText 渲染成 i18n 人话）。
fn library_target_verdict(
    target: &str,
    current: Option<&str>,
    target_is_dir: bool,
    target_writable: bool,
) -> Result<(), String> {
    if target.trim().is_empty() || !target_is_dir {
        return Err(ipc::ui_err(
            "ui.err_library_target_missing",
            &[("dir", &target)],
        ));
    }
    if !target_writable {
        return Err(ipc::ui_err(
            "ui.err_library_target_readonly",
            &[("dir", &target)],
        ));
    }
    if let Some(cur) = current {
        if paths_overlap(cur, target) {
            return Err(ipc::ui_err("ui.err_library_nested", &[]));
        }
    }
    Ok(())
}

/// DESK-46 (#638)：可写探测——真建一个临时文件再删掉。只看权限位不够：
/// ACL、只读挂载、沙箱限制都不体现在 mode 里，只有真写一次才知道。
fn dir_writable(p: &std::path::Path) -> bool {
    if !p.is_dir() {
        return false;
    }
    let probe = p.join(format!(".ppf-write-probe-{}", std::process::id()));
    match std::fs::File::create(&probe) {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// DESK-46 (#638)：把 data_dir 换进既有 config 文本（read-modify-write）。
///
/// 与 render_config（首启向导的整份模板）不同：这里**只改 data_dir 一行，
/// 其余逐字节保留**——bind_addr / relay_urls / [telemetry] / 注释都是
/// 用户与发版流程的既有事实，不能因为换个库位置被重写。
///
/// 两条老规矩照守（与被删的 daemon write_folder_config 同一教训）：
/// ① 顶层键必须落在第一个 [section] 之前（2026-07-31 crash-loop）——
///    所以新 data_dir 永远插在文首；
/// ② 路径值先归一、再用真 TOML 序列化（DESK-27 同款），不拿 `{:?}` 冒充。
fn merge_library_dir(doc: &str, library_dir: &str) -> String {
    let data_dir_value = toml::Value::String(normalize_separators(library_dir)).to_string();
    let body: String = doc
        .lines()
        .filter(|l| !l.trim_start().starts_with("data_dir"))
        .collect::<Vec<_>>()
        .join("\n");
    format!("data_dir = {data_dir_value}\n{body}\n")
}

/// DESK-46 (#638)：两个路径是否相同或一方包含另一方（纯字符串判据，
/// 不碰盘）。嵌套库是灾难配方：新库在旧库里面 ⇒ 索引/收编会互相看见
/// 对方的文件；旧库在新库里面 ⇒ 换完库「旧照片」出现在新库眼皮底下。
/// 分隔符两种都认（Windows 用户可能混输 / 与 \），结尾分隔符先剥掉，
/// 大小写不敏感（macOS 默认与 Windows 的文件系统都不分大小写）。
fn paths_overlap(a: &str, b: &str) -> bool {
    // DESK-46 落地修正：分隔符必须整体归一（不只尾部分隔符）——Windows 下
    // `C:/Lib/sub` 与 `C:\Lib` 是同一路径的两种写法，只归一尾部会把它们
    // 判成不重叠（正是 `desk46_paths_overlap_boundaries` 抓到的）。
    let norm = |p: &str| {
        p.trim_end_matches(['/', '\\'])
            .replace('\\', "/")
            .to_lowercase()
    };
    let (a, b) = (norm(a), norm(b));
    if a == b {
        return true;
    }
    // 前缀必须断在分隔符边界上：/old/lib2 不是 /old/lib 的子目录。
    let contains = |outer: &str, inner: &str| {
        outer.len() > inner.len()
            && outer.starts_with(inner)
            && outer.as_bytes()[inner.len()] == b'/'
    };
    contains(&a, &b) || contains(&b, &a)
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
        Some(0) => Err(ipc::ui_err(
            "ui.err_sidecar_not_daemon",
            &[(
                "output",
                &stdout.trim().chars().take(120).collect::<String>(),
            )],
        )),
        Some(other) => Err(ipc::ui_err("ui.err_sidecar_exit_code", &[("code", &other)])),
        None => Err(ipc::ui_err("ui.err_sidecar_version_timeout", &[])),
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
        .map_err(|e| {
            ipc::ui_err(
                "ui.err_sidecar_spawn",
                &[("err", &e), ("path", &sidecar.display())],
            )
        })?;

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
            Err(e) => return Err(ipc::ui_err("ui.err_sidecar_wait", &[("err", &e)])),
        }
    }
    // 已经退出了，这一步立即返回。`--version` 的输出只有一行，塞不满管道。
    let out = child
        .wait_with_output()
        .map_err(|e| ipc::ui_err("ui.err_sidecar_read", &[("err", &e)]))?;
    sidecar_probe_verdict(out.status.code(), &String::from_utf8_lossy(&out.stdout))
}

/// 【DESK-42 #604】开机自启登记对账（App 启动时跑一次，独立线程）。
///
/// 缺陷现场：`~/Library/LaunchAgents/com.p-pass.daemon.plist` 被钉在
/// `~/P-Pass-Backups/<日期>/old-app/P-Pass.app/...` 里的旧 App 上，而实际安装
/// 在 `/Applications`——开机/登录/KeepAlive 拉起的是那份旧服务。成因是登记
/// 路径只在「用户主动启动服务」或「daemon 接管」两个时机写入，此后换目录、
/// 更新覆盖、从备份副本启动过，都没有任何东西去校验它。
///
/// 现在每次启动对一次账：登记存在但指向别处 → 用**当前 App 内**的 daemon 路径
/// 重写（幂等）；未登记 → 不动（纯新启动不许顺手装，DAE-03 ②）；一致 → 不动。
fn reconcile_autostart_registration() {
    use platform::PlatformAdapter as _;
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(dir) = exe.parent() else { return };
    let sidecar = dir.join(platform::adapter().daemon_executable_name());
    // 开发运行（target/ 里没有 sidecar）等情况：没有可对账的目标，直接跳过。
    if !sidecar.is_file() {
        return;
    }
    match platform::adapter().reconcile_autostart(&sidecar) {
        Ok(platform::AutostartReconcile::Rewritten) => {
            // 走 stderr：与 daemon_logs 收集的日志同一去处，排障时看得到。
            eprintln!(
                "#604: 开机自启登记与当前安装不一致——已重写为 {}",
                sidecar.display()
            );
        }
        Ok(_) => {}
        Err(e) => eprintln!("#604: 开机自启登记对账失败: {e}"),
    }
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
                .map_err(|e2| {
                    ipc::ui_err(
                        "ui.err_register_and_spawn",
                        &[("err", &e), ("spawn_err", &e2)],
                    )
                })?;
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

/// DESK-36 (#456)：「用户主动停止了后台服务」的持久标记。
///
/// 自愈（前端 refresh 失败分支 → `self_heal_daemon`）原来分不清「服务崩了」
/// 和「用户点了停止」，冷却窗口一过就把用户刚停掉的服务拉回来。这个标记是
/// 两者唯一的区分依据，前端按钮和托盘菜单共用同一份（都走 `stop_daemon`）。
///
/// 为什么是 data dir 里的独立文件、而不是 config.toml 的一个字段：
/// `write_config` 会整体重写 config.toml（向导每走一次就重写一次），字段放
/// 进去会被冲掉；而且 config.toml 是 daemon 的配置，这是壳自己的状态。
/// 持久化（而不是进程内变量）是因为语义要跨 App 重开：用户停了服务、关掉
/// App 再打开，服务仍应保持停止，直到用户点「启动服务」。
const USER_STOPPED_MARKER: &str = "desktop-user-stopped";

fn user_stopped_marker(data_dir: &std::path::Path) -> std::path::PathBuf {
    data_dir.join(USER_STOPPED_MARKER)
}

fn is_user_stopped(data_dir: &std::path::Path) -> bool {
    user_stopped_marker(data_dir).exists()
}

/// 落标记 / 清标记。失败要报出来：标记没落下 = 自愈照样会把服务拉回来，
/// 用户意图被静默撤销，这正是 #456 本身。
fn set_user_stopped(data_dir: &std::path::Path, stopped: bool) -> Result<(), String> {
    let marker = user_stopped_marker(data_dir);
    if stopped {
        std::fs::create_dir_all(data_dir)
            .map_err(|e| ipc::ui_err("ui.err_stop_mark_write", &[("err", &e)]))?;
        std::fs::write(&marker, b"user stopped the background service\n")
            .map_err(|e| ipc::ui_err("ui.err_stop_mark_write", &[("err", &e)]))
    } else {
        match std::fs::remove_file(&marker) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(ipc::ui_err("ui.err_stop_mark_clear", &[("err", &e)])),
        }
    }
}

/// 自愈判据（纯函数，单测覆盖）：配置过、且不是用户主动停的，才允许自愈。
/// 「没配置过」是首启向导的事；「用户停的」要等用户自己点「启动服务」。
fn self_heal_allowed(data_dir: &std::path::Path) -> bool {
    data_dir.join("config.toml").exists() && !is_user_stopped(data_dir)
}

/// #456 后续：更新流程装完（或装失败）之后要不要把 daemon 拉回来。
/// 用户主动停了服务 = 一直停着，直到用户自己点「启动后台服务」；更新不算
/// 用户的启动意图。其余情况（包括向导还没走完的机器）行为和原来一样：
/// pause 杀掉了什么就拉回什么。不复用 `self_heal_allowed`——它多一条
/// config.toml 判断，会改掉「没停过」时的更新行为。
fn update_resume_allowed(data_dir: &std::path::Path) -> bool {
    !is_user_stopped(data_dir)
}

/// DESK-36 (#456)：前端 refresh 发现 daemon 不可达时调这个，而不是直接调
/// `resume_daemon_after_update`。判据在**调用这一刻**读磁盘上的标记——
/// 前端缓存的状态可能是旧的（比如刚在托盘里点了停止），只有这里读才没有竞态。
/// 返回 true = 真的拉起了；false = 按判据跳过（不是错误）。
#[tauri::command]
fn self_heal_daemon() -> Result<bool, String> {
    if !self_heal_allowed(&platform::adapter().data_dir()) {
        return Ok(false);
    }
    // UPD-07 (#617)：自愈与"更新"无关 ⇒ **不带** `--post-update`（不带 = owner 不开火）。
    // #732：有 LaunchAgent 时交给 launchd 拉（不杀在跑的——自愈只补"没在跑"）。
    bring_up_daemon(false, false).map(|_| true)
}

/// Stop the resident service the way a user means it: unregister the
/// autostart entry FIRST (so launchd won't respawn it), then ask the
/// running daemon to shut down. "能优雅退出"与"崩溃自动恢复"必须并存
/// (用户裁决 2026-07-31).
///
/// DESK-36 (#456)：末尾要等进程真的退掉（最长 5s），所以命令是 async、
/// 实际工作放到阻塞线程池——同步命令跑在主线程上，等待期间窗口会卡住。
#[tauri::command]
async fn stop_daemon() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(stop_daemon_now)
        .await
        .map_err(|e| ipc::ui_err("ui.err_stop_thread", &[("err", &e)]))?
}

fn stop_daemon_now() -> Result<(), String> {
    // 0) DESK-36 (#456)：先落「用户主动停止」标记，再动进程——停到一半时
    //    恰好来一次自愈 tick，它也得看见标记。落不下就不停：停了也会被
    //    自愈拉回来，不如直接告诉用户停止失败。
    set_user_stopped(&platform::adapter().data_dir(), true)?;
    // 1) Unregister first — otherwise KeepAlive revives it immediately.
    let _ = platform::adapter().uninstall_autostart();
    // 2) Best-effort: kill the bundled daemon process. launchctl bootout
    //    (inside uninstall_autostart) already stopped the managed one;
    //    this also covers a one-shot fallback spawn.
    // QA-09 迁移（#211）：best-effort —— 杀不掉也继续（原来两个分支也是
    // 直接丢结果）。区别在于「什么退出码算进程本来就没在跑」这条判据
    // 现在只有一份、在 platform 里，不再是三个调用点各抄一遍。
    let _ = platform::adapter().kill_daemon_process();
    // 3) DESK-36 (#456)：等它真的不可达了再返回（最长 5s）——调用方紧接着
    //    就要刷新状态点，socket 还活着的那一瞬读到「运行中」就白刷了。
    //    超时不算失败：标记已落、autostart 已卸，剩下的只是进程退得慢。
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while daemon_online() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(250));
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
    // QA-09 迁移（#211）：best-effort —— 杀不掉也继续（原来两个分支也是
    // 直接丢结果）。区别在于「什么退出码算进程本来就没在跑」这条判据
    // 现在只有一份、在 platform 里，不再是三个调用点各抄一遍。
    let _ = platform::adapter().kill_daemon_process();
    Ok(())
}

/// Counterpart to pause_daemon_for_update(): bring the (now updated on
/// disk) daemon back after the installer finishes (no autostart touch —
/// it was never unregistered). #732：有 LaunchAgent 就交给 launchd
/// `kickstart -k`，内核从此归 launchd 托管、日志进 LaunchAgent 的 `.err`；
/// 没有（Windows Run key / 未登记）才退回一次性 spawn。Best-effort; the
/// frontend degrades to "restart the app" guidance if this fails,
/// rather than silently leaving the daemon down after an update the
/// user believes succeeded.
///
/// #456 后续：用户主动停了服务（盘上有 `desktop-user-stopped` 标记）就不拉，
/// 标记原样保留，界面仍给「启动后台服务」。判据在 Rust 这一侧、调用这一刻
/// 读盘（和 `self_heal_daemon` 同一来源），不信前端缓存——托盘停止之后
/// 前端的 wizard 状态可能还是旧的。之后用户手动启动走 `start_daemon`，它每次
/// 都从 `current_exe()` 旁边现取 sidecar 并探活、重写 autostart，用的就是
/// 更新后的新文件。返回 true = 拉起了；false = 按判据跳过（不是错误）。
#[tauri::command]
fn resume_daemon_after_update() -> Result<bool, String> {
    if !update_resume_allowed(&platform::adapter().data_dir()) {
        return Ok(false);
    }
    bring_up_daemon(true, true).map(|_| true)
}

/// #732：内核是怎么被拉起来的。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BroughtUp {
    /// 服务管理器（launchd）拉起 / 本来就在跑，pid 由它报出。
    Resident { pid: u32 },
    /// 退回了一次性 spawn（没有服务管理器语义，或它失败了）。
    OneShot,
}

/// 常驻服务登记在、且是 launchd 那种"服务管理器拉起"语义吗？
/// （Windows Run key 是 `UserAutostart`，走老路，行为不变。）
fn resident_service_available() -> bool {
    let a = platform::adapter();
    a.service_mode() == platform::ServiceMode::LaunchAgent
        && a.autostart_installed().unwrap_or(false)
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
/// 与改前一致；`post_update` 只对这条退路有意义（见 `spawn_bundled_daemon_oneshot`）。
fn bring_up_daemon(kill_running: bool, post_update: bool) -> Result<BroughtUp, String> {
    if resident_service_available() {
        if kill_running {
            retire_unmanaged_daemon(platform::adapter().resident_daemon_pid());
        }
        match platform::adapter().restart_resident_daemon(kill_running) {
            Ok(platform::ResidentRestart::Started { pid })
            | Ok(platform::ResidentRestart::AlreadyRunning { pid }) => {
                eprintln!("#732: 内核交由服务管理器拉起 pid={pid}");
                return Ok(BroughtUp::Resident { pid });
            }
            Ok(other) => eprintln!("#732: 服务管理器没接手（{other:?}），退回一次性 spawn"),
            Err(e) => eprintln!("#732: 服务管理器拉起失败，退回一次性 spawn：{e}"),
        }
    }
    spawn_bundled_daemon_oneshot(post_update).map(|()| BroughtUp::OneShot)
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

/// 纯函数：在跑的内核（自报 pid）是不是"野生"的——服务管理器手里的 job pid
/// 与它对不上。读不到自报 pid = 不知道 = 不算（fail-safe：不去动它）。
fn daemon_is_unmanaged(running_pid: Option<u32>, resident_pid: Option<u32>) -> bool {
    match running_pid {
        Some(p) => resident_pid != Some(p),
        None => false,
    }
}

/// 一次性 spawn 时把 daemon 的 stdout/stderr 接到哪儿（#732 ③）。
///
/// LaunchAgent plist 登记了日志路径就**追加**进同一对文件——与 launchd 托管时
/// 同一去处，排障只看一处；读不到 plist（Windows / 未登记）= 接 null，与改前
/// 一致（Windows 的 daemon 自己有落盘日志，DIAG-B1）。打不开文件也退回 null，
/// 不能因为日志让内核起不来。
fn oneshot_stdio() -> (std::process::Stdio, std::process::Stdio) {
    let paths = std::fs::read_to_string(daemon_logs::plist_path())
        .map(|t| daemon_logs::parse_plist_log_paths(&t))
        .unwrap_or((None, None));
    let open = |p: Option<String>| -> std::process::Stdio {
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
/// `post_update`（UPD-07 #617）：这一份是**被更新流程拉起的**吗？只有它会带上
/// `--post-update`，从而允许 daemon 在更新窗口内换掉旧壳（见 `crates/daemon/src/owner.rs`）。
/// 自愈/用户点「启动服务」绝不带——那两件事与"更新"无关，不该让 owner 开火。
/// ⚠️ 走 launchd 那条（`kickstart` 不能带参数）时 owner 不开火——见 PR 登记：
/// owner 这条路在新旧壳上都走不通（#667 评论），新壳装完会自己换壳。
fn spawn_bundled_daemon_oneshot(post_update: bool) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let sidecar = exe
        .parent()
        .ok_or("no parent dir")?
        .join(platform::adapter().daemon_executable_name());
    if !sidecar.is_file() {
        return Err(ipc::ui_err(
            "ui.err_sidecar_missing",
            &[("path", &sidecar.display())],
        ));
    }
    let mut cmd = std::process::Command::new(&sidecar);
    if post_update {
        cmd.arg("--post-update");
    }
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
fn register_shell_login_item() {
    use platform::PlatformAdapter as _;
    if platform::adapter().shell_agent_label().is_none() {
        return; // 本平台没有服务管理器
    }
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    if let Err(e) = platform::adapter().register_shell_agent(&exe) {
        // 开发构建 / 从 dmg 直跑（非稳定安装位置）被拒是**预期**的——不当错误刷屏。
        eprintln!("#616: 壳登录项未登记（{e}）——非 /Applications 安装时属预期");
    }
}

/// UPD-07 (#617)：把自己的身份（版本 + pid）报给 daemon —— owner 对账的**唯一**来源。
///
/// 为什么必须由壳自己报：更新装完"磁盘已是新版、运行中的壳还是旧版"时，只有 daemon
/// （每跳必被换新）能当 owner；而它要判断"壳旧不旧"，必须有**编译进这只壳的版本**——
/// 去读磁盘上的 `Info.plist` 只会读到新版，读不出壳自己的版本。
///
/// 老壳不来这一条 ⇒ daemon 记录为空 ⇒ 它什么都不做（fail-safe）。重试几轮是因为
/// 启动时序：登录项拉起的壳可能比常驻服务先就绪。
fn announce_shell_identity() {
    let params = serde_json::json!({
        "version": env!("CARGO_PKG_VERSION"),
        "pid": std::process::id(),
    });
    for _ in 0..30 {
        if let Ok(handle) = ipc::DaemonHandle::discover() {
            if handle.call("shell.announce", params.clone()).is_ok() {
                return;
            }
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    eprintln!("#617: 壳身份自报失败（daemon 一直不可达）——owner 那条换壳路会按 fail-safe 不动");
}

/// UPD-05 (#605)：更新装完后重启桌面壳自己。
///
/// 为什么必须重启：tauri-plugin-updater 的 downloadAndInstall() 只替换
/// 磁盘上的 .app，**正在运行的外壳进程仍是旧版**——0.7.3→0.7.4 真机现场：
/// 装完后 resume_daemon_after_update 从新版包拉起新 daemon，页脚
/// displayVersion = status?.version || version 先跳 0.7.4（显示的是
/// daemon 版本），外壳二进制还是 0.7.3，于是设置页再弹同一个更新，
/// 用户以为「版本不对」去重启后台，又跳回 0.7.3——鬼打墙。装完重启
/// 外壳后，新外壳启动即跑 #604 的自启对账，daemon 已是新版，版本闭环。
///
/// 为什么不用 `app.restart()`：它走事件循环（ExitRequested +
/// RESTART_EXIT_CODE 约定），在 macOS 上有两个与我们配置雷同
/// （tray 常驻 + 关窗 prevent_close + single-instance）的未结上游
/// issue——tauri#11392、tauri#13923（tauri 2.5.1 仍复现：只关不拉）。
/// `tauri::process::restart` 不走事件循环：直接 spawn 当前二进制 +
/// 立即 exit(0)，与官方 plugin-process 的 relaunch() 是同一底层调用，
/// 零新依赖（不为这一个命令引入 plugin-process 整 crate）。
///
/// Windows 说明：NSIS 静默安装在 downloadAndInstall() 中途就杀掉调用
/// 进程（见 App.svelte 的 W1 注释），本命令在 Windows 实际走不到——
/// 装完由安装器自己拉起新外壳。本命令服务 macOS（#605 的事发平台）。
#[tauri::command]
fn restart_app(app: tauri::AppHandle) {
    tauri::process::restart(&app.env());
}

/// UPD-06 (#616)：磁盘上**安装包**的版本（`Contents/Info.plist`）。
///
/// 与 `getVersion()`（**编译进这只壳**的版本）比对就是"更新装完了、但运行中的
/// 这只壳还是旧的"的**确定性判据**：壳的可执行文件在 `/Applications` 下跨更新
/// 路径不变，包在它下面被换掉，于是"读到的包版本 ≠ 我的编译版本"只有一种解释。
/// 读不到 = `None` = 不知道（前端必须按"什么都不做"处理）。
#[tauri::command]
fn installed_app_version() -> Option<String> {
    use platform::PlatformAdapter as _;
    platform::adapter().installed_bundle_version()
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
    use platform::PlatformAdapter as _;
    // ⚠️ 闸门一：只有**launchd 自己拉起来的**这一份壳才走系统路径。
    // `kickstart -k` 的 "kill the running instance" 只能杀服务管理器启动的进程；
    // 从访达/Dock 打开的壳，launchd 手里没有它的 pid ⇒ `-k` 无物可杀 ⇒ kickstart
    // 只会再拉一个实例，而 single-instance 会让新实例把焦点交回旧壳后自杀 ⇒
    // 用户点"重启"什么都没发生（比不重启更糟）。所以非 launchd 实例直接走退化路径。
    if let Some(label) = platform::adapter().shell_agent_label() {
        if !platform::adapter().shell_agent_started_us() {
            eprintln!(
                "#616: 本进程不是 {label} 拉起的（用户直接打开），kickstart 无物可杀，走壳自己重启"
            );
        } else {
            match std::env::current_exe() {
                Ok(exe) => match platform::adapter().register_shell_agent(&exe) {
                    Ok(()) => match platform::adapter().shell_agent_registered_exec() {
                        Ok(Some(registered)) if registered == exe => {
                            match platform::adapter().kickstart_shell_agent() {
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
/// 版本协商。Windows 的 autostart 是普通 Run key、没有 KeepAlive 复活
/// 语义——杀掉后显式重新拉起一次（start_daemon 的一次性 spawn 分支，
/// 不注册 autostart）。
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
async fn restart_daemon_process() -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(restart_daemon_process_blocking)
        .await
        .map_err(|e| ipc::ui_err("ui.err_restart", &[("err", &e)]))?
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
    // 2) 杀进程——照抄 stop_daemon 的 kill 逻辑（同款 pkill/taskkill），
    //    但绝不做任何 uninstall_autostart。
    // QA-09 迁移（#211）：这处**认真判错**（另两个调用点是 best-effort）。
    // 「进程本来就没在跑」不是失败——判据在 platform 里，各系统一份
    // （unix 的 pkill 退出码 1 / Windows 的 taskkill 128）。DESK-25 (#208)
    // 就是因为这条判据被抄散、其中一处没判，把「没杀掉」当成杀成功、
    // 紧接着去 spawn 第二个 daemon 才出的事。
    //
    // #667 / #732：有 LaunchAgent 时**不再 pkill 等 KeepAlive 复活**——那条路吃
    // launchd 的重拉节流（10s 量级，DESK-44 假失败的根），而且杀不到一次性 spawn
    // 的野生实例。改为：野生实例先退位 + `kickstart -k`（launchd 立刻按磁盘上的
    // 文件拉新的），内核从此归 launchd 托管。走不通才退回下面的老路。
    if resident_service_available() {
        bring_up_daemon(true, false).map_err(|e| ipc::ui_err("ui.err_restart", &[("err", &e)]))?;
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

/// DAE-04 原路径（没有 LaunchAgent 语义时）：杀进程，Run key 平台再显式拉一次。
fn restart_by_kill_and_respawn() -> Result<(), String> {
    platform::adapter()
        .kill_daemon_process()
        .map_err(|e| ipc::ui_err("ui.err_kill_old", &[("err", &e)]))?;

    // 3) 被杀之后系统会不会自己把它拉回来，取决于常驻方式：
    //    LaunchAgent 的 KeepAlive 会（macOS），Run key 不会（Windows /
    //    Linux）——后者必须显式重新拉起一次（一次性 spawn，不碰 autostart
    //    注册，注册从头到尾没动过，这正是本命令的设计要点）。
    //
    //    ⚠️ 这一句在 Linux 上是**行为改变**，已在 PR 里登记：迁移前
    //    Linux 走的是原来那个 unix 分支、杀完不拉起，然后下面那段等待必然
    //    超时报错（Linux 没有任何东西会复活它）。桌面壳在 Linux 上不是发布
    //    形态，但既然改了就写明，不混在"纯搬家"里带过去。
    if platform::adapter().service_mode() == platform::ServiceMode::UserAutostart {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let sidecar = exe
            .parent()
            .ok_or("no parent dir")?
            .join(platform::adapter().daemon_executable_name());
        if !sidecar.is_file() {
            return Err(ipc::ui_err(
                "ui.err_sidecar_missing",
                &[("path", &sidecar.display())],
            ));
        }
        std::process::Command::new(&sidecar)
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
    // DIAG-B1：daemon 自己的固定位置日志，不依赖 plist。DESK-32 (#367)：没读到
    // 也要把原因和本该在的位置带进包里。
    let log_path = platform::adapter().default_log_file(&env.platform_dir);
    let (persistent_log_tail, persistent_log_missing) =
        daemon_logs::persistent_log(log_path.as_deref(), 1024 * 1024);

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
        persistent_log_tail,
        persistent_log_path: log_path.map(|p| p.display().to_string()),
        persistent_log_missing,
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

// ── #667：壳启动时自动换内核 ─────────────────────────────────────────
//
// 现场（2026-10-08 取证）：dmg 覆盖安装（替换 /Applications/P-Pass.app）后重开，
// 壳是新的、内核仍是覆盖前就在跑的旧进程——launchd 不会因为磁盘上文件换了就
// 重拉它，用户只能点「重启后台服务」。新壳启动时自己对一次账：内核比磁盘上
// 的 sidecar 旧（或不归 launchd 管，#732 ①）就自动换，不需要按钮。
//
// 两个既有语义先于"换"：
// ① 用户主动停过服务（`desktop-user-stopped`）⇒ 一律不动；
// ② 正在传输（任何设备 `devices.list` 报出非空 `flow_connection`——与设备行
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

/// 与 daemon 的 DAE-01 `version_cmp`（crates/daemon/src/ipc.rs）**同一语义**：
/// 数字段逐段比；同核心时正式版 > 预发布；预发布按数字段比（test.10 > test.9）。
/// 桌面壳是独立 workspace、不依赖 daemon crate，所以抄一份，单测用同一组样例钉住。
fn version_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let nums = |seg: &str| -> Vec<u64> {
        seg.split(|c: char| !c.is_ascii_digit())
            .filter(|p| !p.is_empty())
            .map(|p| p.parse().unwrap_or(0))
            .collect()
    };
    let parse = |s: &str| -> (Vec<u64>, Vec<u64>, bool) {
        let (core, pre) = match s.split_once('-') {
            Some((c, p)) => (c, Some(p)),
            None => (s, None),
        };
        (nums(core), pre.map(nums).unwrap_or_default(), pre.is_some())
    };
    let (na, npa, pa) = parse(a);
    let (nb, npb, pb) = parse(b);
    for i in 0..na.len().max(nb.len()) {
        let (x, y) = (
            na.get(i).copied().unwrap_or(0),
            nb.get(i).copied().unwrap_or(0),
        );
        if x != y {
            return x.cmp(&y);
        }
    }
    match (pa, pb) {
        (false, true) => Ordering::Greater,
        (true, false) => Ordering::Less,
        (true, true) => {
            for i in 0..npa.len().max(npb.len()) {
                let (x, y) = (
                    npa.get(i).copied().unwrap_or(0),
                    npb.get(i).copied().unwrap_or(0),
                );
                if x != y {
                    return x.cmp(&y);
                }
            }
            Ordering::Equal
        }
        (false, false) => Ordering::Equal,
    }
}

/// 对账用的事实（全部现取，不信缓存）。
#[derive(Debug, Clone, Default)]
struct KernelFacts {
    /// 在跑的内核自报（`status.version` / `status.pid`）。
    running_version: Option<String>,
    running_pid: Option<u32>,
    /// 磁盘上 sidecar 的版本（`ppf-daemon --version`）——换完会是它。
    on_disk_version: Option<String>,
    /// 常驻服务登记在吗（launchd 语义），以及 launchd 眼里在跑的 pid。
    resident_registered: bool,
    resident_pid: Option<u32>,
    user_stopped: bool,
    transfer_active: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KernelVerdict {
    /// 内核 = 磁盘版本，且（有 launchd 时）归 launchd 管：无事可做。
    InSync,
    /// 按规则不动（理由写日志）。
    Skip(&'static str),
    /// 该换，但正在传输 ⇒ 推迟。
    Defer,
    /// 现在就换。
    Converge(&'static str),
}

/// #667 判据（纯函数，单测覆盖每条分支）。
fn kernel_convergence_verdict(f: &KernelFacts) -> KernelVerdict {
    use std::cmp::Ordering;
    if f.user_stopped {
        return KernelVerdict::Skip("用户主动停了服务");
    }
    let (Some(running), Some(on_disk)) =
        (f.running_version.as_deref(), f.on_disk_version.as_deref())
    else {
        // 读不到 = 不知道 = 什么都不做（fail-safe）。
        return KernelVerdict::Skip("读不到内核或磁盘版本");
    };
    let reason = match version_cmp(running, on_disk) {
        // 只在"内核比磁盘旧"时换：dmg 降级安装不许把内核也降下去。
        Ordering::Greater => return KernelVerdict::Skip("内核比磁盘上的新，不降级"),
        Ordering::Less => "内核比磁盘上的旧",
        Ordering::Equal => {
            if f.resident_registered && daemon_is_unmanaged(f.running_pid, f.resident_pid) {
                "内核不归服务管理器管"
            } else {
                return KernelVerdict::InSync;
            }
        }
    };
    if f.transfer_active {
        return KernelVerdict::Defer;
    }
    KernelVerdict::Converge(reason)
}

/// `ppf-daemon --version` 的输出是 `P-Pass daemon <ver>`；取版本号。
fn parse_sidecar_version(text: &str) -> Option<String> {
    text.trim()
        .strip_prefix("P-Pass daemon ")
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// 任何设备报出非空 `flow_connection` = 正在传输（与设备行「传输中」同一信号）。
fn any_transfer_active(devices: &Value) -> bool {
    devices
        .get("devices")
        .and_then(|d| d.as_array())
        .map(|list| list.iter().any(|d| !d["flow_connection"].is_null()))
        .unwrap_or(false)
}

fn gather_kernel_facts() -> KernelFacts {
    let handle = ipc::DaemonHandle::discover().ok();
    let status = handle
        .as_ref()
        .and_then(|h| h.call("status", json!({})).ok());
    let devices = handle
        .as_ref()
        .and_then(|h| h.call("devices.list", json!({})).ok());
    KernelFacts {
        running_version: status
            .as_ref()
            .and_then(|s| s["version"].as_str().map(str::to_string)),
        running_pid: status
            .as_ref()
            .and_then(|s| s["pid"].as_u64())
            .map(|p| p as u32),
        on_disk_version: sidecar_daemon_version().and_then(|t| parse_sidecar_version(&t)),
        resident_registered: resident_service_available(),
        resident_pid: platform::adapter().resident_daemon_pid(),
        user_stopped: is_user_stopped(&platform::adapter().data_dir()),
        transfer_active: devices.as_ref().map(any_transfer_active).unwrap_or(false),
    }
}

/// 壳启动时跑一次（独立线程）。等内核答上 status，再按判据换。
fn converge_kernel_on_startup(app: tauri::AppHandle) {
    // 内核可能还没起来（登录时壳比内核先就绪）——最多等 90s；一直不答上
    // 就交给既有的自愈，不在这里拉。
    let deadline = std::time::Instant::now() + RESTART_GRACE;
    while !daemon_online() {
        if std::time::Instant::now() >= deadline {
            eprintln!("#667: 内核一直不可达，跳过启动对账（交给自愈）");
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
            set_library_dir,
            start_daemon,
            daemon_startup_error,
            stop_daemon,
            pause_daemon_for_update,
            resume_daemon_after_update,
            restart_app,
            installed_app_version,
            relaunch_shell,
            self_heal_daemon,
            restart_daemon_process,
            kernel_convergence_phase,
            export_logs_bundle,
            allow_media_scope,
            notify_system,
            set_tray_locale
        ])
        .setup(|app| {
            // IPC-02: 启动即订阅——daemon 事件驱动 UI（扫码即时切弹窗、
            // 备份落地即时刷新），不依赖前端渲染时序。
            start_event_stream(app.handle().clone());
            // #604 [DESK-42]：开机自启登记对账——注册条目必须指向**当前安装
            // App 内**的 daemon。放独立线程：不一致时它会动 launchctl
            // （bootout + bootstrap），不该堵启动。
            std::thread::spawn(reconcile_autostart_registration);
            // UPD-06 (#616)：把壳登记成登录项（写 plist；下一次登录起由 launchd 接管，
            // 从那时起 kickstart 才是可用路径）。独立线程：只做一次文件读写。
            std::thread::spawn(register_shell_login_item);
            // UPD-07 (#617)：把自己（版本 + pid）报给 daemon —— owner 判断"壳旧不旧"
            // 的唯一来源。独立线程 + 重试，不阻塞启动，也不拖慢首屏。
            std::thread::spawn(announce_shell_identity);
            // #667：内核比磁盘上的旧 / 不归 launchd 管 ⇒ 自动换（尊重用户停止与传输中）。
            {
                let app = app.handle().clone();
                std::thread::spawn(move || converge_kernel_on_startup(app));
            }
            // I18N-03 (#492)：文案取自 assets/i18n（见 TRAY_ITEMS）；前端
            // 报上语言后 set_tray_locale 会再改一次字。
            let locale = tray_locale(&std::env::var("LANG").unwrap_or_default());
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
                        // 用户看不见；notify_system 在 Windows 上是 no-op，
                        // 靠不住。导出本身仍是前端 invoke export_logs_bundle，
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

    #[test]
    fn tray_locale_matches_the_frontend_rule() {
        // 与 src/lib/i18n.js 的 localeFor 同一条规则。
        for (lang, want) in [
            ("zh", "zh"),
            ("zh-CN", "zh"),
            ("zh-Hans", "zh"),
            ("zh_CN.UTF-8", "zh"),
            ("ZH-TW", "zh"),
            ("", "zh"),
            ("en", "en"),
            ("en-US", "en"),
            ("en_US.UTF-8", "en"),
            ("ja-JP", "en"),
        ] {
            assert_eq!(tray_locale(lang), want, "{lang:?}");
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
        let product = include_str!("lib.rs").split("#[cfg(test)]").next().unwrap();
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
        for src in [include_str!("lib.rs"), include_str!("ipc.rs")] {
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

    // ── DESK-27 (#219)：反斜杠翻倍回路 ────────────────────────────────
    //
    // 这一组测试就是卡面验收标准 3 要的「锁住幂等性」：把 `write_config` 里
    // 那句 `normalize_separators` 去掉，下面 doubled/quadrupled 那几条会立刻
    // 变红（本卡实施时实测过，反证输出贴在 PR 里）。

    /// 正常路径必须原样通过 —— 归一不许"顺手美化"没坏的东西。
    #[test]
    fn desk27_a_healthy_path_is_untouched() {
        for p in [
            "C:\\Users\\ethan\\Pictures",
            "C:\\",
            "relative\\sub",
            "/unix/style",
        ] {
            assert_eq!(normalize_separators(p), p, "健康路径被改动了: {p}");
        }
    }

    /// 被翻倍过的路径必须收敛回单分隔符 —— **任意轮数**。
    ///
    /// 这是本卡的正题：真机上已经翻到过每个分隔符四个反斜杠。修法按「折叠
    /// 重复分隔符」而不是「反转义 N 次」，所以不需要事先知道 N。
    #[test]
    fn desk27_any_number_of_doublings_converges() {
        let want = "C:\\Users\\ethan\\Pictures";
        for p in [
            "C:\\\\Users\\\\ethan\\\\Pictures",             // N=2
            "C:\\\\\\\\Users\\\\\\\\ethan\\\\\\\\Pictures", // N=4
            "C:\\\\\\\\\\\\\\\\Users\\\\\\\\\\\\\\\\ethan\\\\\\\\\\\\\\\\Pictures", // N=8
        ] {
            assert_eq!(normalize_separators(p), want, "没收敛: {p}");
        }
    }

    /// ⚠️ UNC 的**前导两个**分隔符是语义，不许折掉。
    ///
    /// 这条是本卡实施时实测否掉 `Path::components()` 方案的那个反例：
    /// `components()` 会把翻倍过的 UNC 折成**单个**前导分隔符，得到另一个
    /// （错的）路径 —— 比放着不修更坏，因为 Windows 至少还能折叠解析损坏的
    /// 那个，而单前导的版本指向完全不同的地方。
    #[test]
    fn desk27_unc_and_verbatim_prefixes_keep_their_leading_pair() {
        // 健康的 UNC / verbatim：原样。
        assert_eq!(
            normalize_separators("\\\\server\\share\\dir"),
            "\\\\server\\share\\dir"
        );
        assert_eq!(
            normalize_separators("\\\\?\\C:\\Users\\x"),
            "\\\\?\\C:\\Users\\x"
        );
        // 被翻倍过的 UNC / verbatim：前导收成两个，中间收成一个。
        assert_eq!(
            normalize_separators("\\\\\\\\server\\\\share\\\\dir"),
            "\\\\server\\share\\dir"
        );
        assert_eq!(
            normalize_separators("\\\\\\\\?\\\\C:\\\\Users\\\\x"),
            "\\\\?\\C:\\Users\\x"
        );
        // 单个前导分隔符（根相对路径）不许被撑成两个。
        assert_eq!(normalize_separators("\\Users\\x"), "\\Users\\x");
    }

    /// 幂等：再归一一次不再变。这条保证「写→读→再写」不会漂移。
    #[test]
    fn desk27_normalization_is_idempotent() {
        for p in [
            "C:\\Users\\x",
            "C:\\\\Users\\\\x",
            "C:\\\\\\\\Users\\\\\\\\x",
            "\\\\server\\share",
            "\\\\\\\\server\\\\share",
            "\\\\?\\C:\\x",
            "\\Users\\x",
            "no-separators-at-all",
            "",
        ] {
            let once = normalize_separators(p);
            let twice = normalize_separators(&once);
            assert_eq!(once, twice, "不幂等: {p} -> {once} -> {twice}");
        }
    }

    /// 非 Windows 的路径形状（无反斜杠）必须是恒等变换 —— 卡面验收标准 5：
    /// Linux/macOS 行为完全不变。
    #[test]
    fn desk27_paths_without_backslashes_are_identity() {
        for p in [
            "/home/ethan/Pictures/P-Pass",
            "/Users/ethan/Pictures/P-Pass 家庭照片库",
            "relative/path",
        ] {
            assert_eq!(normalize_separators(p), p);
        }
    }

    /// DESK-27 (#219) 验收标准 1 的可重复版本：**连续三轮，字节数必须相同**。
    ///
    /// 走的是向导的真实代码路径 —— `read_config_data_dir`（#209 的反转义）
    /// → 预填归一 → `render_config` → 写盘 —— 只是没有 GUI。真机点三次向导
    /// 与这三轮跑的是同一串函数；把它做成测试的好处是**可重复、会在回归时
    /// 变红**，而点 GUI 的记录只能证明当时那一次。
    ///
    /// 起点刻意用真机上观测到的**损坏形状**（每个分隔符四个反斜杠，卡面
    /// 2026-09-18 记的 309 字节 / 16 个 0x5C 就是这个形状），所以这条测试
    /// 同时覆盖了验收标准 2（存量修复）。
    #[test]
    fn desk27_three_wizard_rounds_are_byte_identical_and_repair_legacy() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");

        // 真机损坏态：data_dir = "C:@@@@Users@@@@ethan@@@@Pictures"
        // （文件里每个分隔符四个反斜杠）
        let legacy = format!(
            "data_dir = \"C:{s}{s}{s}{s}Users{s}{s}{s}{s}ethan{s}{s}{s}{s}Pictures\"\n",
            s = '\\'
        );
        std::fs::write(&cfg, &legacy).unwrap();
        let legacy_backslashes = std::fs::read(&cfg)
            .unwrap()
            .iter()
            .filter(|&&b| b == b'\\')
            .count();
        assert_eq!(legacy_backslashes, 12, "起点应当是损坏态（12 个 0x5C）");

        let mut rounds = Vec::new();
        let mut prefills = Vec::new();
        for _ in 0..3 {
            // 向导做的事：读回已配置的库目录 → 预填（归一）→ 用户不改 → 写回。
            let prefill = configured_library_dir(dir.path()).expect("读不到 data_dir");
            // 读侧归一：**第一轮**（还没写过）向导显示的就必须是正确路径——
            // 锁的是"UI 显示给用户的路径是错的"那条危害。
            prefills.push(prefill.clone());
            std::fs::write(&cfg, render_config(&prefill)).unwrap();
            let bytes = std::fs::read(&cfg).unwrap();
            let n = bytes.iter().filter(|&&b| b == b'\\').count();
            let parsed: toml::Value =
                toml::from_str(&String::from_utf8(bytes).unwrap()).expect("必须是合法 TOML");
            rounds.push((n, parsed["data_dir"].as_str().unwrap().to_string()));
        }

        // 打出来便于取证（`--nocapture` 可见；卡面要求贴三次的真实字节数）。
        println!(
            "DESK-27 起点 0x5C={legacy_backslashes}  三轮 0x5C={:?}  data_dir={:?}",
            rounds.iter().map(|r| r.0).collect::<Vec<_>>(),
            rounds[2].1
        );
        // 三轮的字节数必须完全相同 —— 改前是 N、2N、4N。
        assert_eq!(
            rounds[0].0, rounds[1].0,
            "第 1→2 轮反斜杠数变了: {rounds:?}"
        );
        assert_eq!(
            rounds[1].0, rounds[2].0,
            "第 2→3 轮反斜杠数变了: {rounds:?}"
        );

        // 且三轮解析出来都是**归一后的真实路径**（存量已修复）。
        let want = format!("C:{s}Users{s}ethan{s}Pictures", s = '\\');
        for (i, (_, v)) in rounds.iter().enumerate() {
            assert_eq!(v, &want, "第 {} 轮的 data_dir 不是归一值", i + 1);
        }
        for (i, v) in prefills.iter().enumerate() {
            assert_eq!(v, &want, "第 {} 轮向导预填的不是归一值", i + 1);
        }
    }

    /// 写入方产出的必须是**真 TOML**，且读回来等于**归一后**的路径。
    ///
    /// ⚠️ 刻意走 `render_config`（而不是直接调 `normalize_separators`）——
    /// 这样「把归一那步去掉」才会让本测试变红。卡面验收标准 3 要的就是这个；
    /// 只测归一函数本身的话，删掉调用点测试照样绿，那种反证等于没做。
    #[test]
    fn desk27_rendered_config_round_trips_and_is_normalized() {
        let want = "C:\\Users\\ethan\\Pictures\\P-Pass 家庭照片库";
        // 损坏输入（每个分隔符两个/四个反斜杠）必须写出健康值。
        for input in [
            want,
            "C:\\\\Users\\\\ethan\\\\Pictures\\\\P-Pass 家庭照片库",
            "C:\\\\\\\\Users\\\\\\\\ethan\\\\\\\\Pictures\\\\\\\\P-Pass 家庭照片库",
        ] {
            let doc = render_config(input);
            let parsed: toml::Value = toml::from_str(&doc)
                .unwrap_or_else(|e| panic!("产出的不是合法 TOML: {e} / doc={doc}"));
            assert_eq!(
                parsed["data_dir"].as_str().unwrap(),
                want,
                "render_config 没把 {input} 归一"
            );
        }
        // UNC / 含引号这些边界也要能往返（值等于归一后的自己）。
        for input in [
            "\\\\server\\share\\dir",
            "\\\\\\\\server\\\\share\\\\dir",
            "C:\\Users\\O'Brien\\Pics",
            "C:\\Users\\say \"hi\"\\Pics",
            // macOS / Linux 形状（家里 Mac 狗粮走的就是这条写入路径）。
            "/Users/ethan/Pictures/P-Pass 家庭照片库",
            "/home/ethan/Pictures/P-Pass",
        ] {
            let doc = render_config(input);
            let parsed: toml::Value =
                toml::from_str(&doc).unwrap_or_else(|e| panic!("不是合法 TOML: {e}"));
            assert_eq!(
                parsed["data_dir"].as_str().unwrap(),
                normalize_separators(input),
                "往返后值变了: {input}"
            );
        }
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

    // ── #667 / #732：自动换内核判据 ───────────────────────────────────

    fn facts(running: &str, on_disk: &str) -> KernelFacts {
        KernelFacts {
            running_version: Some(running.into()),
            running_pid: Some(100),
            on_disk_version: Some(on_disk.into()),
            resident_registered: true,
            resident_pid: Some(100),
            user_stopped: false,
            transfer_active: false,
        }
    }

    /// #667 验收 1 的判据：dmg 覆盖安装后内核比磁盘旧 ⇒ 现在就换。
    /// 反证：把 `Ordering::Less` 分支改成 InSync（= 去掉自动收敛），本测试必红。
    #[test]
    fn kernel_older_than_disk_converges() {
        assert!(matches!(
            kernel_convergence_verdict(&facts("0.9.1", "0.9.5")),
            KernelVerdict::Converge(_)
        ));
        assert!(matches!(
            kernel_convergence_verdict(&facts("0.9.5-test.1", "0.9.5")),
            KernelVerdict::Converge(_)
        ));
    }

    #[test]
    fn kernel_in_sync_and_managed_is_left_alone() {
        assert_eq!(
            kernel_convergence_verdict(&facts("0.9.5", "0.9.5")),
            KernelVerdict::InSync
        );
    }

    /// #732 ①：同版本但在跑的不是 launchd 那份（旧壳更新时一次性 spawn 的）⇒ 收编。
    #[test]
    fn kernel_same_version_but_unmanaged_converges() {
        let mut f = facts("0.9.5", "0.9.5");
        f.resident_pid = None; // launchd: not running
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Converge(_)
        ));
        f.resident_pid = Some(999); // launchd 手里是另一个 pid
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Converge(_)
        ));
        // 没有常驻登记（Windows Run key / 未登记）：没有"归谁管"可言 ⇒ 不动。
        f.resident_registered = false;
        assert_eq!(kernel_convergence_verdict(&f), KernelVerdict::InSync);
    }

    /// dmg 降级安装：内核比磁盘新 ⇒ 绝不把内核也降下去。
    #[test]
    fn kernel_newer_than_disk_is_never_downgraded() {
        assert!(matches!(
            kernel_convergence_verdict(&facts("0.9.5", "0.9.4")),
            KernelVerdict::Skip(_)
        ));
        let mut f = facts("0.9.5", "0.9.4");
        f.resident_pid = None; // 即使不归 launchd 管
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Skip(_)
        ));
    }

    /// #667 验收 2 ①：用户主动停过服务 ⇒ 一律不动（哪怕内核旧）。
    #[test]
    fn user_stop_beats_kernel_convergence() {
        let mut f = facts("0.9.1", "0.9.5");
        f.user_stopped = true;
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Skip(_)
        ));
    }

    /// #667 验收 2 ②：正在传输 ⇒ 推迟（不是失败、也不是放弃）。
    #[test]
    fn transfer_in_progress_defers_kernel_convergence() {
        let mut f = facts("0.9.1", "0.9.5");
        f.transfer_active = true;
        assert_eq!(kernel_convergence_verdict(&f), KernelVerdict::Defer);
        // 一致时传输与否都不动
        let mut g = facts("0.9.5", "0.9.5");
        g.transfer_active = true;
        assert_eq!(kernel_convergence_verdict(&g), KernelVerdict::InSync);
    }

    /// 读不到 = 不知道 = 不动（fail-safe）。
    #[test]
    fn unknown_versions_never_trigger_a_restart() {
        let mut f = facts("0.9.1", "0.9.5");
        f.on_disk_version = None;
        assert!(matches!(
            kernel_convergence_verdict(&f),
            KernelVerdict::Skip(_)
        ));
        let mut g = facts("0.9.1", "0.9.5");
        g.running_version = None;
        assert!(matches!(
            kernel_convergence_verdict(&g),
            KernelVerdict::Skip(_)
        ));
    }

    #[test]
    fn unmanaged_needs_a_known_running_pid() {
        assert!(daemon_is_unmanaged(Some(1), None));
        assert!(daemon_is_unmanaged(Some(1), Some(2)));
        assert!(!daemon_is_unmanaged(Some(1), Some(1)));
        assert!(
            !daemon_is_unmanaged(None, None),
            "读不到自报 pid 不许当野生实例去请它退位"
        );
    }

    #[test]
    fn sidecar_version_line_is_parsed() {
        assert_eq!(
            parse_sidecar_version("P-Pass daemon 0.9.5\n").as_deref(),
            Some("0.9.5")
        );
        assert_eq!(
            parse_sidecar_version("P-Pass daemon 0.9.5-test.2").as_deref(),
            Some("0.9.5-test.2")
        );
        assert_eq!(parse_sidecar_version("something else"), None);
        assert_eq!(parse_sidecar_version("P-Pass daemon "), None);
    }

    /// 「传输中」= 任何设备 `flow_connection` 非空——与设备行「传输中」同一信号（NET-05）。
    #[test]
    fn transfer_signal_is_the_flow_connection_field() {
        let idle = json!({"devices": [{"flow_connection": null}, {"name": "x"}]});
        assert!(!any_transfer_active(&idle));
        let busy = json!({"devices": [{"flow_connection": null}, {"flow_connection": "direct"}]});
        assert!(any_transfer_active(&busy));
        assert!(!any_transfer_active(&json!({})));
    }

    /// 与 daemon DAE-01 `version_cmp`（crates/daemon/src/ipc.rs）同一组样例——两份
    /// 实现若漂移，这里先红。
    #[test]
    fn version_cmp_matches_the_daemon_handshake() {
        use std::cmp::Ordering;
        assert_eq!(version_cmp("0.1.0", "0.1.0"), Ordering::Equal);
        assert_eq!(version_cmp("0.2.0", "0.1.0"), Ordering::Greater);
        assert_eq!(version_cmp("0.1.0", "0.2.0"), Ordering::Less);
        assert_eq!(version_cmp("1.0.0", "0.9.9"), Ordering::Greater);
        assert_eq!(version_cmp("0.10.0", "0.9.0"), Ordering::Greater);
        assert_eq!(version_cmp("0.2.0-test.7", "0.1.0"), Ordering::Greater);
        assert_eq!(version_cmp("0.1.0", "0.2.0-test.7"), Ordering::Less);
        assert_eq!(
            version_cmp("0.2.0-test.8", "0.2.0-test.7"),
            Ordering::Greater
        );
        assert_eq!(version_cmp("0.2.0-test.7", "0.2.0-test.8"), Ordering::Less);
        assert_eq!(
            version_cmp("0.2.0-test.10", "0.2.0-test.9"),
            Ordering::Greater
        );
        assert_eq!(version_cmp("0.2.0-test.8", "0.2.0-test.8"), Ordering::Equal);
        assert_eq!(version_cmp("0.2.0", "0.2.0-test.8"), Ordering::Greater);
        assert_eq!(version_cmp("0.2.0-test.8", "0.2.0"), Ordering::Less);
        assert_eq!(version_cmp("0.1.0", "0.1.0-test.3"), Ordering::Greater);
        assert_eq!(version_cmp("0.1.0-test.3", "0.1.0"), Ordering::Less);
        assert_eq!(version_cmp("", "0.0.0"), Ordering::Equal);
        assert_eq!(version_cmp("alpha", "0.1.0"), Ordering::Less);
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
        assert!(product.contains("std::thread::spawn(move || converge_kernel_on_startup(app));"));
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
        assert!(manual.contains("bring_up_daemon(true, false)"));
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

    #[test]
    fn probe_passes_only_on_exit_zero_with_our_marker() {
        assert!(sidecar_probe_verdict(Some(0), "P-Pass daemon 0.5.7-test.1\n").is_ok());
    }

    #[test]
    fn probe_rejects_a_program_that_is_not_our_daemon() {
        // 退出码 0 但不是我们的 daemon（被换成了别的 exe）。
        let e = sidecar_probe_verdict(Some(0), "Python 3.9.13\n").unwrap_err();
        assert!(
            render_err("zh", &e).contains("不是 P-Pass 的 daemon"),
            "{e}"
        );
        assert!(render_err("zh", &e).contains("Python 3.9.13"), "{e}");
    }

    #[test]
    fn probe_rejects_empty_output() {
        assert!(sidecar_probe_verdict(Some(0), "").is_err());
    }

    #[test]
    fn probe_rejects_nonzero_exit() {
        let e = sidecar_probe_verdict(Some(2), "P-Pass daemon 0.5.7-test.1").unwrap_err();
        assert!(render_err("zh", &e).contains("退出码 2"), "{e}");
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

    // ── DESK-36 (#456)：「用户主动停止」标记 + 自愈判据 ───────────────────
    //
    // 全部用 tempdir 注入 data dir——绝不调 stop_daemon / start_daemon 本体，
    // 它们会走真实 adapter（pkill ppf-daemon、launchctl bootout 真 agent）。

    /// 一个「向导走完了」的 data dir：config.toml 在。
    fn configured_data_dir() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("config.toml"), "library_dir = \"x\"\n").unwrap();
        dir
    }

    #[test]
    fn self_heal_revives_a_configured_daemon_that_was_not_stopped_by_the_user() {
        // 崩了 / 被更新流程停了又没拉回来（W1 那个 NSIS 场景）——自愈的本职。
        let dir = configured_data_dir();
        assert!(self_heal_allowed(dir.path()));
    }

    #[test]
    fn self_heal_never_revives_a_daemon_the_user_stopped() {
        // #456 本体：用户点了停止 → 自愈不许在冷却窗口过后把它拉回来。
        let dir = configured_data_dir();
        set_user_stopped(dir.path(), true).unwrap();
        assert!(
            !self_heal_allowed(dir.path()),
            "用户主动停止了服务，自愈却仍然判定要拉起它（#456）"
        );
    }

    #[test]
    fn user_stop_survives_an_app_restart() {
        // 持久化语义：标记在盘上，换一个「进程」（重新读同一目录）仍然在。
        let dir = configured_data_dir();
        set_user_stopped(dir.path(), true).unwrap();
        let reopened = dir.path().to_path_buf();
        assert!(is_user_stopped(&reopened));
        assert!(!self_heal_allowed(&reopened));
    }

    #[test]
    fn starting_the_service_clears_the_user_stop() {
        let dir = configured_data_dir();
        set_user_stopped(dir.path(), true).unwrap();
        set_user_stopped(dir.path(), false).unwrap();
        assert!(!is_user_stopped(dir.path()));
        assert!(self_heal_allowed(dir.path()), "点了启动之后自愈应当恢复");
        // 没停过也能清（首启向导调 start_daemon 时就是这种情况）。
        set_user_stopped(dir.path(), false).unwrap();
    }

    #[test]
    fn self_heal_stays_out_of_an_unconfigured_machine() {
        // 向导没走完不自愈——这条是原有语义，本卡不许改掉。
        let dir = tempfile::tempdir().unwrap();
        assert!(!self_heal_allowed(dir.path()));
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
        let kill = stop.find("kill_daemon_process()").expect("杀进程");
        assert!(mark < unregister && mark < kill, "标记必须先于停进程落下");
        assert!(body("start_daemon")
            .contains("set_user_stopped(&platform::adapter().data_dir(), false)?;"));
        // 托盘停止与窗口按钮必须是同一个实现（同一份标记）。
        assert!(product.contains("let result = stop_daemon_now();"));
    }

    #[test]
    fn wizard_state_reports_the_user_stop_to_the_frontend() {
        // 前端的向导门靠这一位区分「用户停了」和「向导中途退出」。
        // 只钉字段名与来源——wizard_state() 本体读真实 data dir，不在测试里调。
        let src = include_str!("lib.rs");
        let product = src.split("#[cfg(test)]").next().unwrap_or(src);
        assert!(product.contains("\"user_stopped\": is_user_stopped(&dir)"));
    }

    // ── #456 后续：更新流程也尊重「用户主动停止」 ─────────────────────────

    #[test]
    fn update_brings_back_a_daemon_the_user_did_not_stop() {
        // 没停过：pause 杀了什么，装完就拉回什么（W1 原语义不变）。
        let dir = configured_data_dir();
        assert!(update_resume_allowed(dir.path()));
    }

    #[test]
    fn update_never_revives_a_daemon_the_user_stopped() {
        // 规则：用户点了停止 → 一直停着，只有用户点「启动后台服务」才恢复。
        let dir = configured_data_dir();
        set_user_stopped(dir.path(), true).unwrap();
        assert!(
            !update_resume_allowed(dir.path()),
            "用户主动停止了服务，更新装完却仍然判定要拉起它（#456 后续）"
        );
        // 标记原样保留：更新之后界面仍是「启动后台服务」。
        assert!(is_user_stopped(dir.path()));
    }

    #[test]
    fn update_resume_does_not_require_a_finished_wizard() {
        // 「没停过时行为不变」：原来更新后恢复不看 config.toml，这里也不许加。
        let dir = tempfile::tempdir().unwrap();
        assert!(update_resume_allowed(dir.path()));
    }

    #[test]
    fn update_resume_command_checks_the_on_disk_marker_before_spawning() {
        // resume_daemon_after_update 本体走真实 adapter / current_exe，测试里不能调；
        // 钉接线：判据读的是 Rust 侧 data dir 上的标记，且在 spawn 之前；
        // 自愈与更新共用同一个 spawn，但各走各的判据。
        let src = include_str!("lib.rs").replace("\r\n", "\n");
        let product = src.split("#[cfg(test)]").next().unwrap_or(&src);
        let body = |name: &str| {
            let start = product
                .find(&format!("fn {name}("))
                .unwrap_or_else(|| panic!("找不到 fn {name}"));
            let rest = &product[start..];
            rest[..rest.find("\n}\n").expect("函数结尾")].to_string()
        };
        let resume = body("resume_daemon_after_update");
        let gate = resume
            .find("if !update_resume_allowed(&platform::adapter().data_dir()) {")
            .expect("resume_daemon_after_update 必须先读盘上的「用户主动停止」标记");
        // #732：更新后恢复 = 换版本（kill_running=true），走共用的 bring_up_daemon
        // （先交给 launchd，退路才一次性 spawn），退路必须带 post_update=true
        // （UPD-07 #617：只有更新拉起的 daemon 才允许换壳）。
        let spawn = resume
            .find("bring_up_daemon(true, true)")
            .expect("resume_daemon_after_update 走共用 bring_up_daemon(kill_running=true, post_update=true)");
        assert!(gate < spawn, "判据必须在 spawn 之前");
        let heal = body("self_heal_daemon");
        assert!(heal.contains("self_heal_allowed(&platform::adapter().data_dir())"));
        assert!(
            heal.contains("bring_up_daemon(false, false)"),
            "自愈与更新无关：不许带 post_update（否则 owner 会在非更新场合去换壳），也不许杀在跑的内核"
        );
        // 退路的一次性 spawn 仍按 post_update 带参数。
        let up = body("bring_up_daemon");
        assert!(up.contains("spawn_bundled_daemon_oneshot(post_update)"));
        assert!(
            !heal.contains("resume_daemon_after_update()"),
            "自愈不该绕进更新路径的判据"
        );
    }
    /// UPD-05 (#605)：restart_app 命令已注册，且 App.svelte 在
    /// downloadAndInstall 成功路径里调用它（装完重启外壳）。
    #[test]
    fn restart_app_is_registered_and_called_after_install() {
        let src = include_str!("lib.rs");
        assert!(
            src.contains("fn restart_app(app: tauri::AppHandle)"),
            "restart_app 命令缺失"
        );
        assert!(
            src.contains("restart_app,"),
            "restart_app 未注册进 invoke_handler"
        );
        let app = include_str!("../../src/App.svelte");
        let install = app
            .find("await update.downloadAndInstall(")
            .expect("App.svelte 缺 downloadAndInstall");
        // UPD-06 (#616)：换壳走 relaunch_shell（系统路径 kickstart 优先、壳自己
        // 重启兜底），不再是裸的 restart_app——restart_app 现在只是它的退化分支。
        // ⚠️ 比的是**调用点**：`relaunchShellNow` 的定义体在文件里更靠前，比定义
        // 位置会得出反向结论（本测试第一版就是这么红的）。
        let call = app
            .find("await relaunchShellNow();")
            .expect("App.svelte 缺换壳调用点");
        assert!(call > install, "换壳必须在 downloadAndInstall 之后调用");
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
        let src = include_str!("lib.rs");
        assert!(
            src.contains("std::thread::spawn(register_shell_login_item);"),
            "启动时必须登记壳的登录项（否则 launchd 永远接管不到壳）"
        );
        let f = src
            .find("fn register_shell_login_item()")
            .expect("register_shell_login_item 缺失");
        let body: String = src[f..].chars().take(1200).collect();
        assert!(
            body.contains("shell_agent_label()"),
            "没有服务管理器的平台要直接跳过"
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
        let src = include_str!("lib.rs");
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
            src.contains("installed_app_version,"),
            "installed_app_version 未注册进 invoke_handler"
        );
    }

    // ══ DESK-46 (#638)：set_library_dir —— 换库写职责归壳 ═════════════

    // merge 是纯函数：只换 data_dir，其余逐字节保留；新键落在首个
    // [section] 之前（2026-07-31 crash-loop 教训）；值是真 TOML。
    // 反证：merge 若改成整份重写（丢掉 bind_addr 等），本测试必须红。
    #[test]
    fn desk46_merge_replaces_data_dir_and_keeps_everything_else() {
        let doc = "data_dir = \"/old/library\"\n\n# 固定端口\nbind_addr = \"0.0.0.0:41145\"\n\nrelay_urls = []\n\n[telemetry]\nenabled = false\n";
        let out = merge_library_dir(doc, "/Volumes/My Passport");
        let parsed: toml::Value = toml::from_str(&out).expect("merge 产物必须是合法 TOML");
        assert_eq!(parsed["data_dir"].as_str().unwrap(), "/Volumes/My Passport");
        assert_eq!(parsed["bind_addr"].as_str().unwrap(), "0.0.0.0:41145");
        assert_eq!(parsed["relay_urls"].as_array().unwrap().len(), 0);
        assert!(!parsed["telemetry"]["enabled"].as_bool().unwrap());
        // 注释逐字节还在——其余内容不许被重写（E4）。
        assert!(out.contains("# 固定端口"));
        // 顶层键必须落在首个 [section] 之前。
        let key_pos = out.find("data_dir").unwrap();
        let section_pos = out.find('[').expect("原文有 [telemetry]");
        assert!(key_pos < section_pos, "顶层键必须落在首个 [section] 之前");
    }

    // DESK-46 + DESK-27 同款：Windows 路径先归一、再走真 TOML 序列化，
    // 写→读→再写必须逐字节幂等。反证：换回 `{:?}` 或去掉归一必须红。
    #[test]
    fn desk46_merge_windows_path_roundtrip_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let path = "C:\\Users\\ethan\\P-Pass 家庭照片库";
        let once = merge_library_dir("", path);
        std::fs::write(dir.path().join("config.toml"), &once).unwrap();
        let back = configured_library_dir(dir.path()).expect("写出去必须读得回");
        assert_eq!(back, path, "写→读不得变形（反斜杠不许翻倍）");
        let twice = merge_library_dir(&once, &back);
        assert_eq!(once, twice, "写→读→再写必须逐字节幂等");
    }

    // 校验判据（纯函数，文件系统事实由调用点注入）。
    // 反证：把任一 arm 摘掉，对应断言必须红。
    #[test]
    fn desk46_target_verdicts() {
        // 正常：存在 + 可写 + 不嵌套。
        assert!(library_target_verdict("/new/lib", Some("/old/lib"), true, true).is_ok());
        // 不存在（或不是目录）⇒ keyed missing。
        let e = library_target_verdict("/nope", Some("/old/lib"), false, true).unwrap_err();
        assert!(e.contains("ui.err_library_target_missing"), "{e}");
        // 不可写 ⇒ keyed readonly。
        let e = library_target_verdict("/ro", None, true, false).unwrap_err();
        assert!(e.contains("ui.err_library_target_readonly"), "{e}");
        // 相同 / 嵌套 ⇒ keyed nested（三个方向都要拦）。
        for (cur, new) in [
            ("/old/lib", "/old/lib"),
            ("/old/lib", "/old/lib/sub"),
            ("/old/lib/photos", "/old/lib"),
        ] {
            let e = library_target_verdict(new, Some(cur), true, true).unwrap_err();
            assert!(e.contains("ui.err_library_nested"), "{cur} vs {new}: {e}");
        }
        // 兄弟目录不算嵌套（分隔符边界：/old/lib2 ⊄ /old/lib）。
        assert!(library_target_verdict("/old/lib2", Some("/old/lib"), true, true).is_ok());
        // 没配过库（current=None）不做嵌套检查。
        assert!(library_target_verdict("/anywhere", None, true, true).is_ok());
    }

    #[test]
    fn desk46_paths_overlap_boundaries() {
        assert!(paths_overlap("/a/b", "/a/b/"));
        assert!(paths_overlap("/a/b", "/a/b/c"));
        assert!(paths_overlap("/a/b/c", "/a/b"));
        assert!(!paths_overlap("/a/b", "/a/bc"));
        assert!(!paths_overlap("/a/b", "/a/c"));
        // Windows：混输分隔符与大小写。
        assert!(paths_overlap("C:\\Lib", "c:\\lib\\sub"));
        assert!(!paths_overlap("C:\\Lib", "C:\\Lib2"));
        assert!(paths_overlap("C:/Lib/sub", "C:\\Lib"));
    }

    // ══ DESK-49 (#710)：换库读 config 失败不得被吞 ═══════════════════

    const DESK49_FULL_CFG: &str = "data_dir = \"/old/library\"\n\nbind_addr = \"0.0.0.0:41145\"\n\nrelay_urls = []\n\n[telemetry]\nenabled = false\n";

    // 读失败但写能成功 ⇒ 返回 keyed 错误、文件内容逐字节不变（E2 反证主测）。
    // 用非 UTF-8 造读失败：跨平台、不需要平台分叉（B.2）。
    // 为什么不用「权限 000」：000 连写都失败，旧实现会因「写失败」同样返回
    // Err，测试假绿（反证实测如此）；可写不可读（0o200）需要按平台设权限，
    // 该能力应进 crates/platform 的 test-support，不在本卡范围。
    // 反证：换回 `read_to_string(..).unwrap_or_default()`，本测试必须红。
    #[test]
    fn desk49_non_utf8_config_errors_and_keeps_file() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");
        let bytes: &[u8] = b"data_dir = \"/old\"\nbind_addr = \"\xff\xfe\"\n";
        std::fs::write(&cfg, bytes).unwrap();
        let e = rewrite_library_dir(&cfg, "/new/library").unwrap_err();
        assert!(e.contains("ui.err_set_library"), "{e}");
        assert_eq!(std::fs::read(&cfg).unwrap(), bytes, "读失败时不得写文件");
    }

    // 不存在 ⇒ 当空配置，正常创建，只含新 data_dir。
    #[test]
    fn desk49_missing_config_is_created() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");
        rewrite_library_dir(&cfg, "/new/library").expect("不存在应正常创建");
        let parsed: toml::Value = toml::from_str(&std::fs::read_to_string(&cfg).unwrap()).unwrap();
        assert_eq!(parsed["data_dir"].as_str().unwrap(), "/new/library");
    }

    // 正常可读 ⇒ 只换 data_dir，其它字段保留。
    #[test]
    fn desk49_readable_config_keeps_other_fields() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");
        std::fs::write(&cfg, DESK49_FULL_CFG).unwrap();
        rewrite_library_dir(&cfg, "/new/library").unwrap();
        let parsed: toml::Value = toml::from_str(&std::fs::read_to_string(&cfg).unwrap()).unwrap();
        assert_eq!(parsed["data_dir"].as_str().unwrap(), "/new/library");
        assert_eq!(parsed["bind_addr"].as_str().unwrap(), "0.0.0.0:41145");
        assert_eq!(parsed["relay_urls"].as_array().unwrap().len(), 0);
        assert!(!parsed["telemetry"]["enabled"].as_bool().unwrap());
    }

    // DESK-46 (#638) 契约门禁（源码扫描）：
    // ① 写入目标必须是平台目录的 config.toml（孤儿文件不得复活）；
    // ② 前端只调壳侧 set_library_dir，folder.set 永远退役；
    // ③ 命令注册进 invoke_handler；
    // ④ daemon 侧的 folder.set 写者已删除（跨 crate 扫描）。
    #[test]
    fn desk46_library_dir_writer_is_shell_only() {
        let src = include_str!("lib.rs");
        assert!(src.contains("fn set_library_dir(library_dir: String)"));
        assert!(
            src.contains("set_library_dir,"),
            "set_library_dir 未注册进 invoke_handler"
        );
        let f = src.find("fn set_library_dir").expect("命令必须存在");
        let body: String = src[f..].chars().take(1200).collect();
        assert!(
            body.contains("platform::adapter().data_dir()"),
            "写入目标必须是平台目录（DESK-46 根因就是写去了库目录）"
        );
        let app = include_str!("../../src/App.svelte");
        assert!(
            app.contains("invoke(\"set_library_dir\""),
            "前端 chooseFolder 必须改调壳侧 set_library_dir"
        );
        assert!(
            !app.contains("\"folder.set\""),
            "folder.set 已退役（DESK-46），前端不得再调"
        );
        let daemon_ipc = include_str!("../../../../crates/daemon/src/ipc.rs");
        assert!(
            !daemon_ipc.contains("\"folder.set\" =>"),
            "daemon 侧的 folder.set 写者必须删除（DESK-46：写职责归壳）"
        );
        assert!(
            !daemon_ipc.contains("write_folder_config"),
            "write_folder_config 必须随 folder.set 一起删除"
        );
    }
}
