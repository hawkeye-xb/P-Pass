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

/**
 * `<video>` onerror 的生成代际守卫：错误事件只能落在「发起它的那一次
 * 渲染」的 viewer 上，而不是读可变全局。token 是随 `<video>` 元素一起
 * 渲染的不可变身份快照（gen 单调递增，hash 是当前 asset），错误到达时
 * 用它同时在 thumb.get 前后校验：只要活跃代不再等于这个 token，就丢弃。
 *
 * 为什么不能只比 hash：关闭再打开同一个 hash（或 A 的迟到错误在 B 已
 * 打开后到达）都要求「错误归属于它自己那次渲染」而不是「任一相同 hash」。
 * gen 是在打开 viewer 时就定死的标记，关闭重开会递增，旧 DOM 元素随
 * `{#key}` 卸载后它的错误事件仍带着旧 gen，自然被判为过期。
 *
 * @param {{
 *   token: {gen: number, hash: string},
 *   isActive: () => boolean,
 *   loadThumb: (hash: string) => Promise<
 *     {kind: "thumb", src: string} | {kind: "failed"} | {kind: "cancelled"}
 *   >,
 * }} deps
 * @returns {Promise<
 *   "ignored" | {kind: "applied", result:
 *     {kind: "thumb", src: string} | {kind: "failed"} | {kind: "cancelled"}
 *   }
 * >}
 */
export async function handleVideoError({ token, isActive, loadThumb }) {
  // 错误事件的来源元素必须仍是当前 viewer 的那一次渲染；不是则根本
  // 不用发 thumb.get 请求（早期短路，也挡掉同 hash 的旧代错误）。
  if (!token || !isActive()) return "ignored";
  const r = await loadThumb(token.hash);
  // await 之后重判一次：请求期间 viewer 又换人/关闭了 → 丢弃，不许覆盖。
  if (!isActive()) return "ignored";
  return { kind: "applied", result: r };
}