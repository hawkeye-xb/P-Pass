// @vitest-environment jsdom
//
// DESK-38 (#475)：服务从「不可用」变成「可用」时，照片墙必须自己重新拉。
//
// 现场（0.6.0-test.4，本机 macOS）：停服 → 退出重开 App（服务仍停，#456）→
// 点「启动后台服务」→ 状态点变绿、daemon 可用，照片墙却一直空白，要重开 App。
//
// 根因：照片墙首拉（App.svelte 进照片页的 $effect）在 daemon 不可达时失败，
// catch 之后照样把 photosLoaded 置 true、photos 留空——墙从此认定「已加载、
// 库是空的」。之后 refresh() 只重拉状态/设备/活动，不碰墙；墙唯一的增量
// 同步入口 syncPhotosWallIncremental 只挂在 daemon 事件上，服务刚起来、
// 没有新照片就没有事件，于是墙永远停在空。
//
// 这里挂载的是真的 App.svelte，daemon 由 invoke mock 扮演：start_daemon 之前
// 每个 daemon_call 都失败，之后正常应答。断言盯渲染出来的缩略图按钮。
//
// 反证：
//   - 把 App.svelte refresh() 里「服务刚恢复 → onServiceBackOnline()」那一行
//     去掉，前三条用例必须红（墙上 0 张）；
//   - 把首拉 finally 里的 `if (gen === photosGen)` 去掉（过期的失败照样置
//     photosLoaded），第三条必须红；
//   - 把 onServiceBackOnline 改成无条件 resetPhotosWall()，「不清墙」那条必须红。
//   - #551：把 onServiceBackOnline 里的 `thumbServiceEpoch++` 去掉，或把
//     PhotoThumb 失败灰块上的 `bind:this={el}` 去掉，「#551」那条必须红
//     （灰块还在）。
import { cleanup, render, screen, fireEvent } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { invokeMock } = vi.hoisted(() => {
  // 本机 Node 自带的实验性 localStorage 在没给 --localstorage-file 时是
  // undefined，会盖住 jsdom 的那个；App 依赖的 mode-watcher 在 import 时就读它。
  // 给一个内存版，必须在 import App 之前（所以放在 hoisted 里）。
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
  // App 按系统语言选字典；jsdom 默认 en-US，这里钉成中文，断言用中文按钮名。
  Object.defineProperty(navigator, "language", { configurable: true, value: "zh-CN" });
  return { invokeMock: vi.fn() };
});

vi.mock("@tauri-apps/api/core", () => ({
  invoke: invokeMock,
  convertFileSrc: (p) => p,
}));
vi.mock("@tauri-apps/api/app", () => ({ getVersion: async () => "0.6.0" }));
vi.mock("@tauri-apps/api/event", () => ({ listen: async () => () => {} }));
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

const PHOTOS = [
  { hash: "h1", taken_at: 1787241443000, media_type: "photo", width: 10, height: 10 },
  { hash: "h2", taken_at: 1787241442000, media_type: "photo", width: 10, height: 10 },
  { hash: "h3", taken_at: 1787241441000, media_type: "photo", width: 10, height: 10 },
];

