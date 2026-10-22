// DEV-03「已断开」行的文案。哪一行算已断开/已移除由 daemon 判定
// （crates/daemon/src/device_projection.rs，#1044），判据测试在那边。
import { test, expect } from "vitest";

const eq = (a, b, msg) => expect(a, msg).toBe(b);
const matches = (a, re, msg) => expect(a, msg).toMatch(re);
const notMatches = (a, re, msg) => expect(a, msg).not.toMatch(re);
import { disconnectedRow } from "./lib/disconnected.js";
import { setLocale } from "./lib/i18n.js";

// I18N-03 (#492)：文案搬进字典后按系统语言取词；这里断言的是中文原文——
// 只搬字不改措辞，zh 下渲染结果必须和搬迁前逐字相同。
setLocale("zh");

test("已断开的行不借用「离线」话术——那读起来像「还在备份，只是不在线」", () => {
  const row = disconnectedRow("今天 14:20");
  eq(row.dot, "idle");
  eq(row.sub, "已断开 · 今天 14:20");
  notMatches(row.sub, /离线/);
  matches(row.right, /重新扫码/);
});

test("不把「已断开」换个说法再讲一遍——只给状态和时刻", () => {
  notMatches(disconnectedRow("今天 14:20").sub, /断开了连接|这台手机/);
});

test("没有断开时刻时仍有可读文案", () => {
  eq(disconnectedRow(null).sub, "已断开");
});

// #1117 / #1109 D2：电脑换了身份的设备同样留在「已断开」，提示语说明为什么要
// 重新扫码。反证：disconnectedRow 不看 departedBy，这条变红。
test("电脑换了身份时提示语说明原因", () => {
  eq(disconnectedRow("今天 14:20", "identity").right, "电脑换了身份，需要重新扫码");
  eq(disconnectedRow("今天 14:20", "device").right, "重新扫码即可恢复");
  eq(disconnectedRow(null, "identity").sub, "已断开");
});
