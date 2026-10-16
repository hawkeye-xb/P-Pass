import { describe, expect, it } from "vitest";
import { closeToTrayHint, usesOverlayTitlebar, wizardVariant } from "./platformUx.js";

describe("DESK-69 (#997) 平台界面决定：每个平台显式一支，未覆盖就报错", () => {
  it("向导：macOS / Windows 各用各的，Linux 还没有桌面向导", () => {
    expect(wizardVariant("macos")).toBe("macos");
    expect(wizardVariant("windows")).toBe("windows");
    expect(() => wizardVariant("linux")).toThrow(/unsupported platform/);
  });

  it("关窗托盘提示：macOS 不提示，Windows / Linux 提示", () => {
    expect(closeToTrayHint("macos")).toBe(false);
    expect(closeToTrayHint("windows")).toBe(true);
    expect(closeToTrayHint("linux")).toBe(true);
  });

  it("透明 Overlay 标题栏只在 macOS", () => {
    expect(usesOverlayTitlebar("macos")).toBe(true);
    expect(usesOverlayTitlebar("windows")).toBe(false);
    expect(usesOverlayTitlebar("linux")).toBe(false);
  });

  it("未知平台不许落到任何默认值上", () => {
    for (const p of [undefined, null, "", "ios", "android", "freebsd"]) {
      expect(() => wizardVariant(p)).toThrow(/unsupported platform/);
      expect(() => closeToTrayHint(p)).toThrow(/unsupported platform/);
      expect(() => usesOverlayTitlebar(p)).toThrow(/unsupported platform/);
    }
  });
});
