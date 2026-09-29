// @vitest-environment jsdom
//
// DEV-07 后续（#463，产品拍板）：手机在等待页点「取消」撤回配对请求后，
// 桌面待确认列表里那一行**直接消失**，而不是留一行、点了「允许」才报
// 「确认失败」。
//
// 前端没有为此新增代码：daemon 在撤回时把该行移出主人队列（ipc.rs
// `live_queue`），并推已有的 `pairing.pending_changed`；App.svelte 的
// onDaemonEvent → refresh() 重新拉 `status` + `pairing.pending`，列表空了就
// 关确认弹窗（与主人自己处理完最后一行走同一条路）。本文件把这条既有路径
// 钉住，挂载的是真的 App.svelte，daemon 由 invoke mock 扮演。
//
// 反证：把 onDaemonEvent 里的 refresh() 去掉，前两条用例必须红（弹窗和
// 「允许加入」按钮都还在）。
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

const row = (hexByte, name) => ({
  node_id: hexByte.repeat(64),
  known: false,
  name,
  requested_at: 1_790_000_000_000,
  expired: false,
});

/** 常驻服务正常的桌面；`d.pending` 就是 daemon 主人队列（撤回 = 从里面删）。 */
function desktop() {
  const d = { pending: [] };
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
            // daemon 口径：计数与 pairing.pending 读同一个过滤后的队列。
            return { version: "v0.6.0", pending_pairs: d.pending.length, photo_sources: 1 };
          case "pairing.pending":
            return { pending: d.pending };
          case "pairing.start":
            return { qr: "ppf://pair?node=aa&t=bb" };
          case "devices.list":
            return { devices: [] };
          case "device.watermarks":
            return { watermarks: [] };
          case "activity.list":
            return { batches: [] };
          case "audit.list":
            return { events: [] };
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

/** daemon 推一条 `pairing.pending_changed`（src-tauri 转发成 `daemon-event`）。 */
async function pushPendingChanged() {
  handlers.get("daemon-event")?.({ payload: { event: "pairing.pending_changed", data: {} } });
  await settle();
}

const allowButtons = () => screen.queryAllByRole("button", { name: "允许加入" });

/** 点「显示配对二维码」→ 手机扫码入队 → 事件到达，确认弹窗打开。 */
async function scanned(d, rows) {
  await fireEvent.click(screen.getByRole("button", { name: "显示配对二维码" }));
  await settle();
  d.pending = rows;
  await pushPendingChanged();
}

describe("DEV-07 后续：手机撤回的配对请求从桌面待确认列表消失", () => {
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

  it("弹窗正开着这一行时手机撤回 → 弹窗关掉，页面上没有可点的「允许加入」", async () => {
    const d = desktop();
    render(App);
    await settle();
    await scanned(d, [row("a", "撤回的手机")]);
    expect(screen.getByText("撤回的手机")).toBeTruthy();
    expect(allowButtons()).toHaveLength(1);

    // 手机点「取消」：daemon 把这一行移出队列并推 pending_changed。
    d.pending = [];
    await pushPendingChanged();

    expect(screen.queryByText("撤回的手机")).toBeNull();
    // 弹窗关了，横幅（pending_pairs > 0 才显示）也不出现。
    expect(allowButtons()).toHaveLength(0);
  });

  it("两台同时在等，只撤回其中一台 → 只有那一行消失，另一行照常可批", async () => {
    const d = desktop();
    render(App);
    await settle();
    await scanned(d, [row("a", "撤回的手机"), row("b", "还在等的手机")]);
    expect(allowButtons()).toHaveLength(2);

    d.pending = [row("b", "还在等的手机")];
    await pushPendingChanged();

    expect(screen.queryByText("撤回的手机")).toBeNull();
    expect(screen.getByText("还在等的手机")).toBeTruthy();
    expect(allowButtons()).toHaveLength(1);
  });
});
