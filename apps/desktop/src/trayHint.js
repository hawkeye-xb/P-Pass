// DESK-23 (#172)：「关掉窗口只是藏到托盘」这条提示要不要弹。
//
// 抽成纯函数是刻意的：卡面验收标准 3 要求「macOS 上不出现该提示」，而本仓
// 没有 Mac、PR CI 里也没有任何 job 会跑 macOS（#278）。端到端验不了，但
// **判定规则本身**可以在任何平台上单测——真正会出错的是这条规则，不是
// 它的调用处。

/**
 * localStorage 的键。
 *
 * 为什么是 localStorage 而不是 config.toml：这是 UI 偏好，不是 daemon 的
 * 配置；而且 `write_config` 写的是固定模板、整文件重写，向导跑一次就会把
 * 额外的 key 抹掉（#172 里逐条核过其它候选通道）。
 */
export const TRAY_HINT_SHOWN_KEY = "ppf.trayHintShown";

/**
 * @param {string|undefined|null} platform  `wizard_state` 给的平台标识
 * @param {string|null} alreadyShown  localStorage 读到的值；读不到传 null
 * @returns {boolean} 要不要弹
 */
export function shouldShowTrayHint(platform, alreadyShown) {
  // macOS 上点红灯不退出是常态，用户不需要解释（卡面验收标准 3）。
  //
  // 平台读不到时也**不弹**：这个方向上宁可少说一次，也不要在 macOS 上
  // 冒出一句对那儿的用户毫无意义、甚至误导的话。代价（Windows 用户偶尔
  // 少收到一次提示）远小于反过来。
  if (platform !== "windows") return false;
  return !alreadyShown;
}
