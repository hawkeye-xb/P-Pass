import { hasKey } from "./i18n.js";

/**
 * daemon 起不来时向导红条用哪句话（#1044 / B13）。
 *
 * `failure` 是壳的 `daemon_startup_error` 给的 `{ key, detail }`：`key` 是
 * daemon 自己认出的已知原因（i18n key，例如库比本版本新），`detail` 是 stderr
 * 原文。这里不用正则去猜原文——认原因是 daemon 的事。B13：原文只进 console，
 * 不进界面；红条显示 key 的文案和错误代码。
 *
 * @param {{key?: string|null, detail?: string}|null} failure
 * @returns {string|null} 已登记的原因 key；没有就 null（调用方用兜底文案）
 */
export function startupFailureKey(failure) {
  const detail = String(failure?.detail || "").trim();
  if (detail) console.warn("[daemon startup] stderr:", detail);
  return failure?.key && hasKey(failure.key) ? failure.key : null;
}
