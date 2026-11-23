#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(pwd)"
COMMON_GIT="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
MAIN_ROOT="$(dirname "$COMMON_GIT")"

CREATED_NM=0
TMP_TEST="$REPO_ROOT/apps/desktop/src/__v3_exam_1875_tmp.test.js"

cleanup() {
  rm -f "$TMP_TEST"
  if [ "$CREATED_NM" -eq 1 ] && [ -L "$REPO_ROOT/apps/desktop/node_modules" ]; then
    rm -f "$REPO_ROOT/apps/desktop/node_modules"
  fi
}
trap cleanup EXIT

if [ ! -e "$REPO_ROOT/apps/desktop/node_modules" ] && [ -d "$MAIN_ROOT/apps/desktop/node_modules" ]; then
  ln -s "$MAIN_ROOT/apps/desktop/node_modules" "$REPO_ROOT/apps/desktop/node_modules"
  CREATED_NM=1
fi

cat >"$TMP_TEST" <<'EOF'
// @vitest-environment jsdom
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

vi.mock("@tauri-apps/api/core", () => ({ invoke: invokeMock, convertFileSrc: (p) => p }));
vi.mock("@tauri-apps/api/app", () => ({ getVersion: async () => "0.12.0" }));
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
vi.mock("@tauri-apps/plugin-opener", () => ({ revealItemInDir: vi.fn(), openUrl: vi.fn() }));

import App from "./App.svelte";
import { daemonMethodOf } from "./lib/daemonApi.js";

const row = (hexByte, name) => ({
  node_id: hexByte.repeat(64),
  known: false,
  name,
  requested_at: 1_790_000_000_000,
  expired: false,
});

function isInert(el) {
  let cur = el;
  while (cur) {
    if (cur.inert === true || (cur.hasAttribute && cur.hasAttribute("inert"))) return true;
    cur = cur.parentElement;
  }
  return false;
}

function setupDesktop() {
  const d = { pending: [], confirmThrow: null, dropOnThrow: false };
  invokeMock.mockImplementation(async (cmd, args) => {
    if (cmd === "restart_daemon_process") return { status: "restarted" };
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
            return { version: "v0.12.0", pending_pairs: d.pending.length, photo_sources: 1 };
          case "pairing.pending":
            return { pending: d.pending };
          case "pairing.start":
            return { qr: "ppf://pair?node=aa&t=bb" };
          case "pairing.confirm":
            if (d.confirmThrow) {
              if (d.dropOnThrow) {
                d.pending = d.pending.filter((p) => p.node_id !== args?.node_id);
                handlers.get("daemon-event")?.({ payload: { event: "pairing.pending_changed", data: {} } });
                await vi.advanceTimersByTimeAsync(0);
              }
              throw d.confirmThrow;
            }
            return { decided: true };
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

describe("#1875 配对确认弹窗非验证码失败无障碍播报与恢复操作", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    invokeMock.mockReset();
    handlers.clear();
    location.hash = "";
    globalThis.IntersectionObserver = class { observe() {} disconnect() {} };
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

  it("后台不可达时在非 inert 的弹窗内用 role=alert 播报并提供可点击的「重启后台服务」按钮，背景保持 inert", async () => {
    const d = setupDesktop();
    render(App);
    await vi.advanceTimersByTimeAsync(0);

    d.pending = [row("a", "妈妈的手机")];
    handlers.get("daemon-event")?.({ payload: { event: "pairing.pending_changed", data: {} } });
    await vi.advanceTimersByTimeAsync(0);

    d.confirmThrow = JSON.stringify({
      key: "ui.err_connect",
      params: { err: "Connection refused", path: "/tmp/ppf.sock", method: "pairing.confirm" },
    });
    await fireEvent.input(screen.getByTestId("pair-code-input"), { target: { value: "123456" } });
    await fireEvent.click(screen.getByRole("button", { name: "允许加入" }));
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(0);

    // 背景仍存在 inert 锁定
    expect(document.querySelectorAll("[inert]").length).toBeGreaterThan(0);

    // 弹窗内必须有未处于 inert 树下的 role="alert" 且包含错误代码 connect
    const liveAlerts = Array.from(document.querySelectorAll('[role="alert"]')).filter((el) => !isInert(el));
    expect(liveAlerts.length).toBeGreaterThan(0);
    expect(liveAlerts.map((el) => el.textContent).join(" ")).toContain("connect");

    // 弹窗内必须有未处于 inert 树下的「重启后台服务」按钮且键盘/点击可触发 restart_daemon_process
    const restartBtns = screen
      .queryAllByRole("button", { name: /重启后台服务/ })
      .filter((btn) => !isInert(btn) && !btn.disabled);
    expect(restartBtns.length).toBeGreaterThan(0);

    await fireEvent.click(restartBtns[0]);
    await vi.advanceTimersByTimeAsync(0);
    expect(invokeMock.mock.calls.some(([cmd]) => cmd === "restart_daemon_process")).toBe(true);
  });

  it("验证码错误仍保持 failed 终态与「重新显示二维码」不回归", async () => {
    const d = setupDesktop();
    render(App);
    await vi.advanceTimersByTimeAsync(0);

    d.pending = [row("b", "爸爸的手机")];
    handlers.get("daemon-event")?.({ payload: { event: "pairing.pending_changed", data: {} } });
    await vi.advanceTimersByTimeAsync(0);

    d.confirmThrow = JSON.stringify({ key: "ui.err_pair_code_wrong", params: {} });
    d.dropOnThrow = true;
    await fireEvent.input(screen.getByTestId("pair-code-input"), { target: { value: "654321" } });
    await fireEvent.click(screen.getByRole("button", { name: "允许加入" }));
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(0);

    expect(screen.getByTestId("pending-request").dataset.phase).toBe("failed");
    expect(screen.getByRole("button", { name: "重新显示二维码" })).toBeTruthy();
  });
});
EOF

if [ ! -x "$REPO_ROOT/apps/desktop/node_modules/.bin/vitest" ]; then
  pnpm -C "$REPO_ROOT/apps/desktop" install --frozen-lockfile
fi
(cd "$REPO_ROOT/apps/desktop" && ./node_modules/.bin/vitest run src/__v3_exam_1875_tmp.test.js)
