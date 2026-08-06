// T-092: 字节 → 人读容量（设置页磁盘水位「可用 X GB / 共 Y GB」用）。
// 纯函数，无 DOM/Tauri 依赖，node 可直跑
// （apps/desktop/scripts/check-wire-fns.mjs 是对应断言脚本）。
//
// 数据来源：status.disk_free_bytes / disk_total_bytes（crates/daemon/src/
// ipc.rs status()，disk_stats 拿不到时为 null）。null/缺失/负值 → null，
// 调用方整行隐藏——绝不渲染 undefined/NaN。

const UNITS = ["B", "KB", "MB", "GB", "TB"];

/**
 * 字节数 → "N 单位" 字符串（1024 进制）。
 * <10 且非整数保留 1 位小数（1.5 GB），其余取整（182 GB / 1023 B）。
 * 非有限数字或负值 → null。
 */
export function formatBytes(bytes) {
  if (typeof bytes !== "number" || !Number.isFinite(bytes) || bytes < 0) return null;
  let v = bytes;
  let i = 0;
  while (v >= 1024 && i < UNITS.length - 1) {
    v /= 1024;
    i += 1;
  }
  const num = v < 10 && !Number.isInteger(v) ? v.toFixed(1) : String(Math.round(v));
  return `${num} ${UNITS[i]}`;
}

/**
 * 磁盘已用百分比（进度条宽度用）：(total-free)/total，0..100 取整。
 * 任一字段非有限数字、total<=0、free<0 → null（进度条跟整行一起隐藏）。
 */
export function diskUsedPercent(freeBytes, totalBytes) {
  if (typeof freeBytes !== "number" || !Number.isFinite(freeBytes) || freeBytes < 0) return null;
  if (typeof totalBytes !== "number" || !Number.isFinite(totalBytes) || totalBytes <= 0) return null;
  const pct = Math.round(((totalBytes - freeBytes) / totalBytes) * 100);
  return Math.min(100, Math.max(0, pct));
}
