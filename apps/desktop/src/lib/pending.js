// DEV-04（2026-09-20 验收人实测）：一台**以前连过**的手机断开后重新扫码，
// 桌面弹的还是首次配对那一套「有设备请求加入 / 允许后它会出现在设备列表里」。
// 它本来就在列表里——#253 把它留住了，这里却还当陌生人。
//
// 验收人原话：
//
// > 我在 macOS 重新配对的时候，显示的不是重新配对，
// > 也不是我修改之后的设备名称。
//
// 判据是 `node_id`，**不是名字**：改过名的设备重连依然要认得出来，
// 并且用**桌面上**那个名字称呼它。手机自报名只在库里还没有这一行时作数。
//
// 不降低授权门槛——重连照样要业主点「允许」。本文件只管措辞与信息量。
//
// 纯函数，无 DOM/Tauri 依赖（同 disconnected.js / connection.js 的惯例）。
//
// 契约（crates/daemon/src/ipc.rs pairing.pending）：
//   node_id      hex string
//   known        bool          ← 有没有设备档案（档案永不删除，#1117）
//   name         string        ← known 时是桌面上的名字，否则手机自报名
//   paired_at    unix ms       ← 仅 known：第一次配对成功的时间（设备档案）
//   paired       bool          ← 仅 known：当前有没有配对记录
//   photo_count  int           ← 仅 known

import { t } from "./i18n.js";

/** 这条 pending 是老设备重连吗。 */
export function isKnownDevice(item) {
  return Boolean(item?.known);
}

/**
 * 审批弹窗的标题：单台直接写请求内容（「名字 请求加入 / 请求重新连接」）；
 * 多台时不点名，只报数量——每块以设备名开头，各自带副行（见 pendingSubText）。
 *
 * @param {Array<object>} pendingList pairing.pending 的全量列表
 */
export function pendingDialogText(pendingList) {
  const list = Array.isArray(pendingList) ? pendingList : [];
  if (list.length > 1) {
    return { title: t("ui.pending_many_title", { n: list.length }) };
  }
  const only = list[0];
  if (!only) return { title: "" };
  // 标题直接写请求内容，点名，且点的是桌面上的名字——业主改过名就叫改过的那个。
  return {
    title: t(isKnownDevice(only) ? "ui.pending_known_title" : "ui.pending_one_title", { name: only.name }),
  };
}

/**
 * 单行副文案：老设备摆出「以前连过」的实证，新设备什么都不说。
 *
 * 照片数是业主该知道的事——「恢复备份」恢复的是**这些**照片的续传，
 * 不是从零开始。
 *
 * @param {object} item pairing.pending 的一行
 * @param {string|null} pairedAtText 已人性化的首次配对时刻（humanTime 输出）
 */
export function pendingSubText(item, pairedAtText = null) {
  if (!isKnownDevice(item)) return null;
  const parts = [];
  if (pairedAtText) parts.push(t("ui.pending_sub_paired_at", { time: pairedAtText }));
  const n = Number(item?.photo_count ?? 0);
  if (n > 0) parts.push(t("ui.pending_sub_photos", { n }));
  return parts.length > 0 ? parts.join(" · ") : t("ui.pending_sub_known");
}

/**
 * 「允许」按钮该用哪个文案键。
 *
 * 标题说「请求重新连接」而按钮说「允许加入」是同一种串台——老设备本来
 * 就在列表里，"加入"这个动词在这一屏是错的。
 *
 * 返回键名而不是文案：由调用方 t() 取词（按钮在模板里渲染）。
 */
export function pendingAllowKey(item) {
  return isKnownDevice(item) ? "ui.allow_reconnect" : "ui.allow";
}

/**
 * DEV-06: 配对结果提示（`ui.pair_allowed` / `ui.pair_denied`）该怎么称呼
 * 这台设备。
 *
 * `pairing.confirm` 回的 `device` 是队列里的**自报名**（daemon
 * `IpcServer::confirm` 取的是请求里的 device_name），业主在桌面改过的名字它不知道。
 * pending 行的 `name` 则已经由 daemon 按上面那条口径解析过：known 时是
 * 设备表里的名字，否则才是自报名——审批弹窗标题正因为用它才是对的。
 *
 * 所以优先级是 pending 行 → confirm 回执。首次配对两者本就相同，取谁都
 * 一样；改过名的老设备重连，只有前者是业主认得的那个称呼。
 *
 * 回执是回退而不是摆设：横幅上那两个按钮不带 item（走 daemon 队首语义），
 * 前端手上没有对应的 pending 行。
 *
 * @param {object|null|undefined} item pairing.pending 的那一行（可能没有）
 * @param {object|null|undefined} resp pairing.confirm 的回执
 * @returns {string} 插值用的名字；两者都没有时给空串，不渲染 undefined
 */
export function pairResultName(item, resp) {
  const fromTable = typeof item?.name === "string" ? item.name.trim() : "";
  if (fromTable) return fromTable;
  return typeof resp?.device === "string" ? resp.device.trim() : "";
}

/**
 * #1118：确认 = 输入手机屏幕上的 6 位验证码。只有恰好 6 位数字才能提交（只能试一次，
 * 不让手滑的半截码白白作废这次配对）。
 */
export function isPairCode(code) {
  return /^[0-9]{6}$/.test(String(code ?? "").trim());
}

/** #1118：输入框里只留数字、最多 6 位（粘贴「123 456」也能用）。 */
export function normalizePairCode(raw) {
  return String(raw ?? "").replace(/[^0-9]/g, "").slice(0, 6);
}

/**
 * #1118：`pairing.confirm` 的结果提示。允许后 daemon 最多等 8 秒手机的确认：
 * 等到了 = 已加入；没等到（`verifying`）= 验证码已提交、还在等手机。
 * 码不对走错误分支（`pair_code_wrong` → ui.err_pair_code_wrong），不在这里。
 */
export function pairConfirmToast(accept, reply, shownName) {
  if (!accept) return { key: "ui.pair_denied", params: { name: shownName }, tone: "warning" };
  if (reply?.verifying) return { key: "ui.pair_verifying", params: { name: shownName }, tone: "info" };
  return { key: "ui.pair_allowed", params: { name: shownName }, tone: "success" };
}
