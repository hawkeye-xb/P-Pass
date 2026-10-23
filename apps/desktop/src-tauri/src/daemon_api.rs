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
///
/// 等 IPC 是阻塞活（`pairing.confirm` 要等手机回执，最多 8s），放阻塞线程池：
/// 同步命令跑在主线程上，等待期间整个窗口无响应（统一回归：点「确认加入」卡约 1s）。
async fn forward<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    method: &'static str,
    params: Value,
) -> Result<Value, String> {
    crate::off_main(move || forward_blocking(&app, method, params)).await?
}

fn forward_blocking<R: tauri::Runtime>(
    app: &tauri::AppHandle<R>,
    method: &str,
    params: Value,
) -> Result<Value, String> {
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
pub(crate) async fn daemon_status<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    shell_version: Option<String>,
) -> Result<Value, String> {
    forward(app, "status", json!({ "shell_version": shell_version })).await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_low_space_ack<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
) -> Result<Value, String> {
    forward(app, "low_space.ack", json!({})).await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_pairing_start<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
) -> Result<Value, String> {
    forward(app, "pairing.start", json!({})).await
}

/// #1122：二维码关闭——配对窗口立即关闭（收回未用的令牌）。
#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_pairing_stop<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
) -> Result<Value, String> {
    forward(app, "pairing.stop", json!({})).await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_pairing_pending<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
) -> Result<Value, String> {
    forward(app, "pairing.pending", json!({})).await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_pairing_confirm<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    accept: bool,
    node_id: Option<String>,
    device_name: Option<String>,
    // #1118：允许 = 输入手机显示的 6 位验证码。
    code: Option<String>,
) -> Result<Value, String> {
    forward(
        app,
        "pairing.confirm",
        json!({ "accept": accept, "node_id": node_id, "device_name": device_name, "code": code }),
    )
    .await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_devices_list<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    include_departed: bool,
) -> Result<Value, String> {
    forward(
        app,
        "devices.list",
        json!({ "include_departed": include_departed }),
    )
    .await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_device_watermarks<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
) -> Result<Value, String> {
    forward(app, "device.watermarks", json!({})).await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_device_revoke<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    node_id: String,
) -> Result<Value, String> {
    forward(app, "device.revoke", json!({ "node_id": node_id })).await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_device_rename<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    node_id: String,
    name: String,
) -> Result<Value, String> {
    forward(
        app,
        "device.rename",
        json!({ "node_id": node_id, "name": name }),
    )
    .await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_device_folder<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    node_id: String,
) -> Result<Value, String> {
    forward(app, "device.folder", json!({ "node_id": node_id })).await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_audit_list<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    limit: u32,
    visibility: String,
) -> Result<Value, String> {
    forward(
        app,
        "audit.list",
        json!({ "limit": limit, "visibility": visibility }),
    )
    .await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_timeline_page<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    cursor: Option<String>,
    limit: u32,
) -> Result<Value, String> {
    forward(
        app,
        "timeline.page",
        json!({ "cursor": cursor, "limit": limit }),
    )
    .await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_thumb_get<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    hash: String,
    // 后台 `ThumbSize` 的线上格式是整数（256 / 1024），前端也传数字。
    size: u32,
) -> Result<Value, String> {
    forward(app, "thumb.get", json!({ "hash": hash, "size": size })).await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_asset_original<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    hash: String,
) -> Result<Value, String> {
    forward(app, "asset.original", json!({ "hash": hash })).await
}

