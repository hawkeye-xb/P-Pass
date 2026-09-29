// @vitest-environment jsdom
//
// #481：向导第 3 步必须如实告知点「完成」后 macOS 会出现什么——
// 开机自启只是通知；本地网络是要用户点「允许」的系统弹窗，系统显示的
// 名字是 ppf-daemon（0.6.1-test.1 实测），界面会先进首页；拒绝后给出
// 系统设置里的恢复路径。
//
// 反证：把第 3 步表格还原成只有「会申请什么：开机自启…」一行，
// 本文件除「不会做什么/如果被拦」外的断言全部变红。
//
// I18N-03 (#492)：文案搬进 assets/i18n 后，源码里已经没有这些中文，改成
// **挂载向导走到第 3 步、读渲染出来的文本**（zh 语言），断言一字未动。
import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterAll, beforeAll, describe, it, expect, vi } from "vitest";
import Wizard from "./Wizard.svelte";
import { setLocale } from "./lib/i18n.js";

setLocale("zh");

vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async (cmd) => (cmd === "power_hint" ? { kind: "never" } : null)),
}));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

let step3 = "";
let hasFinish = false;
beforeAll(async () => {
  render(Wizard, {
    props: { defaultDir: "/Users/someone/Pictures/P-Pass", configuredLibraryDir: null, onDone: vi.fn() },
  });
  await fireEvent.click(screen.getByRole("button", { name: "继续" }));
  await vi.waitFor(() => screen.getByText("让这台电脑保持醒着。"));
  await fireEvent.click(screen.getByRole("button", { name: "继续" }));
  await vi.waitFor(() => screen.getByText("最后一步：设为常驻服务。"));
  step3 = document.body.textContent;
  hasFinish = Boolean(screen.queryByRole("button", { name: "完成" }));
});
afterAll(() => cleanup());

describe("#481 向导第 3 步：如实告知本地网络弹窗", () => {
  it("确实渲染到了第 3 步（「完成」按钮在）", () => {
    expect(hasFinish).toBe(true);
  });

  it("明确说出本地网络弹窗、要点「允许」", () => {
    expect(step3).toContain("本地网络");
    expect(step3).toContain("请点「允许」");
  });

  it("写出用户实际看到的名字 ppf-daemon，并说明它就是 P-Pass 的后台服务", () => {
    expect(step3).toContain("允许“ppf-daemon”查找本地网络中的设备？");
    expect(step3).toContain("ppf-daemon 就是 P-Pass 的后台服务");
  });

  it("说明界面会先进首页、弹窗照样要点（#481 的困惑点）", () => {
    expect(step3).toContain("界面会先进入首页");
  });

  it("说明拒绝的后果与恢复入口", () => {
    expect(step3).toContain("没法直连");
    expect(step3).toContain("「系统设置 → 隐私与安全性 → 本地网络」把 ppf-daemon 打开");
  });

  it("开机自启标成只是通知，不再用「会申请什么」笼统一行", () => {
    expect(step3).not.toContain("会申请什么");
    expect(step3).toContain("只是通知");
    expect(step3).toContain("「后台项目已添加」");
  });

  it("其它两行保留", () => {
    expect(step3).toContain("不会做什么");
    expect(step3).toContain("如果被拦");
  });
});
