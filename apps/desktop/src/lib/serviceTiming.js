// 桌面前端的服务时序常量（#1049：从 App.svelte 提出来，供
// docs/desktop/business-rules.zh-CN.md §12 常量表测试导入比对）。

/** 前端自愈（self_heal_daemon）两次尝试之间的冷却（§8.3）。 */
export const SELF_HEAL_COOLDOWN_MS = 30000;

/** 兜底刷新周期：事件之外每隔这么久对一次 status（§6.6）。 */
export const FALLBACK_REFRESH_MS = 60000;
