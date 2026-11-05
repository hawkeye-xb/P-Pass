// @vitest-environment jsdom
//
// #1414：后台服务在跑、但还没有照片库位置（daemon 的「未配置」状态）时向导照常显示，
// 第 1 步不另加提示文案（产品定案：向导本身就是首启流程，提示对这一屏没有新增信息）。
// 两份向导（macOS / Windows）同一口径。
//
// 反证：把 `{#if unconfigured}` 提示块加回向导（任一份），对应「不出现提示」断言变红。
import { cleanup, render, screen } from "@testing-library/svelte";
import { afterEach, describe, it, expect, vi } from "vitest";
import Wizard from "./Wizard.svelte";
import WizardWindows from "./WizardWindows.svelte";
import { setLocale } from "./lib/i18n.js";
import zh from "./i18n/zh.json";
import en from "./i18n/en.json";

setLocale("zh");

vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async (cmd) => (cmd === "power_hint" ? { kind: "never" } : null)),
}));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

afterEach(() => cleanup());

const base = { defaultDir: "/Users/someone/Pictures/P-Pass Library", configuredLibraryDir: null, onDone: vi.fn() };

describe.each([
  ["Wizard", Wizard],
  ["WizardWindows", WizardWindows],
])("%s：未配置状态", (_name, Component) => {
  it("第 1 步照常显示，不出现额外提示", () => {
    render(Component, { props: { ...base, unconfigured: true } });
    expect(screen.getByText("选择照片库位置")).toBeTruthy();
    expect(screen.queryByTestId("wizard-unconfigured")).toBeNull();
  });
});

describe("提示文案键已删除", () => {
  it("zh / en 字典里都没有 ui.wizard_unconfigured_notice", () => {
    expect(zh["ui.wizard_unconfigured_notice"]).toBeUndefined();
    expect(en["ui.wizard_unconfigured_notice"]).toBeUndefined();
  });
});
