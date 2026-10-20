import { describe, expect, it } from "vitest";
import { closeToTrayHint, usesOverlayTitlebar, wizardVariant } from "./platformUx.js";

// #1043：界面决定只读 Rust 侧平台适配器给的能力（platform_ux），不认平台名。
const MAC_LIKE = { close_to_tray_hint: false, overlay_titlebar: true, sleep_owner: "user" };
const WIN_LIKE = { close_to_tray_hint: true, overlay_titlebar: false, sleep_owner: "daemon" };
const NO_WIZARD = { close_to_tray_hint: true, overlay_titlebar: false, sleep_owner: null };

describe("#1043 平台界面决定：只读适配器能力，缺字段就报错", () => {
  it("向导按「睡眠由谁负责」选视图；没有桌面向导的平台报错", () => {
    expect(wizardVariant(MAC_LIKE)).toBe("user-sleep");
    expect(wizardVariant(WIN_LIKE)).toBe("daemon-sleep");
    expect(() => wizardVariant(NO_WIZARD)).toThrow(/unsupported platform/);
  });

  it("关窗托盘提示原样取能力", () => {
    expect(closeToTrayHint(MAC_LIKE)).toBe(false);
    expect(closeToTrayHint(WIN_LIKE)).toBe(true);
  });

  it("Overlay 标题栏原样取能力", () => {
    expect(usesOverlayTitlebar(MAC_LIKE)).toBe(true);
    expect(usesOverlayTitlebar(WIN_LIKE)).toBe(false);
  });

  it("能力缺失或取值不认识，不许落到任何默认值上", () => {
    for (const ux of [undefined, null, {}, { sleep_owner: "someone" }, { close_to_tray_hint: "yes", overlay_titlebar: 1 }]) {
      expect(() => wizardVariant(ux)).toThrow(/unsupported platform/);
      expect(() => closeToTrayHint(ux)).toThrow(/unsupported platform/);
      expect(() => usesOverlayTitlebar(ux)).toThrow(/unsupported platform/);
    }
  });

  // 平台名不再是输入：传进来的字符串一律当成「缺能力」。
  it("不再接受平台名", () => {
    for (const p of ["macos", "windows", "linux"]) {
      expect(() => closeToTrayHint(p)).toThrow(/unsupported platform/);
    }
  });
});
