// DESK-23 (#172)：「关掉窗口只是藏到托盘」这条提示要不要弹。
//
// 抽成纯函数是刻意的：卡面验收标准 3 要求「macOS 上不出现该提示」，而本仓
// 没有 Mac、PR CI 里也没有任何 job 会跑 macOS（#278）。端到端验不了，但
// **判定规则本身**可以在任何平台上单测——真正会出错的是这条规则，不是
// 它的调用处。
//
// DESK-69 (#997)：「哪个平台要提示」挪进 platformUx.js 的 closeToTrayHint，
// 平台来源统一为 plugin-os；这里只剩「提示过就不再打扰」。
import { closeToTrayHint } from "./platformUx.js";

/**
 * localStorage 的键。
 *
 * 为什么是 localStorage 而不是 config.toml：这是 UI 偏好，不是 daemon 的
 * 配置；而且 `write_config` 写的是固定模板、整文件重写，向导跑一次就会把
 * 额外的 key 抹掉（#172 里逐条核过其它候选通道）。
 */
export const TRAY_HINT_SHOWN_KEY = "ppf.trayHintShown";

/**
 * @param {string} platform  plugin-os 的 `platform()`（未覆盖的平台会抛错）
 * @param {string|null} alreadyShown  localStorage 读到的值；读不到传 null
 * @returns {boolean} 要不要弹
 */
export function shouldShowTrayHint(platform, alreadyShown) {
  if (!closeToTrayHint(platform)) return false;
  return !alreadyShown;
}
