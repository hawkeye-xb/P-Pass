// @vitest-environment jsdom
//
// #1118：确认加入 = 输入手机屏幕上的 6 位验证码。挂载真的 App.svelte，daemon 由 invoke mock 扮演
// （脚手架同 pairWithdrawnRow.test.js）。钉住：
// - 不满 6 位数字时「允许加入」不可点；满了才可点，提交时带上这一行的码（node_id + code）；
// - 码错（daemon 回 pair_code_wrong，并撤掉这一行）提示留在该设备那块里；
// - Esc / 关闭只收起弹窗，不拒绝；请求留在首页「待处理」；
// - 每台一块，按钮单独一行（不和 6 个格子挤一行被裁掉）；重连的标题与按钮一致；
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
            if (d.confirmGate) await d.confirmGate;
            if (d.confirmError) {
              // daemon：码错 = 这次申请作废，队列里撤掉这一行。
              d.pending = d.pending.filter((p) => p.node_id !== args?.node_id);
              throw d.confirmError;
            }
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
const allowButtons = () => screen.queryAllByRole("button", { name: "允许加入" });

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
    // bits-ui PinInput 用 ResizeObserver 量输入框，jsdom 没有。
    globalThis.ResizeObserver = class {
      observe() {}
      unobserve() {}
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

  // 定稿：每台一块——名字 · 角色 / 6 格验证码 / 提示 / 按钮单独一行。
  // 反证：恢复「确认是家人的手机吗」「验证码只能输入一次」两段，或把按钮放回验证码那一行 → 红。
  it("每台一块：名字 · 角色、6 格、提示，按钮单独一行", async () => {
    const d = desktop();
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    const block = screen.getByTestId("pending-row");
    expect(block.textContent).toContain("妈妈的手机 · 家庭成员");
    expect(block.textContent).toContain("输入手机上显示的验证码");
    expect(document.body.textContent).not.toContain("确认是家人的手机吗");
    expect(document.body.textContent).not.toContain("验证码只能输入一次");
    expect(block.querySelectorAll('[data-slot="input-otp-slot"]')).toHaveLength(6);
    // 按钮所在的行不含验证码格子，验证码那一行也不含按钮——两者不会挤在同一行被裁掉。
    const actions = screen.getByTestId("pending-actions");
    expect(actions.querySelector('[data-slot="input-otp-slot"]')).toBeNull();
    expect(block.querySelector(".pending-code button")).toBeNull();
    expect(actions.parentElement).toBe(block);
    expect([...actions.querySelectorAll("button")].map((b) => b.textContent.trim())).toEqual(["拒绝", "允许加入"]);
  });

  // 反证：Dialog 不处理 Esc / 不传 onClose → 关不掉；把关闭接到 confirmPair(false) → 发出拒绝，红。
  it("Esc 与关闭按钮只收起弹窗，不拒绝；首页留着待处理入口", async () => {
    const d = desktop();
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    await fireEvent.keyDown(window, { key: "Escape" });
    await settle();
    expect(screen.queryByTestId("pending-row")).toBeNull();
    expect(confirmCalls()).toHaveLength(0);
    // 首页「待处理」可以再打开。
    await fireEvent.click(screen.getByRole("button", { name: "输入验证码" }));
    await settle();
    expect(screen.getByTestId("pending-row")).toBeTruthy();
    await fireEvent.click(screen.getByRole("button", { name: "关闭" }));
    await settle();
    expect(screen.queryByTestId("pending-row")).toBeNull();
    expect(confirmCalls()).toHaveLength(0);
  });

  it("重连：标题点名，按钮是「允许重连」", async () => {
    const d = desktop();
    render(App);
    await settle();
    await openRow(d, [{ ...row("b", "客厅的手机"), known: true, paired: true, photo_count: 12 }]);
    expect(document.body.textContent).toContain("「客厅的手机」请求重新连接");
    expect(screen.getByRole("button", { name: "允许重连" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "允许加入" })).toBeNull();
    expect(screen.getByTestId("pending-row").textContent).toContain("已存 12 张");
  });

  it("不满 6 位不可确认；满了提交时带上这一行的 node_id 与码", async () => {
    const d = desktop();
    d.confirmReply = { decided: true, device: "妈妈的手机" };
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    const button = screen.getByRole("button", { name: "允许加入" });
    expect(button.disabled).toBe(true);
    const input = screen.getByTestId("pair-code-input");
    await fireEvent.input(input, { target: { value: "12 34" } });
    expect(screen.getByRole("button", { name: "允许加入" }).disabled).toBe(true);
    // 从手机上抄来的「123 456」：粘贴时去掉空格一次填满 6 格。
    await fireEvent.paste(input, { clipboardData: { getData: () => "123 456" } });
    await settle();
    expect(input.value).toBe("123456");
    expect(document.querySelectorAll('[data-slot="input-otp-slot"]')[5].textContent.trim()).toBe("6");
    expect(screen.getByRole("button", { name: "允许加入" }).disabled).toBe(false);
    await fireEvent.click(screen.getByRole("button", { name: "允许加入" }));
    await settle();
    const calls = confirmCalls();
    expect(calls).toHaveLength(1);
    expect(calls[0][1]).toMatchObject({ accept: true, node_id: "a".repeat(64), code: "123456" });
  });

  // 确认要等手机回执（daemon 最多 8s）：等待期间按钮置灰 + 转圈，不能重复提交。
  // 反证：去掉 pairBusy → 第二次点击也发出 pairing.confirm，红。
  it("提交中：确认键转圈、两个按钮置灰，重复点击不重发", async () => {
    const d = desktop();
    let release;
    d.confirmGate = new Promise((r) => (release = r));
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    await fireEvent.input(screen.getByTestId("pair-code-input"), { target: { value: "123456" } });
    const ok = screen.getByTestId("pair-code-confirm");
    await fireEvent.click(ok);
    await settle();
    expect(ok.getAttribute("aria-busy")).toBe("true");
    expect(ok.disabled).toBe(true);
    expect(screen.getByRole("button", { name: "拒绝" }).disabled).toBe(true);
    await fireEvent.click(ok);
    expect(confirmCalls()).toHaveLength(1);
    release();
    await settle();
  });

  // 反证：码错仍走 toast、不记 pairFailed → 该行随 refresh 消失、弹窗关闭，红。
  it("码错：提示留在该设备那块里，这次申请作废", async () => {
    const d = desktop();
    d.confirmError = JSON.stringify({ key: "ui.err_pair_code_wrong", params: {} });
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    await fireEvent.input(screen.getByTestId("pair-code-input"), { target: { value: "654321" } });
    await fireEvent.click(screen.getByRole("button", { name: "允许加入" }));
    await settle();
    const block = screen.getByTestId("pending-row");
    expect(block.textContent).toContain("验证码不对，请在手机上重新扫码");
    expect(screen.queryByRole("button", { name: "允许加入" })).toBeNull();
  });

  it("手机还没确认：提示验证码已提交", async () => {
    const d = desktop();
    d.confirmReply = { decided: true, verifying: true, device: "妈妈的手机" };
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    await fireEvent.input(screen.getByTestId("pair-code-input"), { target: { value: "654321" } });
    await fireEvent.click(screen.getByRole("button", { name: "允许加入" }));
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
