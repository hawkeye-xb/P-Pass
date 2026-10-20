// #1054 图片大图加载编排：按 daemon 给的真实 media_type 组 data URL，
// `<img>` 解不了（onerror）时回退 1024 缩略图。可单测，App.svelte 只做接线。
import { loadVideoThumbnail } from "./viewerVideo.js";

// 只接受形如 image/<子类型> 的 MIME，防止任意字符串（含 `;`、`,`）拼进 URL。
// 不限定具体格式：能不能解码由 `<img>` 决定，解不了走 onerror 回退。
const IMAGE_MIME = /^image\/[a-z0-9][a-z0-9.+-]*$/;

/** `asset.original` 回复 → data URL；media_type 缺失/不合法（旧 daemon）按 jpeg。 */
export function originalDataUrl(o) {
  const mt = String(o?.media_type ?? "").toLowerCase();
  const type = IMAGE_MIME.test(mt) ? mt : "image/jpeg";
  return `data:${type};base64,${o.data_base64}`;
}

/**
 * 打开图片大图：asset.original 成功给原图；失败（含超过上限、视频等
 * daemon 返回 NotFound）→ thumb.get 1024；都失败才 failed。每步过 isCancelled 闸。
 *
 * @returns {Promise<{kind:"original"|"thumb", src:string}|{kind:"failed"}|{kind:"cancelled"}>}
 */
export async function loadImageViewer(deps, { hash }) {
  const { call, isCancelled } = deps;
  try {
    const o = await call("asset.original", { hash });
    if (isCancelled()) return { kind: "cancelled" };
    return { kind: "original", src: originalDataUrl(o) };
  } catch (_) {
    if (isCancelled()) return { kind: "cancelled" };
    return loadVideoThumbnail(deps, { hash });
  }
}

/**
 * `<img>` onerror：当前显示的是原图 → 回退缩略图；已经是缩略图（或已失败）
 * → failed，不再循环。isActive 防止旧 viewer 的迟到错误覆盖新 viewer。
 *
 * @returns {Promise<{kind:"thumb", src:string}|{kind:"failed"}|{kind:"ignored"}>}
 */
export async function handleImageError({
  call,
  hash,
  showingOriginal,
  isActive,
}) {
  if (!isActive()) return { kind: "ignored" };
  if (!showingOriginal) return { kind: "failed" };
  const r = await loadVideoThumbnail(
    { call, isCancelled: () => !isActive() },
    { hash },
  );
  if (r.kind === "cancelled") return { kind: "ignored" };
  return r;
}
