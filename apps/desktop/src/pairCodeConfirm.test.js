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
import { cleanup, render, screen, fireEvent, within } from "@testing-library/svelte";
import { readFileSync } from "node:fs";
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
              // 真实时序：daemon 先作废这次申请（撤行 + 推 pending_changed，前端随即 refresh），
              // 然后才回复 confirm 的错误。854bb867 就是在这一步按「队列空了」把弹窗关掉的。
              d.pending = d.pending.filter((p) => p.node_id !== args?.node_id);
              await pushPendingChanged();
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

  const dialogOpen = () => screen.queryAllByTestId("pending-request").length > 0;

  // 真机：新申请要先关弹窗、点横幅「输入验证码」才看得到内容。现在到达即弹出、按钮可见，
  // 不管二维码弹窗开没开。反证：只在二维码弹窗开着时才弹 → 红。
  it("申请到达时自动弹出，按钮可见", async () => {
    const d = desktop();
    render(App);
    await settle();
    d.pending = [row("a", "Galaxy S24 Ultra")];
    await pushPendingChanged();
    expect(dialogOpen()).toBe(true);
    expect(screen.getByRole("heading", { name: "Galaxy S24 Ultra 请求加入" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "拒绝" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "允许加入" })).toBeTruthy();
  });

  // 样式参照 macOS 提示框：单台时内容直接在弹窗里，不套卡片。顺序：标题 → 角色小字 → 6 格 → 提示 → 按钮行。
  // 反证：恢复 .pending-row 灰底卡片，或把按钮放回验证码那一行 → 红。
  it("单台：标题即请求内容，角色小字，不套卡片，按钮单独一行", async () => {
    const d = desktop();
    render(App);
    await settle();
    await openRow(d, [row("a", "Galaxy S24 Ultra")]);
    const block = screen.getByTestId("pending-request");
    expect(document.querySelector(".pending-title").textContent).toBe("Galaxy S24 Ultra 请求加入");
    expect(block.textContent).not.toContain("Galaxy S24 Ultra"); // 名字只在标题里出现一次
    expect(block.querySelector(".pending-meta").textContent).toBe("家庭成员 · 可以备份和浏览照片");
    expect(block.textContent).toContain("输入手机上显示的验证码");
    expect(document.body.textContent).not.toContain("确认是家人的手机吗");
    expect(document.body.textContent).not.toContain("验证码只能输入一次");
    // 不套卡片：没有旧的灰底块，块不在卡片组件里，块的样式也不带底色。
    expect(document.querySelector(".pending-row")).toBeNull();
    expect(block.closest('[data-slot="card"]')).toBeNull();
    const css = readFileSync(`${process.cwd()}/src/App.svelte`, "utf8");
    const at = css.indexOf("  .pending-request {");
    expect(css.slice(at, css.indexOf("}", at))).not.toMatch(/background/);
    // 顺序与按钮行。
    const order = [...block.children].map((el) => el.className.split(" ")[0]);
    expect(order).toEqual(["pending-meta", "pending-code", "pending-hint", "pending-actions"]);
    const actions = screen.getByTestId("pending-actions");
    expect(actions.querySelector('[data-slot="input-otp-slot"]')).toBeNull();
    expect([...actions.querySelectorAll("button")].map((b) => b.textContent.trim())).toEqual(["拒绝", "允许加入"]);
    expect(block.querySelectorAll('[data-slot="input-otp-slot"]')).toHaveLength(6);
  });

  it("多台：总标题报数量，每块以设备名开头", async () => {
    const d = desktop();
    render(App);
    await settle();
    await openRow(d, [row("a", "Galaxy S24 Ultra"), row("b", "iPhone")]);
    expect(document.querySelector(".pending-title").textContent).toBe("2 台设备请求加入");
    const blocks = screen.getAllByTestId("pending-request");
    expect(blocks.map((b) => b.firstElementChild.textContent)).toEqual(["Galaxy S24 Ultra", "iPhone"]);
  });

  // 反证：Dialog 不处理 Esc / 不传 onClose → 关不掉；把关闭接到 confirmPair(false) → 发出拒绝，红。
  it("Esc 与关闭按钮只收起弹窗，不拒绝；首页留着待处理入口", async () => {
    const d = desktop();
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    await fireEvent.keyDown(window, { key: "Escape" });
    await settle();
    expect(dialogOpen()).toBe(false);
    expect(confirmCalls()).toHaveLength(0);
    expect(document.body.textContent).toContain("「妈妈的手机」请求加入");
    await fireEvent.click(screen.getByRole("button", { name: "输入验证码" }));
    await settle();
    expect(dialogOpen()).toBe(true);
    await fireEvent.click(screen.getByRole("button", { name: "关闭" }));
    await settle();
    expect(dialogOpen()).toBe(false);
    expect(confirmCalls()).toHaveLength(0);
  });

  it("重连：标题点名，按钮是「允许重连」，带事实小字", async () => {
    const d = desktop();
    render(App);
    await settle();
    await openRow(d, [{ ...row("b", "客厅的手机"), known: true, paired: true, photo_count: 12 }]);
    expect(document.querySelector(".pending-title").textContent).toBe("客厅的手机 请求重新连接");
    expect(screen.getByRole("button", { name: "允许重连" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "允许加入" })).toBeNull();
    expect(screen.getByTestId("pending-request").textContent).toContain("已存 12 张");
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

  // 真机：输错点「允许」后弹窗直接关掉，看不到错误（daemon 先撤行推事件，前端按队列空关了弹窗）。
  // 反证：弹窗 open 条件改回看队列 / 码错不进 failed → 红。
  it("输错：弹窗不关，块停在终态；点「知道了」后才关", async () => {
    const d = desktop();
    d.confirmError = JSON.stringify({ key: "ui.err_pair_code_wrong", params: {} });
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    await fireEvent.input(screen.getByTestId("pair-code-input"), { target: { value: "654321" } });
    await fireEvent.click(screen.getByRole("button", { name: "允许加入" }));
    await settle();
    await settle();
    expect(d.pending).toHaveLength(0); // daemon 那边已经作废
    expect(dialogOpen()).toBe(true);
    const block = screen.getByTestId("pending-request");
    expect(block.dataset.phase).toBe("failed");
    expect(block.textContent).toContain("验证码不对，这次配对已作废，请在手机上重新扫码");
    expect(screen.queryByRole("button", { name: "允许加入" })).toBeNull();
    await fireEvent.click(screen.getByRole("button", { name: "知道了" }));
    await settle();
    expect(dialogOpen()).toBe(false);
  });

  // 真机：重新扫码后，新申请还挂着上一次的错误、没有按钮。错误绑在申请上，新申请从干净状态开始。
  // 反证：状态按 node_id 存 → 红。
  it("同一台手机再次申请：没有旧错误，按钮可用", async () => {
    const d = desktop();
    d.confirmError = JSON.stringify({ key: "ui.err_pair_code_wrong", params: {} });
    render(App);
    await settle();
    await openRow(d, [row("a", "妈妈的手机")]);
    await fireEvent.input(screen.getByTestId("pair-code-input"), { target: { value: "654321" } });
    await fireEvent.click(screen.getByRole("button", { name: "允许加入" }));
    await settle();
    await settle();
    expect(screen.getByTestId("pending-request").dataset.phase).toBe("failed");
    // 不点「知道了」，手机直接重新扫码：同一台、新的一次申请。
    d.confirmError = null;
    d.pending = [{ ...row("a", "妈妈的手机"), requested_at: 1_790_000_100_000 }];
    await pushPendingChanged();
    const fresh = screen.getAllByTestId("pending-request").find((b) => b.dataset.phase === "input");
    expect(fresh).toBeTruthy();
    expect(fresh.textContent).not.toContain("验证码不对");
    expect(fresh.querySelector("input").value).toBe("");
    expect(within(fresh).getByRole("button", { name: "拒绝" }).disabled).toBe(false);
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
