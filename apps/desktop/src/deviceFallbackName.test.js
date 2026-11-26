// @vitest-environment jsdom
//
// #1406：设备名为空时列表里显示兜底名「手机 · <ID 前 4 位>」，且可点击进入改名。
// #1433：兜底名抽成 lib/deviceDisplayName.js 的共用函数——列表主行、水位卡、
//        移除确认弹窗三处必须取到同一个名字（各写一套口径一定会漂）。
// 挂载真的 App.svelte（同 deviceNeedsUpdate.test.js）。
//
// 反证：把任一处的 displayName(d) 改回 `{d.name}`（或 revoke 的第二个实参改回
// d.name），对应用例必须红——空名那一处渲染成空白，找不到「手机 · cccc」。
import { cleanup, render, screen, fireEvent } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { invokeMock, handlers, confirmMock } = vi.hoisted(() => {
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
  return { invokeMock: vi.fn(), handlers: new Map(), confirmMock: vi.fn(async () => true) };
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
  confirm: confirmMock,
  message: vi.fn(async () => {}),
}));
vi.mock("@tauri-apps/plugin-updater", () => ({ check: vi.fn(async () => null) }));
vi.mock("@tauri-apps/plugin-opener", () => ({
  revealItemInDir: vi.fn(),
  openUrl: vi.fn(),
}));

import App from "./App.svelte";
import { displayName } from "./lib/deviceDisplayName.js";
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

async function openPage(hash) {
  location.hash = hash;
  render(App);
  await vi.advanceTimersByTimeAsync(0);
}

const openDevices = () => openPage("#/devices");

beforeEach(() => {
  vi.useFakeTimers();
  invokeMock.mockReset();
  confirmMock.mockClear();
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

// 三处显示点共用同一个函数，这一组钉住 #1406 定案的三种输入：name 为空
// （有型号 / 无型号）与有名字。devices.list 目前不带 model 字段，线上恒走
// 「手机」那一支；型号分支先按定案实现并钉住，daemon 补字段即生效。
describe("#1433 兜底名纯函数（唯一口径）", () => {
  it("空名 + 无型号 → 「手机 · <ID 前 4 位>」", () => {
    expect(displayName({ name: "", node_id: NODE })).toBe("手机 · cccc");
  });

  it("空名 + 有型号 → 「<型号> · <ID 前 4 位>」（#1406 例：SM-S9210 · 3f2a）", () => {
    expect(displayName({ name: "", model: "SM-S9210", node_id: "3f2a1234" })).toBe("SM-S9210 · 3f2a");
  });

  it("纯空白名 → 同样兜底（无型号）", () => {
    expect(displayName({ name: "   ", node_id: "abcdef1234" })).toBe("手机 · abcd");
  });

  it("纯空白型号 → 当没有型号", () => {
    expect(displayName({ name: "", model: "   ", node_id: NODE })).toBe("手机 · cccc");
  });

  it("有名字 → 用名字，型号不参与", () => {
    expect(displayName({ name: "测试手机", model: "SM-S9210", node_id: NODE })).toBe("测试手机");
  });

  it("名字两边空白 → 去掉空白", () => {
    expect(displayName({ name: "  测试手机  ", node_id: NODE })).toBe("测试手机");
  });
});

describe("#1433 三处显示同一个兜底名", () => {
  it("设备列表主行：空名 → 「手机 · cccc」，与 ID 列 #cccccccc 的前 4 位对得上", async () => {
    daemon("");
    await openDevices();
    expect(screen.getByRole("button", { name: "手机 · cccc" })).toBeTruthy();
    expect(screen.getByText("#cccccccc")).toBeTruthy();
  });

  it("水位卡（总览）：空名 → 「手机 · cccc」", async () => {
    daemon("");
    await openPage("#/overview");
    expect(screen.getByText("手机 · cccc")).toBeTruthy();
  });

  it("断开确认弹窗：点「断开」→ 弹窗正文点名「手机 · cccc」", async () => {
    daemon("");
    await openDevices();
    await fireEvent.click(screen.getByRole("button", { name: "断开 手机 · cccc" }));
    await vi.advanceTimersByTimeAsync(0);
    expect(confirmMock).toHaveBeenCalledWith(
      expect.stringContaining("手机 · cccc"),
      expect.anything(),
    );
  });

  it("兜底名本身可点击进入改名", async () => {
    daemon("   ");
    await openDevices();
    await fireEvent.click(screen.getByRole("button", { name: "手机 · cccc" }));
    expect(document.querySelector("input")).toBeTruthy();
  });

  it("有名字时三处照常显示名字（反证：不被兜底名覆盖）", async () => {
    daemon("测试手机");
    await openDevices();
    expect(screen.getByRole("button", { name: "测试手机" })).toBeTruthy();
    expect(screen.queryByText("手机 · cccc")).toBeNull();
  });
});
