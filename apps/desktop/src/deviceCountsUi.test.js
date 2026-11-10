// @vitest-environment jsdom
//
// #1402 卡1：总览顶部、备份状态卡、设备页三处说同一件事。挂载真的
// App.svelte，daemon 由 invoke mock 扮演（同 deviceNeedsUpdate.test.js）。
//
// 反证：把顶部/设备页的计数改回数列表行（含已断开的），第一条里
// 「已配对设备 0 台」变 1 台、第二条的「另有 1 台已断开」消失；
// 把卡片空状态判据改回 devices 列表，第一条的空状态文案变回
// 「还没有配对的设备。」（都是本卡要消除的打架）。
import { cleanup, render } from "@testing-library/svelte";
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
vi.mock("@tauri-apps/api/app", () => ({ getVersion: async () => "0.6.0" }));
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
import { daemonMethodOf } from "./lib/daemonApi.js";
import { setLocale } from "./lib/i18n.js";

const row = (node, name, removal) => ({
  node_id: node.repeat(64),
  name,
  removal,
  row_state: removal === "disconnected" ? "disconnected" : "idle",
  presence: "offline",
  last_seen: null,
  needs_update: null,
});

/** daemon 的两个结论是分开的两个 IPC：计数在 status，每行在 devices.list。 */
function daemon({ paired, disconnected = 0, removed = 0 }, devices) {
  invokeMock.mockImplementation(async (cmd) => {
    switch (daemonMethodOf(cmd) ? "daemon" : cmd) {
      case "wizard_state":
        return { show_wizard: false };
      case "service_state":
        return { state: "running" };
      case "daemon":
        switch (daemonMethodOf(cmd)) {
          case "status":
            return {
              version: "v0.6.0",
              pending_pairs: 0,
              photo_sources: 0,
              photo_count: 0,
              paired_devices: paired,
              disconnected_devices: disconnected,
              removed_devices: removed,
            };
          case "devices.list":
            return { devices, last_backup_overall: null };
          case "device.watermarks":
            return { watermarks: [] };
          case "audit.list":
            return { events: [] };
          case "timeline.page":
            return { items: [], next: null };
          case "pairing.pending":
            return { pending: [] };
          default:
            return {};
        }
      default:
        return null;
    }
  });
}

const text = () => document.body.textContent.replace(/\s+/g, " ");

async function open(hash = "") {
  location.hash = hash;
  render(App);
  await vi.advanceTimersByTimeAsync(0);
}

beforeEach(() => {
  vi.useFakeTimers();
  invokeMock.mockReset();
  handlers.clear();
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
  // 英文渲染用例里切过 locale，这里复位，别影响后续用例。
  setLocale("zh");
});

describe("断开后总览顶部与备份状态卡一致（#1402 卡1）", () => {
  it("手机自己断开后：顶部 0 台、卡片说清 1 台已断开，不再自相矛盾", async () => {
    daemon({ paired: 0, disconnected: 1 }, [row("b", "断开的那台", "disconnected")]);
    await open();

    expect(text()).toContain("已配对设备 0 台");
    expect(text()).toContain("（另有 1 台已断开）");
    expect(text()).toContain("还没有配对的设备（1 台已断开）。");
    // 已断开的不计入「已配对」：改回数列表行这里就是 1 台。
    expect(text()).not.toContain("已配对设备 1 台");
  });

  it("断开与在用并存：顶部 1 台 + 另有 1 台已断开，卡片仍有在用设备行", async () => {
    daemon({ paired: 1, disconnected: 1 }, [
      row("a", "在用的那台", "none"),
      row("b", "断开的那台", "disconnected"),
    ]);
    await open();

    expect(text()).toContain("已配对设备 1 台");
    expect(text()).toContain("（另有 1 台已断开）");
    expect(text()).toContain("在用的那台");
    expect(text()).not.toContain("还没有配对的设备");
  });

  it("设备页副标题同一口径", async () => {
    daemon({ paired: 0, disconnected: 1 }, [row("b", "断开的那台", "disconnected")]);
    await open("#/devices");

    expect(text()).toContain("已配对设备 0 台（另有 1 台已断开）");
  });

  it("设备页主列表分「已配对」「已断开」，已移除折叠区隐藏（#1402 卡2）", async () => {
    daemon({ paired: 1, disconnected: 1, removed: 1 }, [
      row("a", "在用的那台", "none"),
      row("b", "断开的那台", "disconnected"),
      row("c", "移除的那台", "removed"),
    ]);
    await open("#/devices");

    expect(text()).toContain("在用的那台");
    expect(text()).toContain("断开的那台");
    // 分组标题真的渲染（把 deviceGroups 换成平铺列表，这两条会红）。
    expect(document.querySelector('[data-testid="device-group-paired"]')?.textContent).toContain("已配对");
    expect(document.querySelector('[data-testid="device-group-disconnected"]')?.textContent).toContain("已断开");
    // 已移除折叠区隐藏：看不到移除的那台，也看不到「已移除设备 N 台」。
    expect(text()).not.toContain("移除的那台");
    expect(text()).not.toContain("已移除设备");
  });

  it("15 天提示不覆盖 5 天备份告警（同时满足两者时告警优先）", async () => {
    daemon({ paired: 1, disconnected: 0 }, [
      {
        ...row("a", "在用的那台", "none"),
        row_state: "needs_attention",
        last_seen: Date.now() - 16 * 86400000,
      },
    ]);
    await open("#/devices");

    expect(text()).toContain("需要处理");
    expect(text()).not.toContain("很久没联系");
  });

  it("当前在线（有活连接）的设备不显示 15 天提示", async () => {
    daemon({ paired: 1, disconnected: 0 }, [
      {
        ...row("a", "在用的那台", "none"),
        presence: "online",
        row_state: "online",
        last_seen: Date.now() - 16 * 86400000,
      },
    ]);
    await open("#/devices");

    expect(text()).toContain("在线");
    expect(text()).not.toContain("很久没联系");
  });

  it("英文界面渲染分组标题与 15 天提示（en locale）", async () => {
    setLocale("en");
    daemon({ paired: 1, disconnected: 1 }, [
      { ...row("a", "Paired Device", "none"), last_seen: Date.now() - 16 * 86400000 },
      row("b", "Disconnected Device", "disconnected"),
    ]);
    await open("#/devices");

    // 英文分组标题（数据字典存在 ≠ 界面渲染，这里钉住渲染层）。
    expect(document.querySelector('[data-testid="device-group-paired"]')?.textContent).toContain("Paired");
    expect(document.querySelector('[data-testid="device-group-disconnected"]')?.textContent).toContain("Disconnected");
    // 英文 15 天提示
    expect(text()).toContain("No contact for a while");
  });
});
