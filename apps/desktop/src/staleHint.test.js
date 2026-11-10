// #1577（#1402 卡2）：15 天「很久没联系」边界。判据：last_seen 距今
// 严格超过 15 天才提示；正好 15 天、更近、缺失/0/负值都不提示。
//
// 反证：`>` 改 `>=`，第二条（正好 15 天）变红；去掉 lastSeen<=0 的过滤，
// 缺失/0 的「幽灵」也提示，第四条变红。
import { test, expect } from "vitest";
import { staleHint } from "./lib/staleHint.js";

const DAY = 24 * 3600 * 1000;
const NOW = 1_800_000_000_000;

test("last_seen 距今严格超过 15 天才提示", () => {
  expect(staleHint(NOW - 15 * DAY - 1, NOW)).toBe(true);
  expect(staleHint(NOW - 16 * DAY, NOW)).toBe(true);
});

test("正好 15 天不算", () => {
  expect(staleHint(NOW - 15 * DAY, NOW)).toBe(false);
});

test("更近（< 15 天）不算", () => {
  expect(staleHint(NOW - 14 * DAY, NOW)).toBe(false);
  expect(staleHint(NOW - 60_000, NOW)).toBe(false);
});

test("缺失 / 0 / 负值不提示", () => {
  expect(staleHint(null, NOW)).toBe(false);
  expect(staleHint(0, NOW)).toBe(false);
  expect(staleHint(-5, NOW)).toBe(false);
});
