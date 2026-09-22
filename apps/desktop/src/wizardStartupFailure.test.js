// @vitest-environment jsdom
//
// DESK-09 标准 1/2 的原始措辞，第一次有了能验它的东西：**挂载向导、走完
// 三步、让 daemon 起不来，然后读渲染出来的那条红条**。
//
// 在这之前（QA-16 / #326）本仓没有组件渲染能力，这条链路的"护栏"是
// `daemonStartupError.test.js` 里一段 `readFileSync` 源码 grep——它只检查
// `invoke("daemon_startup_error")` 这个字符串在不在。把 Wizard.svelte:101 的
// `startupFailureText(stderr) ||` 删掉（只留兜底文案），字符串还在、行为已
// 断，那条测试照样绿（#326 的 M3 变异，实测全绿）。
//
// 所以这里的断言必须盯**红条里真正出现的字**，三条缺一不可：
//   1. stderr 原文透出（DESK-09 标准 2：不许拿模板文案替换诊断信息）
//   2. 人话解释在（标准 1：migration mismatch 要说人听得懂的那句）
//   3. 兜底文案**没有**赢——`startupFailureText` 被摘掉时正是它顶上来，
//      这条才是真正把 M3 钉死的判据。
//
// 反证（复现 #326 M3）：删掉 `Wizard.svelte:101` / `WizardWindows.svelte:99`
// 的 `startupFailureText(stderr) ||`，本文件必须红。
import { cleanup, render, screen, fireEvent } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Wizard from "./Wizard.svelte";
import WizardWindows from "./WizardWindows.svelte";

// 那次真实事故的 stderr（装回旧版本 → 库的 migration 比二进制新）。
const DAEMON_STDERR =
  "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";
// `startupFailureText` 认出 migration mismatch 时给的人话。
const HUMAN = "这个版本比你的照片库旧。请装回新版本。";
// 只在 stderr 拿不到时才该出现的兜底——它赢了就说明 stderr 那条路断了。
const FALLBACK = "后台服务未能启动。请检查后台服务日志。";

const { invokeMock } = vi.hoisted(() => ({ invokeMock: vi.fn() }));

vi.mock("@tauri-apps/api/core", () => ({ invoke: invokeMock }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

/**
 * 一个「daemon 永远起不来」的桌面：start_daemon 说自己成功了，但之后每次
 * status 探活都失败——正是 launchd 把 daemon 拉起来又立刻崩掉的形状。
 */
function daemonNeverBecomesReady({ startupError }) {
  invokeMock.mockImplementation(async (cmd) => {
    switch (cmd) {
      case "write_config":
        return null;
      case "power_hint":
        return { kind: "never" };
      case "start_daemon":
        return "resident";
      case "daemon_call":
        throw new Error("no daemon");
      case "daemon_startup_error":
        return startupError;
      default:
        throw new Error(`未预期的 command：${cmd}`);
    }
  });
}

/** 点一个按钮，并把它引发的那串 await 放完。 */
async function click(name) {
  await fireEvent.click(screen.getByRole("button", { name }));
  await vi.advanceTimersByTimeAsync(0);
}

/**
 * 从第 1 步一路点到"完成"，把 10 秒的就绪轮询（20 × 500ms）走完，
 * 返回渲染出来的那条红条的文本。
 */
async function runToStartupFailure(Component) {
  render(Component, {
    props: {
      defaultDir: "/Users/someone/Pictures/P-Pass",
      configuredLibraryDir: null,
      onDone: vi.fn(),
    },
  });

  await click("继续"); // 第 1 步 → 第 2 步（write_config + power_hint）
  await click("继续"); // 第 2 步 → 第 3 步
  await click("完成"); // finishSetup：start_daemon + 就绪轮询
  await vi.advanceTimersByTimeAsync(10_000);

  const bar = document.querySelector("p.text-act");
  expect(bar, "启动失败后必须渲染出一条红条").not.toBeNull();
  return bar.textContent;
}

describe.each([
  ["Wizard.svelte", Wizard],
  ["WizardWindows.svelte", WizardWindows],
])("%s：daemon 起不来时向导红条说的话", (_name, Component) => {
  beforeEach(() => {
    vi.useFakeTimers();
    invokeMock.mockReset();
  });
  afterEach(() => {
    // globals 没开 ⇒ testing-library 的自动清理不会注册，必须手动卸载，
    // 否则第二个用例会在上一个向导的 DOM 上找到两个「继续」。
    cleanup();
    vi.useRealTimers();
  });

  it("红条同时显示人话与 daemon 的 stderr 原文，兜底文案不许顶替它们", async () => {
    daemonNeverBecomesReady({ startupError: DAEMON_STDERR });

    const text = await runToStartupFailure(Component);

    // 标准 2：诊断原文原样透出，一个字都不许被模板文案吃掉。
    expect(text).toContain(DAEMON_STDERR);
    // 标准 1：已知故障要有人听得懂的解释。
    expect(text).toContain(HUMAN);
    // M3 的判据：`startupFailureText(stderr) ||` 被摘掉时，顶上来的就是它。
    expect(text).not.toContain(FALLBACK);
    // DESK-09 卡面原文：不许退化成"没有在 10 秒内就绪"这种什么都没说的话。
    expect(text).not.toContain("没有在 10 秒内就绪");
  });

  it("stderr 真的读不到时才轮到兜底文案（不许编一个错误原因）", async () => {
    // plist 不在 / 日志读不到 → 包装层如实返回 null。
    daemonNeverBecomesReady({ startupError: null });

    const text = await runToStartupFailure(Component);

    expect(text).toContain(FALLBACK);
    // 读不到就说读不到，不许把上一种情况的人话套上来。
    expect(text).not.toContain(HUMAN);
  });
});
