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
  openUrl: vi.fn(),
}));

import App from "./App.svelte";
import { t } from "./lib/i18n.js";

/** 常驻服务正常的桌面；`relation` 是 daemon 下发的 status.shell_relation。 */
function desktop({ relation = "same", serviceVersion = "0.9.5", auditFails = false, events = [] } = {}) {
  const d = { auditFails, events };
  invokeMock.mockImplementation(async (cmd, args) => {
    switch (cmd) {
      case "wizard_state":
        return { show_wizard: false };
      case "self_heal_daemon":
      case "notify_system":
        return null;
      case "daemon_call":
        switch (args.method) {
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
      ([cmd, a]) => cmd === "daemon_call" && a.method === "status",
    );
    expect(statusCalls.map(([, a]) => a.params)).toContainEqual({ shell_version: "0.9.5" });
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
