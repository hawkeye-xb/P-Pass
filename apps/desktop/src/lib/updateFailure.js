// #1063：安装失败横幅的纯逻辑（App.svelte 只做接线，便于单测）。
//
// 失败标记由安装器 `.onInstFailed` 写（install-failed / version / service），
// 新壳启动读一次；用户点「重试」或「关闭」后清掉。

/** 手动下载入口：发布页（与站点 consts 的 RELEASES_URL 同源）。 */
export const RELEASES_URL = "https://github.com/hawkeye-xb/P-Pass/releases/latest";

/** 横幅正文 key：知道目标版本就带上，不知道就退回泛化文案。 */
export function updateFailureBodyKey(state) {
  return state?.version
    ? "ui.update_failed_banner_body_version"
    : "ui.update_failed_banner_body";
}

/** 交给 t() 的参数；没有版本时给空对象，绝不显示 `{version}` 原文。 */
export function updateFailureBodyParams(state) {
  return state?.version ? { version: state.version } : {};
}

/** 服务状态那一行：安装器恢复了服务 / 用户本来停过 / 还在恢复中。 */
export function updateFailureServiceKey(state, serviceRunning) {
  if (!state?.service_restored) return "ui.update_failed_service_stopped";
  return serviceRunning
    ? "ui.update_failed_service_restored"
    : "ui.update_failed_service_pending";
}
