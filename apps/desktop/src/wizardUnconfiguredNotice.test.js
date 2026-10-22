// @vitest-environment jsdom
//
// #1115：后台服务在跑、但还没有照片库位置（daemon 的「未配置」状态）时，向导第 1 步顶部
// 要说清楚「服务在等你选库」，不能让人以为服务挂了。两份向导（macOS / Windows）同一口径。
//
// 反证：去掉向导里的 `{#if unconfigured}` 提示块，「未配置时显示」两条断言变红；
// 把条件写成恒真，「已配置时不显示」两条变红。
import { cleanup, render, screen } from "@testing-library/svelte";
import { afterEach, describe, it, expect, vi } from "vitest";
import Wizard from "./Wizard.svelte";
import WizardWindows from "./WizardWindows.svelte";
import { setLocale } from "./lib/i18n.js";

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
])("%s：未配置提示", (_name, Component) => {
  it("未配置时显示「服务在等你选库」", () => {
    render(Component, { props: { ...base, unconfigured: true } });
    const notice = screen.getByTestId("wizard-unconfigured");
    expect(notice.textContent).toContain("后台服务已在运行");
  });

  it("已配置（普通首启）时不显示", () => {
    render(Component, { props: base });
    expect(screen.queryByTestId("wizard-unconfigured")).toBeNull();
  });
});
