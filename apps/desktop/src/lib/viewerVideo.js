// MOB-47 视频查看器加载编排 —— 纯函数，依赖全部注入，零 Svelte / 零
// IPC 依赖，可单测。承载的正是 L2 审查点名的三条契约：
//
//   1. asset 协议只收 hash（后端按 daemon 记录解析 + canonicalize +
//      只授权单个文件），绝不把渲染进程给的任意路径卷入 scope；
//   2. asset 协议失败（scope 拒绝/文件缺失/不支持）→ thumb.get 缩略图
//      兜底；缩略图也失败才判失败；
//   3. 每一步都过 isCancelled 闸——旧的异步响应不能覆盖已关闭/已换人的
//      viewer。

/**
 * 视频查看器的加载结果分派。
 *
 * @param {{invoke: Function, call: Function, convertFileSrc: Function,
 *          isCancelled: () => boolean}} deps
 * @param {{hash: string, size?: number}} asset
 * @returns {Promise<
 *   | {kind: "video", src: string, path: string}
 *   | {kind: "thumb", src: string}
 *   | {kind: "failed"}
 *   | {kind: "cancelled"}>}
 */
export async function loadVideoViewer(deps, { hash, size = 1024 }) {
  const { invoke, call, convertFileSrc, isCancelled } = deps;
  try {
    // 后端只收 hash：记录查找 → canonicalize → 只授权这一个文件，
    // 返回 canonical 路径（前端转 asset:// URL + Finder 揭示共用）。
    const canon = await invoke("allow_media_scope", { hash });
    if (isCancelled()) return { kind: "cancelled" };
    return { kind: "video", src: convertFileSrc(canon), path: canon };
  } catch (_) {
    // asset 协议失败 → 走既有 thumb.get 缩略图（图片路径不变的回退）。
    return loadVideoThumbnail(deps, { hash, size });
  }
}

/**
 * 视频播放里的缩略图兜底（`<video>` onerror / asset 协议失败共用）——
 * thumb.get 成功给缩略图、也失败才判 failed，且每步都过 isCancelled 闸。
 *
 * @param {{call: Function, isCancelled: () => boolean}} deps
 * @param {{hash: string, size?: number}} asset
 */
export async function loadVideoThumbnail(deps, { hash, size = 1024 }) {
  const { call, isCancelled } = deps;
  try {
    const t = await call("thumb.get", { hash, size });
    if (isCancelled()) return { kind: "cancelled" };
    return { kind: "thumb", src: `data:image/jpeg;base64,${t.jpeg_base64}` };
  } catch (_) {
    // 缩略图也失败 → 才真正判失败。
    if (isCancelled()) return { kind: "cancelled" };
    return { kind: "failed" };
  }
}