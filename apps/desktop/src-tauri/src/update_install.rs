//! #1121：应用内更新的下载与安装收在 Rust 里，安装前多一道发布者校验。
//!
//! 以前前端直接调 updater 插件的 download / install：插件只验 minisign 签名，没有
//! 地方插别的检查，而且网页能绕开任何外加的校验直接装。现在：
//! - 网页对 updater 插件只剩 `allow-check`（显示有没有新版、说明是什么）；
//! - 下载、校验、安装是这里的两个命令，校验和安装用**同一份内存里的字节**，中间不重新下载；
//! - 校验 = 插件自带的 minisign 验签（`Update::download` 内）+
//!   `platform::verify_update_package`（macOS：新包必须是团队 2WJUWVUJBN 签名的桌面主 App，
//!   且包内版本严格高于当前版本——防降级，#1116 P2-2）。
//!
//! 顺序与 #1060 一致：前端先 `update_download`（daemon 照常跑），再暂停 daemon，再
//! `update_install`。进度事件的形状与插件 JS 端的 `DownloadEvent` 相同，前端的进度逻辑不变。

use std::sync::Mutex;

use platform::update_limits::{
    with_limits, with_timeout, ByteBudget, MANIFEST_TIMEOUT, PACKAGE_MAX_BYTES, PACKAGE_TIMEOUT,
};
use serde::Serialize;
use tauri::ipc::Channel;
use tauri::Manager;
use tauri_plugin_updater::{Update, UpdaterExt};

use crate::ipc::ui_err;

/// 已下载、已校验、等待安装的更新。
#[derive(Default)]
pub(crate) struct PendingUpdate(Mutex<Option<(Update, Vec<u8>)>>);

/// 与 `@tauri-apps/plugin-updater` 的 `DownloadEvent` 同形。
#[derive(Clone, Serialize)]
#[serde(tag = "event", content = "data")]
pub(crate) enum DownloadEvent {
    #[serde(rename_all = "camelCase")]
    Started {
        content_length: Option<u64>,
    },
    #[serde(rename_all = "camelCase")]
    Progress {
        chunk_length: usize,
    },
    Finished,
}

/// 再查一次更新（必须是前端展示给用户的那个版本），下载，验签（插件内），校验发布者，
/// 存起来等安装。任何一步不过都不留下可安装的东西。
#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn update_download(
    app: tauri::AppHandle,
    expected_version: String,
    on_event: Channel<DownloadEvent>,
) -> Result<(), String> {
    let pending = app.state::<PendingUpdate>();
    *pending.0.lock().map_err(|e| e.to_string())? = None;

    // #1151：清单有总时长上限（插件内部读清单没有字节回调，大小只能靠超时兜）。
    let updater = app.updater().map_err(|e| e.to_string())?;
    let update = with_timeout(MANIFEST_TIMEOUT, updater.check())
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| ui_err("ui.err_update_none", &[]))?;
    if update.version != expected_version {
        return Err(ui_err(
            "ui.err_update_version_changed",
            &[("found", &update.version), ("shown", &expected_version)],
        ));
    }

    // #1151：安装包有大小上限与总时长上限。字节回调同时喂进 ByteBudget；超限即丢弃下载
    // （连接随之关闭），不留下可安装的东西。
    let budget = ByteBudget::new(PACKAGE_MAX_BYTES);
    let mut started = false;
    let bytes = with_limits(
        PACKAGE_TIMEOUT,
        budget.clone(),
        update.download(
            |chunk, total| {
                budget.on_chunk(chunk, total);
                if !started {
                    started = true;
                    let _ = on_event.send(DownloadEvent::Started {
                        content_length: total,
                    });
                }
                let _ = on_event.send(DownloadEvent::Progress {
                    chunk_length: chunk,
                });
            },
            || {
                let _ = on_event.send(DownloadEvent::Finished);
            },
        ),
    )
    .await
    .map_err(|e| e.to_string())?;

    // #1116 P2-2：包内（签名封装覆盖的）版本必须严格高于正在运行的版本——清单里的版本号不签名，不能信。
    let current = app.package_info().version.to_string();
    match platform::verify_update_package(&bytes, &current) {
        platform::UpdatePackageCheck::Verified => {}
        platform::UpdatePackageCheck::NotChecked(why) => {
            // 不是通过，是本平台还不能检查：记下来，照常走（只有 minisign 那一道）。
            eprintln!("#1121: 更新包未做发布者校验：{why}");
        }
        // #1155：Windows 没有发布者签名，只做了「包内版本严格高于当前」这一道。
        // 单独记一条：这不是签名校验通过，别把日志读成 Verified。
        platform::UpdatePackageCheck::VersionOnly => {
            eprintln!("#1155: Windows 更新包只做了防降级校验（无发布者签名）");
        }
        platform::UpdatePackageCheck::Rejected(why) => {
            return Err(ui_err(
                "ui.err_update_publisher_rejected",
                &[("reason", &why)],
            ));
        }
    }

    *pending.0.lock().map_err(|e| e.to_string())? = Some((update, bytes));
    Ok(())
}

/// 安装 [`update_download`] 校验过的那份字节。没有就报错，不会临时再下载。
#[tauri::command]
pub(crate) async fn update_install(app: tauri::AppHandle) -> Result<(), String> {
    let taken = app
        .state::<PendingUpdate>()
        .0
        .lock()
        .map_err(|e| e.to_string())?
        .take();
    let (update, bytes) = taken.ok_or_else(|| ui_err("ui.err_update_not_downloaded", &[]))?;
    update.install(bytes).map_err(|e| e.to_string())
}
