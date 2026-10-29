// @vitest-environment jsdom
//
// I18N-03 (#492)：系统语言是英文时，向导三步 + Rust 壳回来的错误都不能
// 露出中文。真机截图（E3）之外能在 CI 里钉住的那一半：挂载真组件、走完
// 每一步，读渲染出来的整页文本。
//
// 反证：把 Wizard.svelte 任一处 t(...) 换回中文字面量，或让 errMessage 不认
// keyed 错误（直接 String(e)），这里必须红。
import { cleanup, render, screen, fireEvent } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Wizard from "./Wizard.svelte";
import WizardWindows from "./WizardWindows.svelte";
import { errCode, errMessage, errText, setLocale, t } from "./lib/i18n.js";

setLocale("en");

const HAN = new RegExp("[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]");

// Rust 壳的线上格式（ipc::ui_err）：壳错误包着一条更具体的错误，底层细节（OS 原文）在参数里。
const NESTED_START_ERR = JSON.stringify({
  key: "ui.err_register_and_spawn",
  params: {
    err: JSON.stringify({
      key: "ui.err_daemon_not_ours",
      params: { path: "/tmp/ppf.sock", reason: "Connection refused (os error 61)" },
    }),
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

// DAE-11 (#804)：Windows 向导第 2 步不再有「一键关闭自动睡眠」，只剩一句说明；
// macOS 那份等 #999 再改，仍走一键设置。
describe.each([
  ["Wizard.svelte", Wizard, true],
  ["WizardWindows.svelte", WizardWindows, false],
])("%s：英文系统下整页没有中文", (_name, Component, hasSleepFix) => {
  beforeEach(() => {
    vi.useFakeTimers();
    invokeMock.mockReset();
    desktop();
  });
  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it("三步走完（含一键设置失败〔仅 macOS〕、启动失败两条红条），每一屏都没有中文", async () => {
    render(Component, {
      props: { defaultDir: "/Users/someone/Pictures/P-Pass", configuredLibraryDir: null, onDone: vi.fn() },
    });
    expect(pageText()).toContain(t("ui.wizard_library_title"));
    expect(pageText()).not.toMatch(HAN);

    await click("Continue");
    if (hasSleepFix) {
      expect(pageText()).toContain(t("ui.wizard_sleep_on"));
      await click("Turn off auto sleep");
      // keyed 错误被渲染成英文句子 + 错误代码，而不是 {"key":…} 原串。
      expect(pageText()).toContain("Authorization cancelled. Auto sleep wasn't turned off.");
      expect(pageText()).toContain("Error code: auth_cancelled");
    } else {
      expect(pageText()).toContain(t("ui.wizard_sleep_auto_win"));
      expect(screen.queryByRole("button", { name: "Turn off auto sleep" })).toBeNull();
    }
    expect(pageText()).not.toMatch(HAN);

    await click("Continue");
    expect(pageText()).toContain(t("ui.wizard_service_title"));
    expect(pageText()).not.toMatch(HAN);

    await click("Finish");
    // B13：显示嵌套里最内层的已登记错误（出路最具体）+ 它的错误代码；OS 原文不进界面。
    const bar = document.querySelector("p.text-act").textContent;
    expect(bar).toContain(t("ui.err_daemon_not_ours"));
    expect(bar).toContain("Error code: daemon_not_ours");
    expect(bar).not.toContain("os error");
    expect(pageText()).not.toMatch(HAN);
  });
});

describe("errMessage：Rust 壳回来的三种错误形状（B13：正文 + 错误代码，原文只进 console）", () => {
  let warn;
  beforeEach(() => {
    warn = vi.spyOn(console, "warn").mockImplementation(() => {});
  });
  afterEach(() => warn.mockRestore());

  it("keyed 错误（JSON 串或对象）按 key 渲染，参数里的原文不进界面", () => {
    const e = JSON.stringify({ key: "ui.err_sleep_fix_failed", params: { err: "exit 1" } });
    expect(errMessage(e)).toEqual({
      key: "ui.err_sleep_fix_failed",
      text: t("ui.err_sleep_fix_failed"),
      code: "sleep_fix_failed",
    });
    expect(errText(e)).not.toContain("exit 1");
    expect(warn).toHaveBeenCalled();
    expect(errMessage({ key: "ui.err_no_daemon", params: {} }).text).toBe(t("ui.err_no_daemon"));
  });

  it("嵌套时取最内层的已登记 key；ui.err_generic 不算，退回外层", () => {
    expect(errMessage(NESTED_START_ERR).key).toBe("ui.err_daemon_not_ours");
    const generic = JSON.stringify({ key: "ui.err_restart", params: { err: "ui.err_generic" } });
    expect(errMessage(generic).key).toBe("ui.err_restart");
  });

  it("内层不是已登记 key 时显示包装句，代码用包装句的 key", () => {
    expect(errMessage(new Error("boom"), "ui.stop_failed")).toEqual({
      key: "ui.stop_failed",
      text: t("ui.stop_failed"),
      code: "stop_failed",
    });
    expect(errMessage("ui.err_no_daemon", "ui.stop_failed").key).toBe("ui.err_no_daemon");
  });

  it("裸已注册 key 按 key 渲染，不显示 key 本身", () => {
    expect(errText("err.not_authorized")).toBe(t("err.not_authorized"));
    expect(errText("err.not_authorized")).not.toContain("err.");
    expect(errMessage("err.not_authorized").code).toBe("not_authorized");
  });

  it("未注册的串（含 daemon 机器码）一律通用文案，原串不进界面、只进 console", () => {
    for (const raw of ["storage_full", "ipc timeout: status > 10s", "{not json", "err.never_registered"]) {
      expect(errText(raw)).toBe(t("ui.err_generic"));
      expect(errText(raw)).not.toContain(raw);
    }
    expect(errText(new Error("boom"))).toBe(t("ui.err_generic"));
    expect(errText({ key: "ui.never_registered", params: {} })).toBe(t("ui.err_generic"));
    expect(errMessage("storage_full").code).toBe("generic");
    expect(warn).toHaveBeenCalledWith(expect.any(String), expect.any(String), expect.any(String), "storage_full");
  });

  it("错误代码 = key 去掉 ui.err_ / err. / ui. 前缀，用 ui.err_code 渲染", () => {
    expect(errCode("ui.err_generic")).toBe("generic");
    expect(errCode("err.disk_full")).toBe("disk_full");
    expect(errCode("ui.update_failed_file_locked")).toBe("update_failed_file_locked");
    expect(t("ui.err_code", { code: "generic" })).toBe("Error code: generic");
  });

  it("中文环境下同一条 keyed 错误渲染成中文原文", () => {
    setLocale("zh");
    try {
      expect(errText(SLEEP_ERR)).toBe("已取消授权，自动睡眠没有关闭。");
      expect(t("ui.err_code", { code: "auth_cancelled" })).toBe("错误代码：auth_cancelled");
    } finally {
      setLocale("en");
    }
  });
});
