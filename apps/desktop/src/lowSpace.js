// #413 §7：照片库所在卷剩余空间低于固定阈值时，发一次桌面系统通知。
//
// 抽成纯函数，理由同 trayHint.js：系统通知本身端到端验不了（macOS 走
// osascript，Windows 目前是 no-op），真正会写错的是"什么时候发"这条规则。
//
// 数据来源：status.disk_free_bytes（daemon `disk_stats(data_dir)`，与手机侧
// hello.health.free_bytes 同一个 statvfs 口径）；拿不到是 null。

/** 固定阈值 5 GiB——与手机 `DesktopHealth.lowSpace`（FlowContract.kt）一致。 */
export const LOW_SPACE_THRESHOLD_BYTES = 5 * 1024 ** 3;

/**
 * 通知过之后，要回升到这条线以上才重新布防。留 1 GiB 回差：空间在 5 GiB
 * 附近来回抖（边备份边清理）时，不能每次轮询都弹一次。
 */
export const LOW_SPACE_REARM_BYTES = 6 * 1024 ** 3;

/**
 * @param {boolean} armed  上一次的布防状态（进程启动时为 true）
 * @param {unknown} freeBytes  status.disk_free_bytes
 * @returns {{notify: boolean, armed: boolean}}
 */
export function nextLowSpace(armed, freeBytes) {
  // 未知不是"满了"：既不通知，也不改变布防状态。
  if (typeof freeBytes !== "number" || !Number.isFinite(freeBytes) || freeBytes < 0) {
    return { notify: false, armed };
  }
  if (armed && freeBytes < LOW_SPACE_THRESHOLD_BYTES) {
    return { notify: true, armed: false };
  }
  if (!armed && freeBytes >= LOW_SPACE_REARM_BYTES) {
    return { notify: false, armed: true };
  }
  return { notify: false, armed };
}
