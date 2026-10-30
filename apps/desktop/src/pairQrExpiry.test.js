// @vitest-environment jsdom
//
// #1264：二维码的有效期以 daemon 为准（`pairing.start` 的 `expires_at_ms`）。挂载真的 App.svelte，
// daemon 由 invoke mock 扮演，有效期注入成 40 秒、fake timers 推时间（脚手架同 pairCodeConfirm.test.js）。
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
import { QR_AUTO_REFRESH_MAX, QR_REFRESH_LEAD_MS } from "./lib/pairQr.js";
import { daemonMethodOf } from "./lib/daemonApi.js";


const TTL = 40_000; // 注入的短有效期（生产 10 分钟，以 daemon 为准）

/** 常驻服务正常的桌面；`d.ttl` = 这台 daemon 给的码有效期（undefined = 老 daemon 不给失效时刻）。 */
function desktop(ttl) {
  const d = { ttl, failStart: false };
  invokeMock.mockImplementation(async (cmd) => {
    const m = daemonMethodOf(cmd);
    if (!m) {
      switch (cmd) {
        case "wizard_state":
          return { show_wizard: false };
        case "service_state":
          return { state: "running" };
        case "pair_qr_svg":
          return "<svg/>";
        default:
          return null;
      }
    }
    switch (m) {
      case "status":
        return { version: "v0.6.0", pending_pairs: 0, photo_sources: 1 };
      case "pairing.start":
        if (d.failStart) throw new Error("down");
        return d.ttl === undefined ? { qr: "ppf://pair?node=aa&t=bb" } : { qr: "ppf://pair?node=aa&t=bb", expires_at_ms: Date.now() + d.ttl };
      case "pairing.pending":
        return { pending: [] };
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
  });
  return d;
}

const starts = () => invokeMock.mock.calls.filter(([cmd]) => daemonMethodOf(cmd) === "pairing.start").length;
const settle = (ms = 0) => vi.advanceTimersByTimeAsync(ms);

async function openQr() {
  render(App);
  await settle();
  await fireEvent.click(screen.getByRole("button", { name: "显示配对二维码" }));
  await settle();
  expect(screen.getByTestId("pair-qr")).toBeTruthy();
}

describe("#1264 二维码不会过期了还挂在屏幕上", () => {
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

  // 反证：去掉 App 里的 $effect 计时 ⇒ 第一条红（永远只调一次 pairing.start）。
  it("快到期自动换码；换满次数后盖住过期的码，点刷新恢复", async () => {
    desktop(TTL);
    await openQr();
    expect(starts()).toBe(1);
    // 一秒一秒推，记下每次自动换码发生在打开后第几秒。
    const at = [];
    for (let sec = 1; sec <= 4 * (TTL / 1000); sec++) {
      const before = starts();
      await settle(1_000);
      if (starts() > before) at.push(sec);
    }
    expect(at.length).toBe(QR_AUTO_REFRESH_MAX);
    // 每张码都在失效前 QR_REFRESH_LEAD_MS 左右（1 秒的检查粒度内）换掉。
    const due = (TTL - QR_REFRESH_LEAD_MS) / 1000;
    at.forEach((sec, k) => {
      const issued = k === 0 ? 0 : at[k - 1];
      expect(sec - issued).toBeGreaterThanOrEqual(due);
      expect(sec - issued).toBeLessThanOrEqual(due + 1);
    });
    // 换满之后最后一张到期：盖住，不再自动换。
    const cover = screen.getByTestId("pair-qr-expired");
    expect(cover.textContent).toContain("二维码已过期");
    expect(screen.queryByTestId("pair-qr")).toBeNull();
    // 过期的配对串也不再给复制（弹窗里；首页卡片上的退路会现取新码）。
    expect(within(cover.closest("[role='dialog']")).queryByRole("button", { name: "无法扫码？复制配对码" })).toBeNull();

    await fireEvent.click(within(cover).getByRole("button", { name: "刷新二维码" }));
    await settle();
    expect(starts()).toBe(2 + QR_AUTO_REFRESH_MAX);
    expect(screen.queryByTestId("pair-qr-expired")).toBeNull();
    expect(screen.getByTestId("pair-qr")).toBeTruthy();
    // 手动刷新重新计次：还会自动换码。
    await settle(TTL - QR_REFRESH_LEAD_MS + 1_000);
    expect(starts()).toBe(3 + QR_AUTO_REFRESH_MAX);
  });

  it("自动换码失败（服务连不上）：不弹错误，码到期后盖住", async () => {
    const d = desktop(TTL);
    await openQr();
    d.failStart = true;
    await settle(TTL + 1_000);
    expect(screen.getByTestId("pair-qr-expired")).toBeTruthy();
  });

  it("关掉弹窗后不再换码", async () => {
    desktop(TTL);
    await openQr();
    await fireEvent.click(screen.getByRole("button", { name: "关闭" }));
    await settle(TTL * 5);
    expect(starts()).toBe(1);
  });

  it("老 daemon 不给失效时刻：保持原样，不换码也不盖码", async () => {
    desktop(undefined);
    await openQr();
    await settle(60 * 60 * 1000);
    expect(starts()).toBe(1);
    expect(screen.getByTestId("pair-qr")).toBeTruthy();
  });
});
