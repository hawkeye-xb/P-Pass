// @vitest-environment jsdom
//
// #1044 B13：设置页「关于」分开列壳版本与内核（后台服务）版本；daemon 判定
// 不一致（shell_relation ≠ same）时标出来。判定本身在 daemon（ipc_flow.rs
// status_reports_the_shell_relation_from_the_shared_version_rule），这里钉渲染。
import { cleanup, render, screen } from "@testing-library/svelte";
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
vi.mock("@tauri-apps/api/app", () => ({ getVersion: async () => "0.9.5" }));
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
  openUrl: vi.fn(async () => {}),
}));

import { fireEvent } from "@testing-library/svelte";
import { openUrl } from "@tauri-apps/plugin-opener";
import App from "./App.svelte";
import { t, setLocale } from "./lib/i18n.js";
import { aboutLinks } from "./lib/aboutLinks.js";
import { daemonMethodOf } from "./lib/daemonApi.js";

/** 常驻服务正常的桌面；`relation` 是 daemon 下发的 status.shell_relation。 */
function desktop({ relation = "same", serviceVersion = "0.9.5", auditFails = false, events = [] } = {}) {
  const d = { auditFails, events };
  invokeMock.mockImplementation(async (cmd, args) => {
    switch (daemonMethodOf(cmd) ? "daemon" : cmd) {
      case "wizard_state":
        return { show_wizard: false };
      case "self_heal_daemon":
      case "notify_system":
        return null;
      case "daemon":
        switch (daemonMethodOf(cmd)) {
          case "status":
            return { version: serviceVersion, shell_relation: relation, pending_pairs: 0, photo_sources: 1 };
          case "pairing.pending":
            return { pending: [] };
          case "devices.list":
            return { devices: [] };
          case "device.watermarks":
            return { watermarks: [] };
          case "audit.list":
            if (d.auditFails) throw new Error("audit list exploded");
            return { events: d.events };
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

async function goto(page) {
  location.hash = `#/${page}`;
  window.dispatchEvent(new HashChangeEvent("hashchange"));
  await settle();
}

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


describe("#1044 设置页「关于」", () => {
  it("一致：两行版本都列出，不标不一致", async () => {
    desktop();
    render(App);
    await settle();
    await goto("settings");

    expect(screen.getByText(t("ui.about"))).toBeTruthy();
    expect(screen.getByTestId("about-shell-version").textContent).toContain("v0.9.5");
    expect(screen.getByTestId("about-service-version").textContent).toContain("v0.9.5");
    // 壳把自己的版本报给 daemon，shell_relation 才有意义。
    const statusCalls = invokeMock.mock.calls.filter(
      ([cmd, a]) => daemonMethodOf(cmd) === "status",
    );
    expect(statusCalls.map(([, a]) => a)).toContainEqual({ shell_version: "0.9.5" });
    expect(screen.queryByTestId("about-versions-differ")).toBeNull();
  });

  it("不一致：两边版本各自列出，并标出「版本不一致」", async () => {
    desktop({ relation: "shell_newer", serviceVersion: "0.9.4" });
    render(App);
    await settle();
    await goto("settings");

    expect(screen.getByTestId("about-shell-version").textContent).toContain("v0.9.5");
    expect(screen.getByTestId("about-service-version").textContent).toContain("v0.9.4");
    expect(screen.getByTestId("about-versions-differ").textContent).toBe(t("ui.about_versions_differ"));
  });
});

describe("#2065 设置页「关于」外链入口", () => {
  beforeEach(() => {
    openUrl.mockClear();
    setLocale("zh-CN");
  });

  it("中文界面渲染全部外链并标注 AGPL-3.0，点击调用 openUrl 打开中文地址与邮件/仓库", async () => {
    desktop();
    render(App);
    await settle();
    await goto("settings");

    const expected = [
      ["website", "https://p-pass.hawkeye-xb.com/zh/"],
      ["faq", "https://p-pass.hawkeye-xb.com/zh/faq/"],
      ["feedback-email", "mailto:ppass@hawkeye-xb.com"],
      ["feedback-discussions", "https://github.com/hawkeye-xb/P-Pass/discussions"],
      ["source", "https://github.com/hawkeye-xb/P-Pass"],
      ["privacy", "https://p-pass.hawkeye-xb.com/zh/privacy/"],
    ];

    expect(screen.getByTestId("about-link-source").textContent).toContain("AGPL-3.0");
    expect(screen.getByTestId("about-link-feedback-email").textContent).toContain("ppass@hawkeye-xb.com");

    for (const [id, url] of expected) {
      const btn = screen.getByTestId(`about-link-${id}`);
      expect(btn.tagName).toBe("BUTTON");
      expect(btn.getAttribute("type")).toBe("button");
      await fireEvent.click(btn);
      await settle();
      expect(openUrl).toHaveBeenLastCalledWith(url);
    }
    expect(openUrl).toHaveBeenCalledTimes(expected.length);
  });

  it("英文界面外链指向英文页并保留全套入口", async () => {
    setLocale("en-US");
    expect(aboutLinks("en-US").map((l) => l.url)).toEqual([
      "https://p-pass.hawkeye-xb.com/",
      "https://p-pass.hawkeye-xb.com/faq/",
      "mailto:ppass@hawkeye-xb.com",
      "https://github.com/hawkeye-xb/P-Pass/discussions",
      "https://github.com/hawkeye-xb/P-Pass",
      "https://p-pass.hawkeye-xb.com/privacy/",
    ]);

    desktop();
    render(App);
    await settle();
    await goto("settings");

    await fireEvent.click(screen.getByTestId("about-link-website"));
    await settle();
    expect(openUrl).toHaveBeenLastCalledWith("https://p-pass.hawkeye-xb.com/");

    await fireEvent.click(screen.getByTestId("about-link-faq"));
    await settle();
    expect(openUrl).toHaveBeenLastCalledWith("https://p-pass.hawkeye-xb.com/faq/");

    await fireEvent.click(screen.getByTestId("about-link-privacy"));
    await settle();
    expect(openUrl).toHaveBeenLastCalledWith("https://p-pass.hawkeye-xb.com/privacy/");
  });
});
