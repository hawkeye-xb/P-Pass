// T-091: 人性化时间 + 哨兵判定 —— 纯函数，无 DOM/Tauri 依赖，node 可直跑
// （apps/desktop/scripts/check-human-time.mjs 是对应断言脚本）。
//
// 时间戳单位 = unix 毫秒。代码依据（不是猜的）：
// - device.watermarks.last_backup_at ← backup_watermark.updated_at，
//   写入点 crates/daemon/src/backup.rs:208 set_watermark(..., unix_ms_now())，
//   unix_ms_now() = SystemTime as_millis()（backup.rs:216）；
//   storage 层测试断言 1_753_770_500_000（13 位毫秒，device_repo.rs:299）。
// - devices.list.last_seen ← 配对时 pairing.rs:168 last_seen: Some(now_ms)，
//   now_ms 由 ipc.rs:696 now_ms() = as_millis() 传入。

const DAY_MS = 86_400_000;
const WEEKDAY = ["日", "一", "二", "三", "四", "五", "六"];

const pad = (n) => String(n).padStart(2, "0");
const hm = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;
// 按本地日历日对齐（「昨天」是日历意义上的昨天，不是 24 小时前）
const dayStart = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();

/**
 * unix 毫秒 → 人性化时间。
 * 刚刚(<60s) / 今天 HH:MM / 昨天 HH:MM / 周X HH:MM(<7天) / MM-DD / 跨年 YYYY-MM-DD。
 * 缺失、0、负值 → null（调用方自己决定「还没备份过」之类的文案），
 * 绝不把 epoch 渲染成 1970-01-01。
 */
export function humanTime(tsMs, nowMs = Date.now()) {
  if (typeof tsMs !== "number" || !Number.isFinite(tsMs) || tsMs <= 0) return null;
  if (nowMs - tsMs < 60_000) return "刚刚"; // 含轻微时钟偏差（未来值）
  const d = new Date(tsMs);
  const now = new Date(nowMs);
  const dayDiff = Math.round((dayStart(now) - dayStart(d)) / DAY_MS);
  if (dayDiff <= 0) return `今天 ${hm(d)}`;
  if (dayDiff === 1) return `昨天 ${hm(d)}`;
  if (dayDiff < 7) return `周${WEEKDAY[d.getDay()]} ${hm(d)}`;
  if (d.getFullYear() === now.getFullYear()) return `${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** 设计稿哨兵阈值：最近备份超过 5 天 → 亮红「需要看看」。 */
export const BACKUP_ATTENTION_DAYS = 5;

/**
 * 哨兵判定（纯函数）：最近备份距今 > thresholdDays 天 → true。
 * 从未备份（缺失/0/负值）不算哨兵态——那是「还没备份过」，另有文案。
 */
export function needsAttention(lastBackupAtMs, nowMs = Date.now(), thresholdDays = BACKUP_ATTENTION_DAYS) {
  if (typeof lastBackupAtMs !== "number" || !Number.isFinite(lastBackupAtMs) || lastBackupAtMs <= 0) {
    return false;
  }
  return nowMs - lastBackupAtMs > thresholdDays * DAY_MS;
}

/** 距今整天数（向下取整，最小 0）；缺失/0/负值 → null。哨兵行文案用。 */
export function daysSince(tsMs, nowMs = Date.now()) {
  if (typeof tsMs !== "number" || !Number.isFinite(tsMs) || tsMs <= 0) return null;
  return Math.max(0, Math.floor((nowMs - tsMs) / DAY_MS));
}
