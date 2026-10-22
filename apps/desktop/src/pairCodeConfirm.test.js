// @vitest-environment jsdom
//
// #1118：确认加入 = 输入手机屏幕上的 6 位验证码。挂载真的 App.svelte，daemon 由 invoke mock 扮演
// （脚手架同 pairWithdrawnRow.test.js）。钉住：
// - 不满 6 位数字时「确认加入」不可点；满了才可点，提交时带上这一行的码（node_id + code）；
// - 码错（daemon 回 pair_code_wrong）给出「验证码不对，这次配对已作废」；
// - 还在等手机（verifying）给出「验证码已提交」；
// - 二维码弹窗里显示本机标识（status.desktop_fingerprint），供手机核对。
// 反证：去掉按钮的 disabled={!isPairCode(code)} ⇒ 第一条红；confirmPair 不带 code ⇒ 第一条红。
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
    switch (daemonMethodOf(cmd) ? "daemon" : cmd) {
      case "wizard_state":
        return { show_wizard: false };
      case "service_state":
        return { state: "running" };
      case "self_heal_daemon":
      case "notify_system":
        return null;
      case "daemon":
        switch (daemonMethodOf(cmd)) {
          case "status":
            // daemon 口径：计数与 pairing.pending 读同一个过滤后的队列。
            return {
              version: "v0.6.0",
              pending_pairs: d.pending.length,
              photo_sources: 1,
              desktop_fingerprint: d.fingerprint,
              desktop_name: d.desktopName,
            };
          case "pairing.pending":
            return { pending: d.pending };
          case "pairing.start":
            return { qr: "ppf://pair?node=aa&t=bb" };
          case "pairing.confirm":
            if (d.confirmError) throw d.confirmError;
            return d.confirmReply ?? { decided: true };
          case "devices.list":
            return { devices: [] };
          case "device.watermarks":
            return { watermarks: [] };
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

// #1118：每一行的确认按钮（输入手机上的验证码后才可点；行在不在看按钮在不在）。
const allowButtons = () => screen.queryAllByRole("button", { name: "确认加入" });

/** 点「显示配对二维码」→ 手机扫码入队 → 事件到达，确认弹窗打开。 */
async function scanned(d, rows) {
  await fireEvent.click(screen.getByRole("button", { name: "显示配对二维码" }));
  await settle();
  d.pending = rows;
  await pushPendingChanged();
}


async function openRow(d, rows) {
  await fireEvent.click(screen.getByRole("button", { name: "显示配对二维码" }));
  await settle();
  d.pending = rows;
  await pushPendingChanged();
}

function confirmCalls() {
  return invokeMock.mock.calls.filter(([cmd]) => daemonMethodOf(cmd) === "pairing.confirm");
}

describe("#1118 确认加入要输入手机上的验证码", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    invokeMock.mockReset();
    handlers.clear();
    location.hash = "";
    globalThis.IntersectionObserver = class {
      observe() {}
      disconnect() {}
    };
    globalThis.matchMedia = () => ({
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

  it("不满 6 位不可确认；满了提交时带上这一行的 node_id 与码", async () => {
    const d = desktop();
    d.confirmReply = { decided: true, device: "妈妈的手机" };
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    const button = screen.getByRole("button", { name: "确认加入" });
    expect(button.disabled).toBe(true);
    const input = screen.getByTestId("pair-code-input");
    await fireEvent.input(input, { target: { value: "12 34" } });
    expect(screen.getByRole("button", { name: "确认加入" }).disabled).toBe(true);
    await fireEvent.input(input, { target: { value: "123 456" } });
    expect(screen.getByRole("button", { name: "确认加入" }).disabled).toBe(false);
    await fireEvent.click(screen.getByRole("button", { name: "确认加入" }));
    await settle();
    const calls = confirmCalls();
    expect(calls).toHaveLength(1);
    expect(calls[0][1]).toMatchObject({ accept: true, node_id: "a".repeat(64), code: "123456" });
  });

  it("码错：提示这次配对已作废", async () => {
    const d = desktop();
    d.confirmError = JSON.stringify({ key: "ui.err_pair_code_wrong", params: {} });
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    await fireEvent.input(screen.getByTestId("pair-code-input"), { target: { value: "654321" } });
    await fireEvent.click(screen.getByRole("button", { name: "确认加入" }));
    await settle();
    expect(document.body.textContent).toContain("验证码不对，这次配对已作废");
  });

  it("手机还没确认：提示验证码已提交", async () => {
    const d = desktop();
    d.confirmReply = { decided: true, verifying: true, device: "妈妈的手机" };
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    await fireEvent.input(screen.getByTestId("pair-code-input"), { target: { value: "654321" } });
    await fireEvent.click(screen.getByRole("button", { name: "确认加入" }));
    await settle();
    expect(document.body.textContent).toContain("验证码已提交");
  });

  it("二维码弹窗显示本机名称与标识（与手机核对页上的同一对）", async () => {
    const d = desktop();
    d.fingerprint = "AB12 CD34";
    d.desktopName = "客厅的 Mac";
    render(App);
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "显示配对二维码" }));
    await settle();
    expect(screen.getByTestId("desktop-name").textContent).toContain("客厅的 Mac");
    expect(screen.getByTestId("desktop-fingerprint").textContent).toContain("AB12 CD34");
  });
});
