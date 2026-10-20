// @vitest-environment jsdom
//
// #1045：两份向导视图共用的状态机（lib/wizardFlow.js）。视图级行为（红条文案、
// 三步走完）由 wizardStartupFailure / i18nEnglish / wizardStep3Copy 挂真组件覆盖；
// 这里直接测状态机本身：步骤流转、config 写入失败不前进、钩子失败同样不前进、
// 就绪轮询与 onDone。
//
// 反证：把 toStep2 里 `await afterLibrarySaved()` 挪到 catch 外面，「钩子抛错
// 不得前进」必须红；把 finishSetup 的 onDone() 提到轮询前，「没就绪不 onDone」必须红。
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createWizardFlow, stepBar, WIZARD_STEP_COUNT } from "./wizardFlow.js";
import { setLocale } from "./i18n.js";

setLocale("zh");

const { invokeMock, openMock } = vi.hoisted(() => ({ invokeMock: vi.fn(), openMock: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: invokeMock }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: openMock }));

function make(over = {}) {
  const view = { step: 1, libraryDir: "", busy: false, error: "" };
  const onDone = vi.fn();
  const flow = createWizardFlow({
    defaultDir: "/Pictures/P-Pass Library",
    configuredLibraryDir: null,
    onDone,
    onChange: (p) => Object.assign(view, p),
    ...over,
  });
  Object.assign(view, flow.snapshot());
  return { flow, view, onDone };
}

beforeEach(() => {
  vi.useFakeTimers();
  invokeMock.mockReset();
  openMock.mockReset();
});
afterEach(() => vi.useRealTimers());

describe("初始状态", () => {
  it("新装默认填默认目录；config 已指向某库则预填它（防孤儿库）", () => {
    expect(make().view.libraryDir).toBe("/Pictures/P-Pass Library");
    expect(make({ configuredLibraryDir: "/Volumes/X/Lib" }).view.libraryDir).toBe("/Volumes/X/Lib");
    expect(make().view.step).toBe(1);
  });

  it("步骤条：三步，当前 / 已完成 / 待办", () => {
    expect(WIZARD_STEP_COUNT).toBe(3);
    expect(stepBar(2).map((s) => [s.n, s.state])).toEqual([
      [1, "done"],
      [2, "current"],
      [3, "todo"],
    ]);
    expect(stepBar(1)[0].label).toBeTruthy();
  });
});

describe("选库", () => {
  it("选了文件夹就换；取消选择不变；回到默认", async () => {
    const { flow, view } = make();
    openMock.mockResolvedValueOnce("/Volumes/X/Lib");
    await flow.chooseFolder();
    expect(view.libraryDir).toBe("/Volumes/X/Lib");
    openMock.mockResolvedValueOnce(null);
    await flow.chooseFolder();
    expect(view.libraryDir).toBe("/Volumes/X/Lib");
    flow.useDefault();
    expect(view.libraryDir).toBe("/Pictures/P-Pass Library");
  });
});

describe("第 1 → 2 步", () => {
  it("write_config 成功才前进，并带着当前库目录", async () => {
    invokeMock.mockResolvedValue(null);
    const { flow, view } = make();
    await flow.toStep2();
    expect(invokeMock).toHaveBeenCalledWith("write_config", { libraryDir: "/Pictures/P-Pass Library" });
    expect(view).toMatchObject({ step: 2, busy: false, error: "" });
  });

  it("write_config 失败：留在第 1 步，红条带 keyed 错误渲染出的人话", async () => {
    invokeMock.mockRejectedValue(
      JSON.stringify({ key: "ui.err_library_nested", params: {} }),
    );
    const { flow, view } = make();
    await flow.toStep2();
    expect(view.step).toBe(1);
    expect(view.busy).toBe(false);
    expect(view.error).toContain("新位置不能与当前照片库相同或互相包含");
  });

  it("钩子在 config 写成功之后、前进之前跑；钩子抛错同样不前进", async () => {
    invokeMock.mockResolvedValue(null);
    const order = [];
    invokeMock.mockImplementation(async (cmd) => void order.push(cmd));
    const { flow, view } = make({
      afterLibrarySaved: async () => {
        order.push("hook");
      },
    });
    await flow.toStep2();
    expect(order).toEqual(["write_config", "hook"]);
    expect(view.step).toBe(2);

    const bad = make({
      afterLibrarySaved: async () => {
        throw new Error("power_hint broke");
      },
    });
    await bad.flow.toStep2();
    expect(bad.view.step).toBe(1);
    expect(bad.view.error).toContain("power_hint broke");
  });
});

describe("步骤流转", () => {
  it("toStep3 / back 在 1..3 之间走，不越界", () => {
    const { flow, view } = make();
    flow.back();
    expect(view.step).toBe(1);
    flow.toStep3();
    expect(view.step).toBe(3);
    flow.back();
    expect(view.step).toBe(2);
  });
});

describe("第 3 步 finishSetup", () => {
  it("服务就绪 → onDone；轮询第一次答上 status 就停", async () => {
    let statusCalls = 0;
    invokeMock.mockImplementation(async (cmd) => {
      if (cmd === "start_daemon") return "resident";
      if (cmd === "daemon_call") {
        statusCalls++;
        if (statusCalls < 3) throw new Error("not yet");
        return {};
      }
      throw new Error(`未预期：${cmd}`);
    });
    const { flow, view, onDone } = make();
    const p = flow.finishSetup();
    await vi.advanceTimersByTimeAsync(5_000);
    await p;
    expect(statusCalls).toBe(3);
    expect(onDone).toHaveBeenCalledTimes(1);
    expect(view).toMatchObject({ busy: false, error: "" });
  });

  it("start_daemon 失败：不 onDone，红条带原因", async () => {
    invokeMock.mockRejectedValue(new Error("register failed"));
    const { flow, view, onDone } = make();
    await flow.finishSetup();
    expect(onDone).not.toHaveBeenCalled();
    expect(view.error).toContain("register failed");
    expect(view.busy).toBe(false);
  });

  it("10 秒都没就绪：不 onDone，红条带 daemon 的 stderr 原文", async () => {
    invokeMock.mockImplementation(async (cmd) => {
      if (cmd === "start_daemon") return "resident";
      if (cmd === "daemon_call") throw new Error("no daemon");
      if (cmd === "daemon_startup_error") return "Error: address already in use";
      throw new Error(`未预期：${cmd}`);
    });
    const { flow, view, onDone } = make();
    const p = flow.finishSetup();
    await vi.advanceTimersByTimeAsync(10_000);
    await p;
    expect(onDone).not.toHaveBeenCalled();
    expect(view.error).toContain("Error: address already in use");
    expect(invokeMock.mock.calls.filter(([c]) => c === "daemon_call")).toHaveLength(20);
  });
});
