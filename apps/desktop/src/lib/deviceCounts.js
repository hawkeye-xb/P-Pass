// #1402 卡1：设备计数只有一份口径，由 daemon 的 `status` 给——`paired_devices`
// 只数有授权的（手机自己断开的另计 `disconnected_devices`，
// crates/daemon/src/ipc.rs）。这里只把两个数拼成用户读的那一行，不自己数列表：
// 前端一数就会出现「顶部 1 台、卡片 0 台」这类各说各话。

import { t } from "./i18n.js";

/** 计数后面补的「（另有 M 台已断开）」；没有已断开的就没有这句。 */
export function disconnectedClause(disconnected) {
  return disconnected > 0 ? t("ui.disconnected_count", { n: disconnected }) : "";
}

/** 没有在用设备的空状态。有已断开的要说清是几台，别和顶部计数打架。 */
export function noDevicesText(disconnected) {
  return disconnected > 0
    ? t("ui.no_devices_disconnected", { n: disconnected })
    : t("ui.no_devices");
}
