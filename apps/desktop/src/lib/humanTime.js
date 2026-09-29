// T-091: 人性化时间 + 哨兵判定 —— 纯函数，无 DOM/Tauri 依赖。I18N-03 (#492)
// 起文案经 ./i18n.js 取自 assets/i18n（JSON import 要 Vite/vitest 解析），
// 裸 node 不再能直跑——scripts/check-human-time.mjs 因此失效，未在本卡修。
//
// 时间戳单位 = unix 毫秒。代码依据（不是猜的）：
// - device.watermarks.last_backup_at ← backup_watermark.updated_at，
//   写入点 crates/daemon/src/backup.rs:208 set_watermark(..., unix_ms_now())，
//   unix_ms_now() = SystemTime as_millis()（backup.rs:216）；
//   storage 层测试断言 1_753_770_500_000（13 位毫秒，device_repo.rs:299）。
// - devices.list.last_seen ← 配对时 pairing.rs:168 last_seen: Some(now_ms)，
//   now_ms 由 ipc.rs:696 now_ms() = as_millis() 传入。

import { t } from "./i18n.js";

const DAY_MS = 86_400_000;
const WEEKDAY = [
  "ui.weekday_sun",
  "ui.weekday_mon",
  "ui.weekday_tue",
  "ui.weekday_wed",
  "ui.weekday_thu",
  "ui.weekday_fri",
  "ui.weekday_sat",
];

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
  if (nowMs - tsMs < 60_000) return t("ui.time_just_now"); // 含轻微时钟偏差（未来值）
  const d = new Date(tsMs);
  const now = new Date(nowMs);
  const dayDiff = Math.round((dayStart(now) - dayStart(d)) / DAY_MS);
  if (dayDiff <= 0) return t("ui.time_today", { time: hm(d) });
  if (dayDiff === 1) return t("ui.time_yesterday", { time: hm(d) });
  if (dayDiff < 7) return t("ui.time_weekday", { day: t(WEEKDAY[d.getDay()]), time: hm(d) });
  if (d.getFullYear() === now.getFullYear()) return `${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** 设计稿哨兵阈值：最近备份超过 5 天 → 亮红「需要看看」。 */
export const BACKUP_ATTENTION_DAYS = 5;

/**
 * PRES-01: 相对时间（「3 分钟前在线」的数据源）。
 * <60s 刚刚 / <60min N 分钟前 / <24h N 小时前 / <30d N 天前 / 更早或
 * 缺失 → null（调用方退回 humanTime 的日历格式）。时钟偏差（未来值）
 * 视为刚刚。向下取整，最小 1（61s → 1 分钟前）。
 */
export function relativeTime(tsMs, nowMs = Date.now()) {
  if (typeof tsMs !== "number" || !Number.isFinite(tsMs) || tsMs <= 0) return null;
  const diff = nowMs - tsMs;
  if (diff < 60_000) return t("ui.time_just_now");
  const minutes = Math.max(1, Math.floor(diff / 60_000));
  if (minutes < 60) return t("ui.time_minutes_ago", { n: minutes });
  const hours = Math.max(1, Math.floor(minutes / 60));
  if (hours < 24) return t("ui.time_hours_ago", { n: hours });
  const days = Math.max(1, Math.floor(hours / 24));
  if (days < 30) return t("ui.time_days_ago", { n: days });
  return null;
}

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
