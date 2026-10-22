// @vitest-environment jsdom
//
// #1071：设备列表对 daemon 标了 `needs_update` 的设备给出「需要更新」标记。
// 挂载真的 App.svelte，daemon 由 invoke mock 扮演（同 pairWithdrawnRow.test.js）。
//
// 反证：把 App.svelte 里的 `d.needs_update === "phone" || …` 渲染块删掉，
// 前两条用例必须红。
import { cleanup, render, screen, fireEvent } from "@testing-library/svelte";
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
// 记下 App 挂上的事件处理器，测试里扮演 src-tauri 转发 daemon 事件。
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

const NODE = "c".repeat(64);
const device = (needs_update) => ({
  node_id: NODE,
  name: "测试手机",
  removal: "none",
  row_state: "idle",
  presence: "offline",
  last_seen: null,
  needs_update,
});

function daemon(needsUpdate) {
  invokeMock.mockImplementation(async (cmd, args) => {
    switch (daemonMethodOf(cmd) ? "daemon" : cmd) {
      case "wizard_state":
        return { show_wizard: false };
      case "service_state":
        return { state: "running" };
      case "daemon":
        switch (daemonMethodOf(cmd)) {
          case "status":
            return { version: "v0.6.0", pending_pairs: 0, photo_sources: 1, paired_devices: 1 };
          case "devices.list":
            return { devices: [device(needsUpdate)] };
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

async function openDevices() {
  location.hash = "#/devices";
  render(App);
  await vi.advanceTimersByTimeAsync(0);
}

describe("设备列表「需要更新」标记", () => {
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
  });

  it('needs_update="phone" → 该行显示「需要更新手机 App」', async () => {
    daemon("phone");
    await openDevices();
    expect(screen.getByText("测试手机")).toBeTruthy();
    const mark = screen.getByTestId("device-needs-update");
    expect(mark.textContent.trim()).toBe("需要更新手机 App");
  });

  it('needs_update="desktop" → 该行提示更新这台电脑', async () => {
    daemon("desktop");
    await openDevices();
    expect(screen.getByTestId("device-needs-update").textContent.trim()).toBe(
      "需要更新这台电脑上的 P-Pass",
    );
  });

  it("needs_update 为 null → 没有标记（反证：正常设备不被误标）", async () => {
    daemon(null);
    await openDevices();
    expect(screen.getByText("测试手机")).toBeTruthy();
    expect(screen.queryByTestId("device-needs-update")).toBeNull();
  });
});
