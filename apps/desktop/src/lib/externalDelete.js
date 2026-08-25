// MOB-29（2026-08-25 用户定调）：从库里删掉的照片会被手机传回来——
// **这是对的**（存储端不该丢数据），但删除发生在这台电脑上，所以警告
// 也该出在这里：告诉用户删了什么、会被传回来、想真删该怎么做。
//
// ## 为什么只针对 delete
//
// | 访达操作 | 对我们的影响 | 态度 |
// |---|---|---|
// | 往库里 add   | 零——被收录，按用户摆的位置采纳 | 鼓励（WATCH-04 不变） |
// | 库里 move    | 零——按 hash 重新认领（`asset.relocated`） | 随便挪 |
// | 从库里 delete| **有**——会被传回来 | **警告，引导从源头删** |
//
// 所以判据只认 `asset.removed_external` 这一个 action。`asset.relocated`
// / `ingest.*` 一律不算——警告一旦对"挪个位置"也响，用户就会开始无视它。
//
// ## 为什么不做归因
//
// 对账把索引行删掉之后，**没有任何东西**能告诉桌面端「这张照片是不是
// 手机传上来的」——那行没了。所以文案用条件从句（"还在手机上的那些会被
// 传回来"），在「手机来源」「访达手动放进来的」两种情况下都成立。这与
// 手机端那句提示是同一条原则：不做精确归因，只让用户知道默认行为。

/** 警告的时间窗：删除是**刚刚**发生的事才值得警告。审计流里的陈年
 *  删除记录不该在每次打开 App 时再吓一次。 */
export const EXTERNAL_DELETE_WINDOW_MS = 24 * 60 * 60 * 1000;

/**
 * 审计事件流 → 该不该出警告。
 *
 * @param events 审计行（`audit.list` 的 `{ action, ts }`，ts = unix ms）
 * @param nowMs 现在（unix ms）
 * @param opts.windowMs 时间窗（默认 [EXTERNAL_DELETE_WINDOW_MS]）
 * @param opts.dismissedAt 用户点过「知道了」的时刻——**该时刻及之前**的
 *   删除不再警告；之后又删了则重新出现（一次 dismiss 不换来永久静默）。
 * @returns `{ count, latestAt }`，无可警告的删除时返回 `null`（调用方
 *   据此整块隐藏）。
 */
export function externalDeleteNotice(events, nowMs, opts = {}) {
  const windowMs = opts.windowMs ?? EXTERNAL_DELETE_WINDOW_MS;
  const dismissedAt = opts.dismissedAt ?? 0;
  let count = 0;
  let latestAt = 0;
  for (const e of events ?? []) {
    if (!e || e.action !== "asset.removed_external") continue;
    const ts = Number(e.ts);
    if (!Number.isFinite(ts)) continue;
    // 窗外的旧记录不警告；已 dismiss 的那一批也不再警告。
    if (nowMs - ts > windowMs) continue;
    if (ts <= dismissedAt) continue;
    count += 1;
    if (ts > latestAt) latestAt = ts;
  }
  return count > 0 ? { count, latestAt } : null;
}
