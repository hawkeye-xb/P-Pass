// @vitest-environment jsdom
//
// I18N-03 (#492)：系统语言是英文时，向导三步 + Rust 壳回来的错误都不能
// 露出中文。真机截图（E3）之外能在 CI 里钉住的那一半：挂载真组件、走完
// 每一步，读渲染出来的整页文本。
//
// 反证：把 Wizard.svelte 任一处 t(...) 换回中文字面量，或让 errText 不认
// keyed 错误（直接 String(e)），这里必须红。
import { cleanup, render, screen, fireEvent } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Wizard from "./Wizard.svelte";
import WizardWindows from "./WizardWindows.svelte";
import { errText, setLocale, t } from "./lib/i18n.js";

setLocale("en");

const HAN = new RegExp("[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]");

// Rust 壳的线上格式（ipc::ui_err）：壳错误包着一条 IPC 错误，底层细节原样透传。
const NESTED_START_ERR = JSON.stringify({
  key: "ui.err_register_and_spawn",
  params: {
    err: JSON.stringify({ key: "ui.err_connect", params: { err: "Connection refused (os error 61)" } }),
    spawn_err: "Permission denied (os error 13)",
  },
});
const SLEEP_ERR = JSON.stringify({ key: "ui.err_auth_cancelled", params: {} });

const { invokeMock } = vi.hoisted(() => ({ invokeMock: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: invokeMock }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));

function desktop() {
  invokeMock.mockImplementation(async (cmd) => {
    switch (cmd) {
      case "write_config":
        return null;
      case "power_hint":
        return { kind: "sleeps", minutes: 10 };
      case "disable_auto_sleep":
        throw SLEEP_ERR;
      case "start_daemon":
        throw NESTED_START_ERR;
      default:
        throw new Error(`unexpected command: ${cmd}`);
    }
  });
}

async function click(name) {
  await fireEvent.click(screen.getByRole("button", { name }));
  await vi.advanceTimersByTimeAsync(0);
}

function pageText() {
  return document.body.textContent;
}

describe.each([
  ["Wizard.svelte", Wizard],
  ["WizardWindows.svelte", WizardWindows],
])("%s：英文系统下整页没有中文", (_name, Component) => {
  beforeEach(() => {
    vi.useFakeTimers();
    invokeMock.mockReset();
    desktop();
  });
  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it("三步走完（含一键设置失败、启动失败两条红条），每一屏都没有中文", async () => {
    render(Component, {
      props: { defaultDir: "/Users/someone/Pictures/P-Pass", configuredLibraryDir: null, onDone: vi.fn() },
    });
    expect(pageText()).toContain(t("ui.wizard_library_title"));
    expect(pageText()).not.toMatch(HAN);

    await click("Continue");
    expect(pageText()).toContain(t("ui.wizard_sleep_on"));
    await click("Fix it for me");
    // keyed 错误被渲染成英文句子，而不是 {"key":…} 原串。
    expect(pageText()).toContain("Authorization cancelled — you can also click");
    expect(pageText()).not.toMatch(HAN);

    await click("Continue");
    expect(pageText()).toContain(t("ui.wizard_service_title"));
    expect(pageText()).not.toMatch(HAN);

    await click("Finish");
    const bar = document.querySelector("p.text-act").textContent;
    expect(bar).toBe(
      "Failed to start the background service: Registering the service failed " +
        "(Couldn't connect to the background service: Connection refused (os error 61)), " +
        "and starting it directly failed too (Permission denied (os error 13))",
    );
    expect(pageText()).not.toMatch(HAN);
  });
});

describe("errText：Rust 壳回来的三种错误形状", () => {
  it("keyed 错误（JSON 串或对象）按 key 渲染，参数原样透传", () => {
    const e = JSON.stringify({ key: "ui.err_sleep_fix_failed", params: { err: "exit 1" } });
    expect(errText(e)).toBe("Setup failed: exit 1");
    expect(errText({ key: "ui.err_no_daemon", params: {} })).toBe(t("ui.err_no_daemon"));
  });

  it("裸 msg_key（daemon 回的 err.*）按 key 渲染，不再原样显示 key", () => {
    expect(errText("err.not_authorized")).toBe(t("err.not_authorized"));
    expect(errText("err.not_authorized")).not.toContain("err.");
  });

  it("其它一律原样：普通串、看起来像 JSON 的串、Error 对象", () => {
    expect(errText("ipc timeout: status > 10s")).toBe("ipc timeout: status > 10s");
    expect(errText("{not json")).toBe("{not json");
    expect(errText(new Error("boom"))).toBe("Error: boom");
  });

  it("中文环境下同一条 keyed 错误渲染成中文原文", () => {
    setLocale("zh");
    try {
      expect(errText(SLEEP_ERR)).toBe("已取消授权");
    } finally {
      setLocale("en");
    }
  });
});
