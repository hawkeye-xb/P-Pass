// #1433：设备在界面上显示的名字，统一走这一个函数——列表主行、水位卡、
// 移除确认弹窗各写一套，口径一定会漂（#1406 引入兜底名时只覆盖了主行）。
//
// 兜底口径（#1406 产品定案）：设备名为空时显示「手机型号 · 设备 ID 前 4 位」，
// 拿不到型号就用「手机 · <ID 前 4 位>」。ID 取自设备列表 ID 列显示的同一个短
// 指纹（devices.list 的 node_id）。
//
// 现状：devices.list 的行不带型号（crates/daemon/src/ipc.rs 的 devices.list
// 只给 node_id/name/role/... ），所以恒走「拿不到型号」那一支，文案键
// ui.device_fallback_name = 「手机 · {id}」。
//
// 纯函数，无 DOM/Tauri 依赖（同 pending.js / disconnected.js 的惯例）。

import { t } from "./i18n.js";

/**
 * 设备在界面上显示的名字：有名字用名字，空名回退到「手机 · <ID 前 4 位>」。
 *
 * @param {{ name?: string|null, node_id?: string|null }} d devices.list 的一行
 * @returns {string}
 */
export function displayName(d) {
  const name = d?.name?.trim();
  if (name) return name;
  return t("ui.device_fallback_name", { id: String(d?.node_id ?? "").slice(0, 4) });
}
