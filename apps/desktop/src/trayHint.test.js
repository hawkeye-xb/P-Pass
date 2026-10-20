import { describe, it, expect } from "vitest";
import { shouldShowTrayHint, TRAY_HINT_SHOWN_KEY } from "./trayHint.js";

// #1043：要不要提示由 Rust 侧平台适配器回答（platform_ux 的 close_to_tray_hint；
// macOS 为 false、Windows / Linux 为 true，判据的平台单测在 crates/platform）。
const HINTS = { close_to_tray_hint: true };
const NO_HINT = { close_to_tray_hint: false };

describe("DESK-23 关窗提示的判定规则", () => {
  it("要提示的平台上第一次关窗要提示", () => {
    expect(shouldShowTrayHint(HINTS, null)).toBe(true);
  });

  it("提示过就不再打扰", () => {
    expect(shouldShowTrayHint(HINTS, "1")).toBe(false);
  });

  // 卡面验收标准 3：macOS（适配器给 false）永远不提示。
  it("不提示的平台上永远不提示", () => {
    expect(shouldShowTrayHint(NO_HINT, null)).toBe(false);
    expect(shouldShowTrayHint(NO_HINT, "1")).toBe(false);
  });

  // 能力缺失是代码缺口，必须报错，不许悄悄当成某个平台。
  it("能力缺失直接报错", () => {
    expect(() => shouldShowTrayHint(undefined, null)).toThrow(/unsupported platform/);
    expect(() => shouldShowTrayHint({}, null)).toThrow(/unsupported platform/);
  });

  // localStorage 被禁/隐私模式下读取会抛，调用方吞掉异常后传 null
  // ——那种情况按「没提示过」走：多提示一次可以忍，静默不行。
  it("标记读不到时按没提示过处理", () => {
    expect(shouldShowTrayHint(HINTS, null)).toBe(true);
    expect(shouldShowTrayHint(HINTS, "")).toBe(true);
  });

  it("键名固定，改了会让所有老用户被重新提示一次", () => {
    expect(TRAY_HINT_SHOWN_KEY).toBe("ppf.trayHintShown");
  });
});
