//! #1120：网页能调的后台方法，一个方法一个具名命令。
//!
//! 以前前端经通用转发 `daemon_call(method, params)` 把任意方法原样转给后台
//! 服务——窗口程序持有调用全部方法的权限（#1115），网页层能做什么必须收到最窄。
//! 现在每个命令只转发自己那一个方法，参数有类型；能不能调由 capabilities
//! 逐个声明（`build.rs` 的 `AppManifest` + `capabilities/default.json`），
//! 三处名单由 `lib.rs` 的 `command_lists_agree` 测试钉成同一份。
//!
//! 参数名沿用后台服务的 snake_case（`rename_all = "snake_case"`），前端传的
//! 键名与 daemon 收到的字段名一字不差。

use serde_json::{json, Value};

use crate::{ipc, ServiceStateManager};
use tauri::Manager;

/// 所有具名命令的同一条出口：发出去，失败记进诊断（DESK-63 #946）。
fn forward(app: &tauri::AppHandle, method: &str, params: Value) -> Result<Value, String> {
    match ipc::DaemonHandle::discover().and_then(|d| d.call(method, params)) {
        Ok(value) => Ok(value),
        Err(e) => {
            // 数据调用失败不改服务状态（见 service_state），但必须进诊断包。
            app.state::<ServiceStateManager>()
                .log_call_failure(method, &e);
            Err(e)
        }
    }
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_status(
    app: tauri::AppHandle,
    shell_version: Option<String>,
) -> Result<Value, String> {
    forward(&app, "status", json!({ "shell_version": shell_version }))
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_low_space_ack(app: tauri::AppHandle) -> Result<Value, String> {
    forward(&app, "low_space.ack", json!({}))
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_pairing_start(app: tauri::AppHandle) -> Result<Value, String> {
    forward(&app, "pairing.start", json!({}))
}

/// #1122：二维码关闭——配对窗口立即关闭（收回未用的令牌）。
#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_pairing_stop(app: tauri::AppHandle) -> Result<Value, String> {
    forward(&app, "pairing.stop", json!({}))
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_pairing_pending(app: tauri::AppHandle) -> Result<Value, String> {
    forward(&app, "pairing.pending", json!({}))
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_pairing_confirm(
    app: tauri::AppHandle,
    accept: bool,
    node_id: Option<String>,
    device_name: Option<String>,
) -> Result<Value, String> {
    forward(
        &app,
        "pairing.confirm",
        json!({ "accept": accept, "node_id": node_id, "device_name": device_name }),
    )
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_devices_list(
    app: tauri::AppHandle,
    include_departed: bool,
) -> Result<Value, String> {
    forward(
        &app,
        "devices.list",
        json!({ "include_departed": include_departed }),
    )
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_device_watermarks(app: tauri::AppHandle) -> Result<Value, String> {
    forward(&app, "device.watermarks", json!({}))
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_device_revoke(
    app: tauri::AppHandle,
    node_id: String,
) -> Result<Value, String> {
    forward(&app, "device.revoke", json!({ "node_id": node_id }))
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_device_rename(
    app: tauri::AppHandle,
    node_id: String,
    name: String,
) -> Result<Value, String> {
    forward(
        &app,
        "device.rename",
        json!({ "node_id": node_id, "name": name }),
    )
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_device_folder(
    app: tauri::AppHandle,
    node_id: String,
) -> Result<Value, String> {
    forward(&app, "device.folder", json!({ "node_id": node_id }))
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_audit_list(
    app: tauri::AppHandle,
    limit: u32,
    visibility: String,
) -> Result<Value, String> {
    forward(
        &app,
        "audit.list",
        json!({ "limit": limit, "visibility": visibility }),
    )
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_timeline_page(
    app: tauri::AppHandle,
    cursor: Option<String>,
    limit: u32,
) -> Result<Value, String> {
    forward(
        &app,
        "timeline.page",
        json!({ "cursor": cursor, "limit": limit }),
    )
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_thumb_get(
    app: tauri::AppHandle,
    hash: String,
    size: String,
) -> Result<Value, String> {
    forward(&app, "thumb.get", json!({ "hash": hash, "size": size }))
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_asset_original(app: tauri::AppHandle, hash: String) -> Result<Value, String> {
    forward(&app, "asset.original", json!({ "hash": hash }))
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) fn daemon_asset_path(app: tauri::AppHandle, hash: String) -> Result<Value, String> {
    forward(&app, "asset.path", json!({ "hash": hash }))
}
