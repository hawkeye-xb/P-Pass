// 桌面首页的阻断状态——首页提示分级（docs/design/2026-09-22-home-notice-priority.md §2.1）的
// L1「阻塞：备份完全停了」。在场时它就是首页的结论：
// - 英雄标题换成状态本身，不再说「安全地住在这台电脑上」（规则 G/H：阻塞时不给完成度结论）；
// - 副标题里的配对数、照片数不渲染——服务此刻答不出它们，显示 0 比不显示更糟；
// - 侧栏胶囊与阻断卡用它的含义色（tokens.json rules：红 = 需要用户动手，琥珀 = 等待），页面不出现绿色。
// 每个阻断都有用户自己走得通的消除路径（启动服务 / 放回照片库后重新检查）。
// 胶囊文案必须在侧栏宽度下一行放得下：可用 151px（216 − 侧栏内边距 24 − 边框 1 − 胶囊内边距 24 − 圆点 8 − 间距 8），
// 13px/600 实测：「已暂停：找不到照片库」130、「已暂停：后台服务未运行」143、
// "Paused: library missing" 144、"Paused: service is off" 133、「已暂停：正在搬迁」104、
// "Paused: moving library" 141。

/**
 * @param {string} serviceState 壳的服务状态（running / starting / stopped / unreachable / not_configured）
 * @param {object|null} status 后台 `status` 应答
 * @returns {{ id: string, tone: "act" | "waiting", headlineKey: string, pillKey: string } | null}
 */
export function homeBlocker(serviceState, status) {
  if (serviceState === "starting") {
    return { id: "service_starting", tone: "waiting", headlineKey: "ui.blocked_service_starting", pillKey: "ui.blocked_service_starting_pill" };
  }
  if (serviceState !== "running") {
    return { id: "service_down", tone: "act", headlineKey: "ui.blocked_service_down", pillKey: "ui.blocked_service_down_pill" };
  }
  // #639：正在搬迁照片库——等待（琥珀），搬完自动恢复，用户不用动手。
  if (status?.relocating) {
    return { id: "relocating", tone: "waiting", headlineKey: "ui.blocked_relocating", pillKey: "ui.blocked_relocating_pill" };
  }
  if (status?.library_missing) {
    return { id: "library_missing", tone: "act", headlineKey: "ui.blocked_library_missing", pillKey: "ui.blocked_library_missing_pill" };
  }
  return null;
}
