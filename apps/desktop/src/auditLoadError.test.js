// @vitest-environment jsdom
//
// AUDIT-07 (#499)：`audit.list` 读失败必须在活动记录页显示出来。
//
// 这一页唯一的数据源是 `audit.list`（App.svelte refresh()）。原来那里的 `catch (_) {}`
// 把失败吞掉：列表留空、页面渲染成「这里还没有内容」——用户会以为备份从未发生过。
// 本文件挂真的 App.svelte，daemon 由 invoke mock 扮演。
//
// 反证：把 catch 改回 `catch (_) {}`（不写 auditError）→ 第一条用例红（错误文字不出现，
// 只剩空态文案）；把模板里的 `{#if auditError}` 分支去掉 → 同样红。
import { cleanup, render, screen } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { invokeMock, handlers } = vi.hoisted(() => {
  const mem = new Map();
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (k) => (mem.has(k) ? mem.get(k) : null),
      setItem: (k, v) => mem.set(k, String(v)),
      removeItem: (k) => mem.delete(k),
      clear: () => mem.clear(),
    },
  });
  Object.defineProperty(navigator, "language", { configurable: true, value: "zh-CN" });
  return { invokeMock: vi.fn(), handlers: new Map() };
});

vi.mock("@tauri-apps/api/core", () => ({
  invoke: invokeMock,
  convertFileSrc: (p) => p,
}));
vi.mock("@tauri-apps/api/app", () => ({ getVersion: async () => "0.9.5" }));
vi.mock("@tauri-apps/api/event", () => ({
  listen: async (name, fn) => {
    handlers.set(name, fn);
    return () => handlers.delete(name);
  },
}));
vi.mock("@tauri-apps/plugin-dialog", () => ({
  open: vi.fn(),
  confirm: vi.fn(async () => true),
  message: vi.fn(async () => {}),
}));
vi.mock("@tauri-apps/plugin-updater", () => ({ check: vi.fn(async () => null) }));
vi.mock("@tauri-apps/plugin-opener", () => ({
  revealItemInDir: vi.fn(),
  openUrl: vi.fn(),
}));

import App from "./App.svelte";
import { t } from "./lib/i18n.js";

/** 常驻服务正常的桌面；`auditFails` 让 audit.list 这一步失败。 */
function desktop({ auditFails = false, events = [] } = {}) {
  const d = { auditFails, events };
  invokeMock.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "wizard_state":
        return { configured: true, installed: true, user_stopped: false };
      case "self_heal_daemon":
      case "notify_system":
        return null;
      case "daemon_call":
        switch (args.method) {
          case "status":
            return { version: "v0.9.5", pending_pairs: 0, photo_sources: 1 };
          case "pairing.pending":
            return { pending: [] };
          case "devices.list":
            return { devices: [] };
          case "device.watermarks":
            return { watermarks: [] };
          case "activity.list":
            return { batches: [] };
          case "audit.list":
            if (d.auditFails) throw new Error("audit list exploded");
            return { events: d.events };
          case "timeline.page":
            return { items: [], next: null };
          default:
            return {};
        }
      default:
        return null;
    }
  });
  return d;
}

async function settle(ms = 0) {
  await vi.advanceTimersByTimeAsync(ms);
}

async function goto(page) {
  location.hash = `#/${page}`;
  window.dispatchEvent(new HashChangeEvent("hashchange"));
  await settle();
}

beforeEach(() => {
  vi.useFakeTimers();
  invokeMock.mockReset();
  handlers.clear();
  location.hash = "";
  globalThis.IntersectionObserver = class {
    observe() {}
    disconnect() {}
  };
  window.matchMedia = () => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {},
    addListener() {},
    removeListener() {},
  });
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe("AUDIT-07：活动记录读失败不再静默吞掉", () => {
  it("audit.list 失败 → 活动记录页显示错误，而不是「这里还没有内容」", async () => {
    desktop({ auditFails: true });
    render(App);
    await settle();
    await goto("log");

    const error = screen.getByTestId("audit-error");
    expect(error.textContent).toContain("读不到活动记录");
    expect(error.textContent).toContain("audit list exploded");
    expect(
      screen.queryByText(t("ui.log_empty")),
      "读不到 ≠ 没有记录：空态文案不许同时出现",
    ).toBeNull();
  });

  it("audit.list 正常 → 没有错误行", async () => {
    desktop();
    render(App);
    await settle();
    await goto("log");

    expect(screen.queryByTestId("audit-error")).toBeNull();
    expect(screen.getByText(t("ui.log_empty"))).toBeTruthy();
  });

  it("一轮备份的终态在活动页读作「已备份 N 张照片」（这张卡要的那一行）", async () => {
    desktop({
      events: [
        {
          id: 7,
          eventId: "round-1",
          ts: 1_790_000_000_000,
          kind: "flow.round.finished",
          actor: null,
          roundId: "round-1",
          payload: null,
          evidenceSummary: { confirmed: 2 },
        },
      ],
    });
    render(App);
    await settle();
    await goto("log");

    expect(screen.queryByTestId("audit-error")).toBeNull();
    expect(screen.getByText(/已备份 2 张照片/)).toBeTruthy();
  });
});