#[tauri::command(rename_all = "snake_case")]
pub(crate) async fn daemon_asset_path<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    hash: String,
) -> Result<Value, String> {
    forward(app, "asset.path", json!({ "hash": hash })).await
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};
    use tauri::ipc::{CallbackFn, InvokeBody};
    use tauri::test::{get_ipc_response, mock_builder, mock_context, noop_assets, INVOKE_KEY};
    use tauri::webview::InvokeRequest;

    use crate::service_state::{ServiceState, ServiceStateManager};

    /// 前端实际发出的参数（键名、JSON 类型与 App.svelte / PhotoThumb / viewer*.js 一致）。
    /// 走 Tauri 真实的命令参数反序列化：类型对不上时命令体根本不执行、
    /// 前端直接拿到 `invalid args`——#1120 后照片墙全灰就是这样（size 是数字 256）。
    fn frontend_calls() -> Vec<(&'static str, Value)> {
        vec![
            ("daemon_status", json!({ "shell_version": "0.10.0" })),
            ("daemon_low_space_ack", json!({})),
            ("daemon_pairing_pending", json!({})),
            (
                "daemon_pairing_confirm",
                json!({ "accept": true, "node_id": "n", "device_name": "d", "code": "123456" }),
            ),
            ("daemon_devices_list", json!({ "include_departed": true })),
            ("daemon_device_watermarks", json!({})),
            ("daemon_device_revoke", json!({ "node_id": "n" })),
            (
                "daemon_device_rename",
                json!({ "node_id": "n", "name": "x" }),
            ),
            ("daemon_device_folder", json!({ "node_id": "n" })),
            (
                "daemon_audit_list",
                json!({ "limit": 500, "visibility": "user" }),
            ),
            (
                "daemon_timeline_page",
                json!({ "cursor": null, "limit": 60 }),
            ),
            (
                "daemon_timeline_page",
                json!({ "cursor": "c", "limit": 60 }),
            ),
            ("daemon_thumb_get", json!({ "hash": "00", "size": 256 })),
            ("daemon_thumb_get", json!({ "hash": "00", "size": 1024 })),
            ("daemon_asset_original", json!({ "hash": "00" })),
            ("daemon_asset_path", json!({ "hash": "00" })),
        ]
    }

    #[tauri::command]
    fn probe_sync_wait() -> Result<(), String> {
        std::thread::sleep(std::time::Duration::from_millis(400));
        Ok(())
    }

    #[tauri::command]
    async fn probe_async_wait() -> Result<(), String> {
        crate::off_main(|| std::thread::sleep(std::time::Duration::from_millis(400))).await
    }

    /// 根因证据（确认加入卡约 1s）：同步命令在**投递 IPC 消息的那个线程**上把活干完
    /// 才返回——真实 App 里那就是主线程（WKWebView / WebView2 的消息回调），等 IPC
    /// 期间窗口无响应。async + off_main 的命令，消息投递立刻返回。
    #[test]
    fn sync_command_holds_the_delivering_thread() {
        let app = mock_builder()
            .invoke_handler(tauri::generate_handler![probe_sync_wait, probe_async_wait])
            .build(mock_context(noop_assets()))
            .expect("mock app");
        let webview = tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
            .build()
            .expect("mock webview");
        // 本地来源用 webview 自己的 URL：Windows 上 Tauri 的本地协议是 http://tauri.localhost，
        // 写死 tauri://localhost 会被当成远端来源，app 命令在执行前就被拒（Windows CI 实测空过）。
        let local_url = webview.url().expect("webview url");
        let deliver = |cmd: &str| {
            let (tx, rx) = std::sync::mpsc::channel();
            let started = std::time::Instant::now();
            webview.as_ref().clone().on_message(
                InvokeRequest {
                    cmd: cmd.into(),
                    callback: CallbackFn(0),
                    error: CallbackFn(1),
                    url: local_url.clone(),
                    body: InvokeBody::Json(json!({})),
                    headers: Default::default(),
                    invoke_key: INVOKE_KEY.to_string(),
                },
                Box::new(move |_, _, response, _, _| {
                    let _ = tx.send(matches!(response, tauri::ipc::InvokeResponse::Ok(_)));
                }),
            );
            let held = started.elapsed();
            // 命令必须真的执行了（被来源校验拒掉也会立刻返回，那就什么都没测）。
            assert!(rx.recv().expect("response"), "{cmd} 没有执行");
            held
        };
        let sync_held = deliver("probe_sync_wait");
        let async_held = deliver("probe_async_wait");
        assert!(
            sync_held >= std::time::Duration::from_millis(350),
            "sync 占住了 {sync_held:?}"
        );
        assert!(
            async_held < std::time::Duration::from_millis(100),
            "async 占住了 {async_held:?}"
        );
    }

    #[test]
    fn frontend_params_deserialize_into_every_named_command() {
        let tmp = tempfile::tempdir().unwrap();
        let app = mock_builder()
            .manage(ServiceStateManager::new(
                ServiceState::Running,
                tmp.path().join("service.log"),
            ))
            .invoke_handler(tauri::generate_handler![
                super::daemon_status,
                super::daemon_low_space_ack,
                super::daemon_pairing_pending,
                super::daemon_pairing_confirm,
                super::daemon_devices_list,
                super::daemon_device_watermarks,
                super::daemon_device_revoke,
                super::daemon_device_rename,
                super::daemon_device_folder,
                super::daemon_audit_list,
                super::daemon_timeline_page,
                super::daemon_thumb_get,
                super::daemon_asset_original,
                super::daemon_asset_path,
            ])
            .build(mock_context(noop_assets()))
            .expect("mock app");
        let webview = tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
            .build()
            .expect("mock webview");

        let local_url = webview.url().expect("webview url");
        for (cmd, params) in frontend_calls() {
            let res = get_ipc_response(
                &webview,
                InvokeRequest {
                    cmd: cmd.into(),
                    callback: CallbackFn(0),
                    error: CallbackFn(1),
                    url: local_url.clone(),
                    body: InvokeBody::Json(params.clone()),
                    headers: Default::default(),
                    invoke_key: INVOKE_KEY.to_string(),
                },
            );
            // 命令体执行了就行：本机有没有后台服务、调用成不成功不是这里要验的。
            if let Err(e) = res {
                let e = e.to_string();
                assert!(
                    !e.contains("invalid args"),
                    "{cmd} {params}: 参数没进到命令体：{e}"
                );
                // 失败也必须是命令体里出来的（我们的 keyed 错误：连不上 / 后台拒绝），
                // 不能是来源校验、ACL 在命令执行前就拒掉——那样这条测试等于空过。
                assert!(
                    e.contains("\\\"key\\\""),
                    "{cmd} {params}: 命令没有执行：{e}"
                );
            }
        }
    }
}
