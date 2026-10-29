// @vitest-environment jsdom
//
// #1167：Windows 向导第 3 步「会申请什么」必须和真实的常驻形态一致。per-machine 安装
// 注册的是 Windows 系统服务；以前这一行固定写「任务计划程序……不会创建 Windows 服务」，
// 装了服务版的用户看到的是一句反话（真机 UIA 读出）。
//
// 反证：把 WizardWindows.svelte 里的 key 固定回 "ui.wizard_asks_win"，「服务形态」那组红。
import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, describe, expect, it, vi } from "vitest";
import WizardWindows from "./WizardWindows.svelte";
import { setLocale } from "./lib/i18n.js";

setLocale("zh");

let hosting = null;
vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async (cmd) => {
    if (cmd === "resident_hosting") {
      if (hosting === "fail") throw new Error("worker thread");
      return hosting;
    }
    return null;
  }),
}));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

async function step3Text(mode) {
  hosting = mode;
  render(WizardWindows, {
    props: { defaultDir: "C:\\Users\\someone\\Pictures\\P-Pass Library", configuredLibraryDir: null, onDone: vi.fn() },
  });
  await fireEvent.click(screen.getByRole("button", { name: "继续" }));
  await fireEvent.click(await screen.findByRole("button", { name: "继续" }));
  await vi.waitFor(() => screen.getByText("设为后台服务"));
  await new Promise((r) => setTimeout(r, 0));
  return document.body.textContent;
}

afterEach(() => cleanup());

describe("#1167 Windows 向导第 3 步按常驻形态说", () => {
  it("服务形态：说系统服务，不再说「不会创建 Windows 服务」", async () => {
    const text = await step3Text("windows_service");
    expect(text).toContain("Windows 系统服务");
    expect(text).not.toContain("不会创建 Windows 服务");
    expect(text).not.toContain("任务计划程序");
  });

  it("计划任务形态：仍是登录任务那一句", async () => {
    const text = await step3Text("scheduled_task");
    expect(text).toContain("任务计划程序");
    expect(text).not.toContain("Windows 系统服务");
  });

  it("形态读不到：不显示「会申请什么」，宁可不说也不说错", async () => {
    const text = await step3Text("fail");
    expect(text).not.toContain("会申请什么");
    // B1：「如果被拦」行已删（拦截说明在官网下载页）。
    expect(text).not.toContain("如果被拦");
  });
});
