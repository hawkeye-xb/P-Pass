// #1577（#1402 卡2）：15 天「很久没联系」提示。
//
// 设备行仍「已配对」、但 last_seen 距今超过 15 天时，电脑无从区分「手机
// 关机了」和「手机已经把我忘了」（#1402 场景 4/6：断开通知没送到、或换手机
// 留下幽灵行）。与其假装知道，不如照实提示「很久没联系，可能已在手机上
// 断开」，行上给「移除」。
//
// 时间源与 presence.rs 一致——都是 devices.list 的 last_seen（unix 毫秒）；
// 但这是**前端新增的提示档**，不碰 presence.rs 的 5 天离线哨兵，也不碰
// 5 天的「需要看看」备份告警（它们量的是不同东西：这里是「多久没上报
// 在线」，那边是「多久没备份成功」）。
//
// 纯函数，无 DOM/Tauri 依赖。

const STALE_HINT_MS = 15 * 24 * 3600 * 1000;

/**
 * last_seen 距今是否超过 15 天（严格大于；正好 15 天不算）。
 * 缺失 / 0 / 负值 → false（没有上报过就别猜）。
 */
export function staleHint(lastSeen, nowMs = Date.now()) {
  if (typeof lastSeen !== "number" || !Number.isFinite(lastSeen) || lastSeen <= 0) return false;
  return nowMs - lastSeen > STALE_HINT_MS;
}
