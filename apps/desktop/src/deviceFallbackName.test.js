// @vitest-environment jsdom
//
// #1406：设备名为空时列表里显示兜底名「手机 · <ID 前 4 位>」，且可点击进入改名。
// 挂载真的 App.svelte（同 deviceNeedsUpdate.test.js）。
//
// 反证：把按钮文案改回 `{d.name}`，两条用例必须红（空名按钮没有文字，找不到）。
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
const device = (name) => ({
  node_id: NODE,
  name,
  removal: "none",
  row_state: "idle",
  presence: "offline",
  last_seen: null,
  needs_update: null,
});

function daemon(name) {
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
            return { devices: [device(name)] };
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

describe("设备名为空的兜底名", () => {
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

  it("空名 → 显示「手机 · cccc」，与 ID 列 #cccccccc 的前 4 位对得上", async () => {
    daemon("");
    await openDevices();
    expect(screen.getByRole("button", { name: "手机 · cccc" })).toBeTruthy();
    expect(screen.getByText("#cccccccc")).toBeTruthy();
  });

  it("兜底名本身可点击进入改名", async () => {
    daemon("   ");
    await openDevices();
    await fireEvent.click(screen.getByRole("button", { name: "手机 · cccc" }));
    expect(document.querySelector("input")).toBeTruthy();
  });

  it("有名字时照常显示名字（反证：不被兜底名覆盖）", async () => {
    daemon("测试手机");
    await openDevices();
    expect(screen.getByRole("button", { name: "测试手机" })).toBeTruthy();
    expect(screen.queryByText("手机 · cccc")).toBeNull();
  });
});
