// @vitest-environment jsdom
//
// DESK-09 的护栏：**挂载向导、走完三步、让 daemon 起不来，然后读渲染出来的那条红条**。
//
// 在这之前（QA-16 / #326）本仓没有组件渲染能力，这条链路的"护栏"是一段
// `readFileSync` 源码 grep——字符串还在、行为已断，测试照样绿（#326 的 M3 变异）。
//
// B13 起红条的规矩：正文 + 错误代码，daemon 的 stderr 原文只进 console。断言盯红条里
// 真正出现的字：
//   1. daemon 认出原因时，说那条原因的人话，错误代码是那条 key；
//   2. stderr 原文**不**出现在界面上；
//   3. 兜底文案**没有**赢——读 stderr 那一步（`startupFailureKey(stderr) ||`）被摘掉时
//      正是它顶上来，这条才是真正把 M3 钉死的判据。
//
// 反证（复现 #326 M3）：删掉 `lib/wizardFlow.js` finishSetup 里的
// `startupFailureKey(stderr) ||`，本文件必须红。
import { cleanup, render, screen, fireEvent } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Wizard from "./Wizard.svelte";
import WizardWindows from "./WizardWindows.svelte";
import { setLocale } from "./lib/i18n.js";
import { daemonMethodOf } from "./lib/daemonApi.js";

// I18N-03 (#492)：文案搬进字典后按系统语言取词；这里断言的是中文原文——
// 只搬字不改措辞，zh 下渲染结果必须和搬迁前逐字相同。
setLocale("zh");

// 那次真实事故的 stderr（装回旧版本 → 库的 migration 比二进制新）。#1044 起
// daemon 自己认出原因、给 keyed 错误，壳拆成 { key, detail } 交给向导。
const DAEMON_STDERR =
  "migration: migration 2 was previously applied but is missing in the resolved migrations";
const STARTUP_ERROR = { key: "ui.startup_migration_guidance", detail: DAEMON_STDERR };
// daemon 认出 migration mismatch 时红条说的人话与错误代码。
const HUMAN = "P-Pass 版本太旧，无法打开现有照片库。请安装最新版本。";
const HUMAN_CODE = "错误代码：startup_migration_guidance";
// 只在 daemon 没认出原因时才该出现的兜底——它赢了就说明读原因那条路断了。
const FALLBACK = "备份没能启动。请再试一次。";
const FALLBACK_CODE = "错误代码：wizard_daemon_not_started";

const { invokeMock } = vi.hoisted(() => ({ invokeMock: vi.fn() }));

vi.mock("@tauri-apps/api/core", () => ({ invoke: invokeMock }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

/**
 * 一个「daemon 永远起不来」的桌面：start_daemon 说自己成功了，但之后每次
 * status 探活都失败——正是 launchd 把 daemon 拉起来又立刻崩掉的形状。
 */
function daemonNeverBecomesReady({ startupError }) {
  invokeMock.mockImplementation(async (cmd) => {
    switch (daemonMethodOf(cmd) ? "daemon" : cmd) {
      case "write_config":
        return null;
      case "power_hint":
        return { kind: "never" };
      case "start_daemon":
        return "resident";
      case "daemon":
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

  it("红条说 daemon 认出的原因并附错误代码，stderr 原文不进界面，兜底文案不许顶替", async () => {
    daemonNeverBecomesReady({ startupError: STARTUP_ERROR });

    const text = await runToStartupFailure(Component);

    // 已知故障要有人听得懂的解释，附上能对照日志的错误代码。
    expect(text).toContain(HUMAN);
    expect(text).toContain(HUMAN_CODE);
    // B13：原文只进 console。
    expect(text).not.toContain(DAEMON_STDERR);
    // M3 的判据：`startupFailureKey(stderr) ||` 被摘掉时，顶上来的就是它。
    expect(text).not.toContain(FALLBACK);
    // DESK-09 卡面原文：不许退化成"没有在 10 秒内就绪"这种什么都没说的话。
    expect(text).not.toContain("没有在 10 秒内就绪");
  });

  it("daemon 没认出原因时才轮到兜底文案（不许编一个错误原因）", async () => {
    // plist 不在 / 日志读不到 → 包装层如实返回 null。
    daemonNeverBecomesReady({ startupError: null });

    const text = await runToStartupFailure(Component);

    expect(text).toContain(FALLBACK);
    expect(text).toContain(FALLBACK_CODE);
    // 读不到就说读不到，不许把上一种情况的人话套上来。
    expect(text).not.toContain(HUMAN);
  });
});
