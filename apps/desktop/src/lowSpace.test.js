import { describe, it, expect } from "vitest";
import {
  LOW_SPACE_THRESHOLD_BYTES,
  LOW_SPACE_REARM_BYTES,
  nextLowSpace,
} from "./lowSpace.js";

const GIB = 1024 ** 3;

describe("#413 §7 照片库低空间系统通知的判定", () => {
  it("阈值固定 5 GiB，与手机 DesktopHealth.lowSpace 一致", () => {
    expect(LOW_SPACE_THRESHOLD_BYTES).toBe(5 * GIB);
    expect(LOW_SPACE_REARM_BYTES).toBeGreaterThan(LOW_SPACE_THRESHOLD_BYTES);
  });

  it("首次跌破 5 GiB 发一次", () => {
    expect(nextLowSpace(true, 4 * GIB)).toEqual({ notify: true, armed: false });
  });

  it("恰好 5 GiB 不算不足", () => {
    expect(nextLowSpace(true, 5 * GIB)).toEqual({ notify: false, armed: true });
  });

  it("一直低于阈值时不重复打扰（60s 轮询不能每分钟弹一次）", () => {
    let s = nextLowSpace(true, 4 * GIB);
    s = nextLowSpace(s.armed, 3 * GIB);
    expect(s).toEqual({ notify: false, armed: false });
  });

  it("在阈值附近抖动不重复通知，回升到重新布防线以上才会再报", () => {
    let s = nextLowSpace(true, 4.9 * GIB);
    s = nextLowSpace(s.armed, 5.2 * GIB);
    expect(s).toEqual({ notify: false, armed: false });
    s = nextLowSpace(s.armed, 4.9 * GIB);
    expect(s.notify).toBe(false);
    s = nextLowSpace(s.armed, LOW_SPACE_REARM_BYTES);
    expect(s).toEqual({ notify: false, armed: true });
    s = nextLowSpace(s.armed, 4 * GIB);
    expect(s.notify).toBe(true);
  });

  it("剩余空间未知（null/非数字）既不通知也不改状态", () => {
    for (const unknown of [null, undefined, NaN, -1, "4"]) {
      expect(nextLowSpace(true, unknown)).toEqual({ notify: false, armed: true });
      expect(nextLowSpace(false, unknown)).toEqual({ notify: false, armed: false });
    }
  });
});

// 接线：规则再对，没接上也等于没有。反证：删掉 refresh 里的 checkLowSpace
// 调用、或壳里没注册 notify_system，下面会挂。
import { readFileSync } from "node:fs";
const lf = (s) => s.replace(/\r\n/g, "\n");
const app = lf(readFileSync(new URL("./App.svelte", import.meta.url), "utf8"));
const shell = lf(readFileSync(new URL("../src-tauri/src/lib.rs", import.meta.url), "utf8"));

describe("#413 §7 低空间通知接线", () => {
  it("每次 status 刷新都用 disk_free_bytes 过一遍判定", () => {
    expect(app).toMatch(
      /status = await call\("status"\);\s*\n\s*online = true;\s*\n\s*checkLowSpace\(status\.disk_free_bytes \?\? null\);/,
    );
  });

  it("通知走壳的 notify_system，文案走 i18n 字典", () => {
    expect(app).toContain('invoke("notify_system", {');
    expect(app).toContain('t("ui.low_space_title")');
    expect(app).toContain('t("ui.low_space_body", { free: formatBytes(freeBytes) })');
    expect(shell).toMatch(/fn notify_system\(title: String, body: String\)/);
    expect(shell).toMatch(/generate_handler!\[[\s\S]*notify_system[\s\S]*\]/);
  });
});
