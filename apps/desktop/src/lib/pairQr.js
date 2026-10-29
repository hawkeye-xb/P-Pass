// #1264：配对二维码还能不能扫，以 daemon 说的失效时刻为准（`pairing.start` 应答的
// `expires_at_ms`，令牌 TTL 只在 daemon 里有一份）。窗口只拿当前时刻去比，不自己算有效期。
//
// 标准做法（网页扫码登录）：码快到期就自动换一张；自动换几次后停下，把过期的码盖住、
// 给「刷新」按钮——弹窗开着一夜不应让配对入口（#1122）也开一夜。

/** 离失效还剩这么久时自动换码：留够手机扫码到发出申请的时间。 */
export const QR_REFRESH_LEAD_MS = 30_000;
/** 一次打开弹窗最多自动换几次码；之后盖住过期的码，等人点刷新。 */
export const QR_AUTO_REFRESH_MAX = 3;

/**
 * 弹窗里这张码此刻该怎么处理。
 * - `"show"`：照常显示；
 * - `"refresh"`：快到期了，自动换一张（调用方计次）；
 * - `"expired"`：已经失效，盖住，等人点刷新。
 *
 * `expiresAt` 不是有限数（老版本 daemon 不给）⇒ 一律 `"show"`：不换码、不盖码，保持原行为，
 * 也绝不会因为拿 undefined 比较而陷入不停换码。
 */
export function qrPhase({ now, expiresAt, autoRefreshes, lead = QR_REFRESH_LEAD_MS, max = QR_AUTO_REFRESH_MAX }) {
  if (!Number.isFinite(expiresAt)) return "show";
  if (autoRefreshes < max && now >= expiresAt - lead) return "refresh";
  return now > expiresAt ? "expired" : "show";
}
