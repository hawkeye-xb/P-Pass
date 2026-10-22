// #1120：后台方法 → 壳的具名命令（src-tauri/src/daemon_api.rs）。
//
// 没有通用转发：只有这里列出的方法能调，未知方法当场抛错。名单之外的方法
// 即使绕过本表直接 invoke，也会被 Tauri 的 capabilities 拒绝。
import { invoke } from "@tauri-apps/api/core";

export const DAEMON_COMMANDS = Object.freeze({
  status: "daemon_status",
  "low_space.ack": "daemon_low_space_ack",
  "pairing.start": "daemon_pairing_start",
  "pairing.pending": "daemon_pairing_pending",
  "pairing.confirm": "daemon_pairing_confirm",
  "devices.list": "daemon_devices_list",
  "device.watermarks": "daemon_device_watermarks",
  "device.revoke": "daemon_device_revoke",
  "device.rename": "daemon_device_rename",
  "device.folder": "daemon_device_folder",
  "audit.list": "daemon_audit_list",
  "timeline.page": "daemon_timeline_page",
  "thumb.get": "daemon_thumb_get",
  "asset.original": "daemon_asset_original",
  "asset.path": "daemon_asset_path",
});

const METHOD_OF = Object.freeze(
  Object.fromEntries(Object.entries(DAEMON_COMMANDS).map(([m, c]) => [c, m])),
);

/** 具名命令名 → 后台方法名；不是后台命令返回 undefined（测试的 invoke 桩用）。 */
export function daemonMethodOf(command) {
  return Object.prototype.hasOwnProperty.call(METHOD_OF, command) ? METHOD_OF[command] : undefined;
}

/** 调一个后台方法。参数键名与后台服务一致（snake_case）。 */
export function callDaemon(method, params = {}) {
  if (!Object.prototype.hasOwnProperty.call(DAEMON_COMMANDS, method)) {
    return Promise.reject(new Error(`daemon method not exposed to the webview: ${method}`));
  }
  return invoke(DAEMON_COMMANDS[method], params);
}
