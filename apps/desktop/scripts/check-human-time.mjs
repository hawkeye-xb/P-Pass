// T-091 验收脚本：node 直跑 humanTime / needsAttention 边界断言。
// 用法：node apps/desktop/scripts/check-human-time.mjs
import { humanTime, needsAttention, daysSince, relativeTime, BACKUP_ATTENTION_DAYS } from "../src/lib/humanTime.js";

const DAY = 86_400_000;
// 固定「现在」= 本地 2026-08-06(周四) 15:00:00，避免跑的时刻影响结果
const NOW = new Date(2026, 7, 6, 15, 0, 0).getTime();

let failed = 0;
function eq(label, actual, expected) {
  const ok = actual === expected;
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}: got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
}

// ---- humanTime 边界（≥6 用例：now/今天/昨天/6天前/7天前/去年/0与负值） ----
eq("now(0s ago) -> 刚刚", humanTime(NOW, NOW), "刚刚");
eq("59s ago -> 刚刚", humanTime(NOW - 59_000, NOW), "刚刚");
eq("61s ago -> 今天 14:58", humanTime(NOW - 61_000, NOW), "今天 14:58");
eq("今天 08:05 -> 今天 08:05", humanTime(new Date(2026, 7, 6, 8, 5).getTime(), NOW), "今天 08:05");
eq("昨天 22:40 -> 昨天 22:40", humanTime(new Date(2026, 7, 5, 22, 40).getTime(), NOW), "昨天 22:40");
// 6 天前 = 2026-07-31(周五) -> 周X HH:MM（仍在 7 天窗口内）
eq("6天前 周五 09:30 -> 周五 09:30", humanTime(new Date(2026, 6, 31, 9, 30).getTime(), NOW), "周五 09:30");
// 7 天前 = 2026-07-30 -> 出 7 天窗口，同年 -> MM-DD
eq("7天前 -> 07-30", humanTime(new Date(2026, 6, 30, 9, 30).getTime(), NOW), "07-30");
// 去年 -> 跨年 YYYY-MM-DD
eq("去年 -> 2025-12-31", humanTime(new Date(2025, 11, 31, 9, 30).getTime(), NOW), "2025-12-31");
eq("0 -> null（不渲染 epoch）", humanTime(0, NOW), null);
eq("负值 -> null", humanTime(-5, NOW), null);
eq("undefined -> null", humanTime(undefined, NOW), null);

// ---- 哨兵判定（>5 天亮红，纯函数） ----
const T = BACKUP_ATTENTION_DAYS; // = 5，反证时把下面断言的阈值改成 0 再跑
eq("阈值常量 = 5 天", T, 5);
eq(`刚备份 -> 不亮红`, needsAttention(NOW - 60_000, NOW, T), false);
eq(`3 天前 -> 不亮红`, needsAttention(NOW - 3 * DAY, NOW, T), false);
eq(`恰好 5 天 -> 不亮红（严格大于）`, needsAttention(NOW - 5 * DAY, NOW, T), false);
eq(`5 天 + 1ms -> 亮红`, needsAttention(NOW - 5 * DAY - 1, NOW, T), true);
eq(`6 天前 -> 亮红`, needsAttention(NOW - 6 * DAY, NOW, T), true);
eq(`从未备份(0) -> 不算哨兵态`, needsAttention(0, NOW, T), false);
eq(`从未备份(undefined) -> 不算哨兵态`, needsAttention(undefined, NOW, T), false);

// ---- daysSince（哨兵行文案「N 天没备份了」用） ----
eq("6 天前 -> 6", daysSince(NOW - 6 * DAY, NOW), 6);
eq("刚刚 -> 0", daysSince(NOW - 1000, NOW), 0);
eq("0 -> null", daysSince(0, NOW), null);

// ---- PRES-01 relativeTime（「x 分钟前在线」数据源） ----
eq("59s -> 刚刚", relativeTime(NOW - 59_000, NOW), "刚刚");
eq("61s -> 1 分钟前（向下取整最小 1）", relativeTime(NOW - 61_000, NOW), "1 分钟前");
eq("3 分钟前 -> 3 分钟前", relativeTime(NOW - 3 * 60_000, NOW), "3 分钟前");
eq("59 分钟 -> 59 分钟前", relativeTime(NOW - 59 * 60_000, NOW), "59 分钟前");
eq("61 分钟 -> 1 小时前", relativeTime(NOW - 61 * 60_000, NOW), "1 小时前");
eq("23 小时 -> 23 小时前", relativeTime(NOW - 23 * 3600_000, NOW), "23 小时前");
eq("25 小时 -> 1 天前", relativeTime(NOW - 25 * 3600_000, NOW), "1 天前");
eq("5 天 -> 5 天前", relativeTime(NOW - 5 * DAY, NOW), "5 天前");
eq("30 天 -> null（退回日历格式）", relativeTime(NOW - 30 * DAY, NOW), null);
eq("0 -> null", relativeTime(0, NOW), null);
eq("undefined -> null", relativeTime(undefined, NOW), null);

if (failed > 0) {
  console.error(`\n${failed} assertion(s) FAILED`);
  process.exit(1);
}
console.log("\nall assertions passed");
