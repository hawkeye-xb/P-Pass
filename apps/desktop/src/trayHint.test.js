import { describe, it, expect } from "vitest";
import { shouldShowTrayHint, TRAY_HINT_SHOWN_KEY } from "./trayHint.js";

describe("DESK-23 关窗提示的判定规则", () => {
  it("Windows 上第一次关窗要提示", () => {
    expect(shouldShowTrayHint("windows", null)).toBe(true);
  });

  it("Windows 上提示过就不再打扰", () => {
    expect(shouldShowTrayHint("windows", "1")).toBe(false);
  });

  // 卡面验收标准 3。没有 Mac、PR CI 也不跑 macOS（#278），端到端验不了；
  // 这条覆盖的是真正会写错的那一环——判定规则本身。
  it("macOS 上永远不提示（点红灯不退出在那儿是常态）", () => {
    expect(shouldShowTrayHint("macos", null)).toBe(false);
    expect(shouldShowTrayHint("macos", "1")).toBe(false);
  });

  it("Linux 上也不提示", () => {
    expect(shouldShowTrayHint("linux", null)).toBe(false);
  });

  // fail-closed：平台读不到时宁可少说一次，也不要在 macOS 上冒出来。
  it("平台读不到时不提示", () => {
    expect(shouldShowTrayHint(undefined, null)).toBe(false);
    expect(shouldShowTrayHint(null, null)).toBe(false);
    expect(shouldShowTrayHint("", null)).toBe(false);
  });

  // localStorage 被禁/隐私模式下读取会抛，调用方吞掉异常后传 null
  // ——那种情况按「没提示过」走：多提示一次可以忍，静默不行。
  it("标记读不到时按没提示过处理", () => {
    expect(shouldShowTrayHint("windows", null)).toBe(true);
    expect(shouldShowTrayHint("windows", "")).toBe(true);
  });

  it("键名固定，改了会让所有老用户被重新提示一次", () => {
    expect(TRAY_HINT_SHOWN_KEY).toBe("ppf.trayHintShown");
  });
});
