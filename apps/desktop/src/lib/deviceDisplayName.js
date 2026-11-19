// #1433：设备在界面上显示的名字，统一走这一个函数——列表主行、水位卡、
// 移除确认弹窗各写一套，口径一定会漂（#1406 引入兜底名时只覆盖了主行）。
//
// 兜底口径（#1406 产品定案）：设备名为空时显示「手机型号 · 设备 ID 前 4 位」
// （例 `SM-S9210 · 3f2a`），拿不到型号就用「手机 · <ID 前 4 位>」。ID 取自设备
// 列表 ID 列显示的同一个短指纹（devices.list 的 node_id）。
//
// 现状：devices.list 的行还不带型号（crates/daemon/src/ipc.rs 的 devices.list
// 只给 node_id/name/role/... ），所以线上恒走「拿不到型号」那一支。型号分支按
// #1406 先实现并钉住，daemon 补上 model 字段即自动生效，不用再改这里。
//
// 纯函数，无 DOM/Tauri 依赖（同 pending.js / disconnected.js 的惯例）。

import { t } from "./i18n.js";

/**
 * 设备在界面上显示的名字：有名字用名字，空名回退到兜底名（有型号用型号，否则「手机」）。
 *
 * @param {{ name?: string|null, model?: string|null, node_id?: string|null }} d devices.list 的一行
 * @returns {string}
 */
export function displayName(d) {
  const name = d?.name?.trim();
  if (name) return name;
  const id = String(d?.node_id ?? "").slice(0, 4);
  // 型号是设备自报的产品名（SM-S9210 之类），不翻译；「 · 」是分隔符，
  // 与 pending.js 里 parts.join(" · ") 同一个写法，不走 i18n 键。
  const model = d?.model?.trim();
  return model ? `${model} · ${id}` : t("ui.device_fallback_name", { id });
}
