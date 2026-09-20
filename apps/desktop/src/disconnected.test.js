// DEV-03 的判据边界。纯函数，node --test 直跑。
import { test, expect } from "vitest";

const eq = (a, b, msg) => expect(a, msg).toBe(b);
const matches = (a, re, msg) => expect(a, msg).toMatch(re);
const notMatches = (a, re, msg) => expect(a, msg).not.toMatch(re);
import { isSelfDisconnected, isOwnerRemoved, disconnectedRow } from "./lib/disconnected.js";

const active = { revoked: false, revoked_by: null };
const selfGone = { revoked: true, revoked_by: "device", revoked_at: 1_700_000_000_000 };
const ownerGone = { revoked: true, revoked_by: "owner", revoked_at: 1_700_000_000_000 };
const legacyGone = { revoked: true, revoked_by: null };

test("在用设备两边都不算", () => {
  eq(isSelfDisconnected(active), false);
  eq(isOwnerRemoved(active), false);
});

test("手机自己断开的留在主列表", () => {
  eq(isSelfDisconnected(selfGone), true);
  eq(isOwnerRemoved(selfGone), false);
});

test("业主移除的收进折叠区", () => {
  eq(isSelfDisconnected(ownerGone), false);
  eq(isOwnerRemoved(ownerGone), true);
});

test("来源不可考的历史行按「业主移除」处理——宁可不出现，也不要凭空冒出来", () => {
  eq(isSelfDisconnected(legacyGone), false);
  eq(isOwnerRemoved(legacyGone), true);
});

test("两个判据永远互斥，且合起来覆盖所有 revoked 行", () => {
  for (const d of [active, selfGone, ownerGone, legacyGone]) {
    eq(isSelfDisconnected(d) && isOwnerRemoved(d), false, "不能同时成立");
    eq(isSelfDisconnected(d) || isOwnerRemoved(d), Boolean(d.revoked), "revoked 行必须落到其中一边");
  }
});

test("已断开的行不借用「离线」话术——那读起来像「还在备份，只是不在线」", () => {
  const row = disconnectedRow(selfGone, "今天 14:20");
  eq(row.dot, "idle");
  eq(row.sub, "已断开 · 今天 14:20");
  notMatches(row.sub, /离线/);
  matches(row.right, /重新扫码/);
});

test("不把「已断开」换个说法再讲一遍——只给状态和时刻", () => {
  notMatches(disconnectedRow(selfGone, "今天 14:20").sub, /断开了连接|这台手机/);
});

test("没有断开时刻时仍有可读文案", () => {
  eq(disconnectedRow(selfGone, null).sub, "已断开");
});

test("不是自己断开的拿不到这套文案", () => {
  eq(disconnectedRow(ownerGone, "今天"), null);
  eq(disconnectedRow(active, "今天"), null);
});
