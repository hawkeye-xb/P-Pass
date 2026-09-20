// DEV-04 的措辞边界：两套文案各自渲染正确、互不串台。
import { test, expect } from "vitest";
import {
  isKnownDevice,
  pendingDialogText,
  pendingSubText,
  pendingAllowKey,
} from "./lib/pending.js";

const fresh = { node_id: "a".repeat(64), known: false, name: "SM-S9210" };
const known = {
  node_id: "b".repeat(64),
  known: true,
  name: "三星测试及", // 桌面上改过的名字
  paired_at: 1_700_000_000_000,
  revoked: true,
  photo_count: 95,
};

test("判据是 known 这一位，不是名字", () => {
  expect(isKnownDevice(fresh)).toBe(false);
  expect(isKnownDevice(known)).toBe(true);
  // 被移除过的设备再回来，依然算「以前连过」。
  expect(isKnownDevice({ known: true, revoked: true })).toBe(true);
});

test("新设备维持原措辞", () => {
  const { title, hint } = pendingDialogText([fresh]);
  expect(title).toBe("有设备请求加入");
  expect(hint).toMatch(/会出现在设备列表里/);
  // 不许串到重连那套。
  expect(title).not.toMatch(/重新连接/);
  expect(hint).not.toMatch(/以前连过/);
});

test("老设备重连点名，且点的是桌面上的名字", () => {
  const { title, hint } = pendingDialogText([known]);
  expect(title).toBe("「三星测试及」请求重新连接");
  expect(hint).toBe("这台设备以前连过，允许后会恢复备份。");
  // 不许串到首次配对那套。
  expect(title).not.toMatch(/请求加入/);
  expect(hint).not.toMatch(/会出现在设备列表里/);
});

test("多台同时扫码只报数量，不替其中一台说话", () => {
  const { title } = pendingDialogText([known, fresh]);
  expect(title).toBe("有 2 台设备请求加入");
  expect(title).not.toMatch(/重新连接/);
  expect(title).not.toMatch(/三星测试及/);
});

test("副行：老设备摆实证，新设备什么都不说", () => {
  expect(pendingSubText(fresh, "3 天前")).toBe(null);
  expect(pendingSubText(known, "3 天前")).toBe("首次配对 3 天前 · 已存 95 张");
});

test("副行退化：缺时刻/零张也说得出一句话", () => {
  expect(pendingSubText({ known: true, photo_count: 95 })).toBe("已存 95 张");
  expect(pendingSubText({ known: true, photo_count: 0 }, "3 天前")).toBe("首次配对 3 天前");
  expect(pendingSubText({ known: true, photo_count: 0 })).toBe("以前连过这台电脑");
});

test("空列表/脏输入不炸", () => {
  expect(pendingDialogText([]).title).toBe("有设备请求加入");
  expect(pendingDialogText(null).title).toBe("有设备请求加入");
  expect(pendingSubText(null)).toBe(null);
  expect(pendingSubText(undefined)).toBe(null);
});

test("按钮文案跟着标题走，不留「允许加入」在重连屏上", () => {
  expect(pendingAllowKey(fresh)).toBe("ui.allow");
  expect(pendingAllowKey(known)).toBe("ui.allow_reconnect");
  expect(pendingAllowKey(null)).toBe("ui.allow");
});