/** 一台「用户停了服务」的桌面：daemon 不可达，直到有人把它拉起来。 */
function stoppedDesktop({ slowOfflineTimeline = 0 } = {}) {
  // userStopped：用户在设置里点过「停止后台服务」（autostart 被卸、停止标记落盘）。
  const d = { up: false, userStopped: true };
  invokeMock.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "wizard_state":
        // 配过、用户主动停的 → 留在主界面（shouldShowWizard = false）；
        // 正常常驻时 autostart 在，偶尔探活失败也不回向导。
        return { configured: true, installed: !d.userStopped, user_stopped: d.userStopped };
      case "start_daemon":
        d.up = true;
        d.userStopped = false;
        return "resident";
      case "self_heal_daemon":
        return null;
      case "notify_system":
        return null;
      case "daemon_call": {
        if (!d.up) {
          // IPC 超时的形状：请求发出时服务不在，要过一阵才失败回来。
          if (args.method === "timeline.page" && slowOfflineTimeline) {
            await new Promise((r) => setTimeout(r, slowOfflineTimeline));
          }
          throw new Error("daemon unreachable");
        }
        switch (args.method) {
          case "status":
            return { version: "v0.6.0", pending_pairs: 0, photo_sources: 1 };
          case "pairing.pending":
            return { pending: [] };
          case "devices.list":
            return {
              devices: [{ node_id: "ab", name: "妈妈的手机", revoked: false, presence: "online" }],
            };
          case "device.watermarks":
            return { watermarks: [] };
          case "activity.list":
            return { batches: [] };
          case "audit.list":
            return { events: [] };
          case "timeline.page":
            return { items: PHOTOS, next: null };
          case "thumb.get":
            return { jpeg_base64: "" };
          default:
            throw new Error(`未预期的 method：${args.method}`);
        }
      }
      default:
        throw new Error(`未预期的 command：${cmd}`);
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

const wallCount = () => screen.queryAllByRole("button", { name: "查看大图" }).length;

describe("DESK-38：服务恢复后照片墙自动重载", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    invokeMock.mockReset();
    location.hash = "";
    globalThis.IntersectionObserver = class {
      observe() {}
      disconnect() {}
    };
    // jsdom 没有 matchMedia；svelte-sonner 的 Toaster 挂载时要它。
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

  it("停服时看过照片墙 → 回总览点「启动后台服务」→ 再进照片页，照片在", async () => {
    stoppedDesktop();
    render(App);
    await settle();

    // 停服状态下进照片页：首拉失败，墙是空的（这一步本身是对的）。
    await goto("photos");
    expect(wallCount()).toBe(0);

    await goto("overview");
    await fireEvent.click(screen.getByRole("button", { name: "启动后台服务" }));
    // startDaemonNow：3 秒一轮刷新，服务起来就停。
    await settle(3000);
    await settle();

    await goto("photos");
    await settle();
    expect(wallCount()).toBe(PHOTOS.length);
  });

  it("停在照片页上，服务被自愈/兜底轮询拉起 → 不用切页，墙自己出照片", async () => {
    const d = stoppedDesktop();
    render(App);
    await settle();
    await goto("photos");
    expect(wallCount()).toBe(0);

    // 服务在别处被拉起来（自愈、更新后恢复、托盘），窗口只靠 60s 兜底对账发现。
    d.up = true;
    await settle(60000);
    await settle();
    expect(wallCount()).toBe(PHOTOS.length);
  });

  it("停服时发出的首拉在服务恢复之后才失败回来 → 不许把墙钉成「已加载、空」", async () => {
    // 首拉 65s 后才超时；60s 兜底对账先发现服务恢复、重置了墙。
    const d = stoppedDesktop({ slowOfflineTimeline: 65000 });
    location.hash = "#/photos";
    render(App);
    await settle();
    d.up = true;
    await settle(60000); // refresh 发现恢复 → 重置墙（首拉还挂着）
    await settle(5000); // 过期的首拉失败回来
    await settle();
    expect(wallCount()).toBe(PHOTOS.length);
  });

  it("墙上已有照片时一次探活失败再恢复：只做增量对账，不清墙（缩略图 DOM 不重建）", async () => {
    const d = stoppedDesktop();
    d.up = true;
    d.userStopped = false;
    location.hash = "#/photos";
    render(App);
    await settle();
    await settle();
    expect(wallCount()).toBe(PHOTOS.length);
    const first = screen.getAllByRole("button", { name: "查看大图" })[0];

    // 大备份期间一次 status 超时 → refresh 记成离线；下一轮成功 → 「恢复」。
    d.up = false;
    await settle(60000);
    d.up = true;
    await settle(60000);
    await settle();

    expect(wallCount()).toBe(PHOTOS.length);
    expect(first.isConnected, "同一个缩略图节点必须还挂在 DOM 上").toBe(true);
  });

  it("#551：停服期间失败的缩略图，服务恢复后不切页自己重取成真图（DOM 不重建、真图不重拉）", async () => {
    // 可手动触发的 IntersectionObserver：记住所有活着的观察者，测试显式 fire。
    const observers = new Set();
    globalThis.IntersectionObserver = class {
      constructor(cb) {
        this.cb = cb;
        this.els = [];
      }
      observe(el) {
        this.els.push(el);
        observers.add(this);
      }
      disconnect() {
        observers.delete(this);
      }
    };
    const fireVisible = async () => {
      for (const o of [...observers]) {
        for (const el of o.els) o.cb([{ isIntersecting: true, target: el }]);
      }
      await settle();
    };
    const thumbCalls = (hash) =>
      invokeMock.mock.calls.filter(
        ([cmd, a]) => cmd === "daemon_call" && a.method === "thumb.get" && a.params.hash === hash,
      ).length;

    const d = stoppedDesktop();
    d.up = true;
    d.userStopped = false;
    location.hash = "#/photos";
    const { container } = render(App);
    await settle();
    await settle();
    expect(wallCount()).toBe(PHOTOS.length);
    const buttons = screen.getAllByRole("button", { name: "查看大图" });

    // h1 在线时就滚进过视口，拿到了真图。
    const firstObservers = [...observers];
    for (const o of firstObservers) {
      if (buttons[0].contains(o.els[0])) o.cb([{ isIntersecting: true, target: o.els[0] }]);
    }
    await settle();
    expect(buttons[0].querySelector("img")).not.toBeNull();
    expect(thumbCalls("h1")).toBe(1);

    // 用户停了服务，60s 兜底对账记成离线；这时 h2/h3 才进视口，thumb.get 失败 → 灰块。
    d.up = false;
    await settle(60000);
    await fireVisible();
    expect(container.querySelectorAll(".thumb-fail").length).toBe(2);
    expect(thumbCalls("h2")).toBe(1);
    // 服务没恢复之前，失败格子再进视口也不自己重试（不轮询、不自旋）。
    await fireVisible();
    await settle(5000);
    expect(thumbCalls("h2"), "离线期间不许自己重试").toBe(1);

    // 服务被拉起来，停在照片页上不切页；下一轮对账发现恢复。
    d.up = true;
    await settle(60000);
    await settle();
    await fireVisible();

    expect(container.querySelectorAll(".thumb-fail").length, "灰块必须变回真图").toBe(0);
    for (const b of buttons) {
      expect(b.isConnected, "缩略图按钮节点不许重建（DESK-38）").toBe(true);
      expect(b.querySelector("img")).not.toBeNull();
    }
    expect(thumbCalls("h2"), "失败的格子恰好重取一次").toBe(2);
    expect(thumbCalls("h3")).toBe(2);
    expect(thumbCalls("h1"), "真图是终态，不重拉（DESK-34）").toBe(1);
    const pages = invokeMock.mock.calls.filter(
      ([cmd, a]) => cmd === "daemon_call" && a.method === "timeline.page",
    );
    // 首拉 1 次 + 恢复时增量对账 1 次；墙没被重置重拉。
    expect(pages.length).toBe(2);
  });

  it("设备列表同样跟上（refresh 全量重拉，锁住不回归）", async () => {
    stoppedDesktop();
    render(App);
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "启动后台服务" }));
    await settle(3000);
    await settle();
    await goto("devices");
    expect(screen.getAllByText("妈妈的手机").length).toBeGreaterThan(0);
  });

  it("一直在线的正常启动：墙只拉一次首页，不会因为「首次探活成功」被清空重拉", async () => {
    const d = stoppedDesktop();
    d.up = true;
    d.userStopped = false;
    location.hash = "#/photos";
    render(App);
    await settle();
    await settle();
    expect(wallCount()).toBe(PHOTOS.length);
    const pages = invokeMock.mock.calls.filter(
      ([cmd, a]) => cmd === "daemon_call" && a.method === "timeline.page",
    );
    expect(pages.length).toBe(1);
  });
});
