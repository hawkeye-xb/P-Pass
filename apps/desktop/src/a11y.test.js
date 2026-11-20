// @vitest-environment jsdom
//
// #1132 桌面无障碍（#1127 审计的 D1–D12）。两层：
//
// 1. axe 扫描（卡验收 2）：用与审计同一套规则集（wcag2a / wcag2aa /
//    wcag21aa / wcag22aa / best-practice）扫主界面五个页 + 向导两个变体
//    （含失败态）+ 打开着的配对弹窗，violation 必须为 0。color-contrast
//    在 jsdom 不可测，按卡说明排除，改由下面对比度的数学断言 + D7/D12
//    源码断言核对。挂载真的 App.svelte，daemon 由 invoke mock 扮演
//    （脚手架同 deviceCountsUi.test.js）。
//    反证：去掉某条修复（如 h1、进度条 role、弹窗 aria-label）⇒ 对应扫描红。
// 2. 逐项断言（卡验收 3）：D2/D3/D4/D5/D6/D10 各一条能判红的测试；
//    D7/D12 对比度直接算 WCAG 公式（token 值）钉下限。
//
// D9（窄窗裁切）与 E3（VoiceOver、真机键盘走查）不在 jsdom 可测范围，
// 按卡归 E3 验收。
import { cleanup, render, screen, fireEvent } from "@testing-library/svelte";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import axe from "axe-core";

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
// D4：下载/安装的编排桩——测试里直接驱动 onPhase/onProgress，不碰插件。
vi.mock("./lib/updateFlow.js", () => ({ runUpdate: vi.fn(async () => {}) }));

import App from "./App.svelte";
import Wizard from "./Wizard.svelte";
import WizardWindows from "./WizardWindows.svelte";
import { daemonMethodOf } from "./lib/daemonApi.js";
import { check as checkUpdate } from "@tauri-apps/plugin-updater";
import { runUpdate } from "./lib/updateFlow.js";
import tokens from "../../../assets/design/tokens.json";

// jsdom 环境里 vite 会把 import.meta.url 解析成 http://localhost:3000/…，
// 不能拿去定位源码文件；门禁（just done 与 CI）固定用
// `pnpm -C apps/desktop test` 跑这里，工作目录就是 apps/desktop。
const srcFile = (rel) => readFileSync(join(process.cwd(), "src", rel), "utf8");

// ---- 数据形状 ----
const NOW = 1_800_000_000_000;
const device = (ch, name, extra = {}) => ({
  node_id: ch.repeat(64),
  name,
  removal: "none",
  row_state: "idle",
  presence: "online",
  connection: "direct",
  flow_connection: null,
  last_seen: NOW - 60_000,
  last_activity_at: NOW - 60_000,
  needs_update: null,
  needs_attention: false,
  ...extra,
});
const photo = (n) => ({
  hash: `hash${n}`,
  taken_at: 1_799_000_000 + n * 60,
  media_type: "image",
});
const auditEvent = (n) => ({
  id: `e${n}`,
  ts: NOW - n * 60_000,
  kind: "pair.requested",
  actor: null,
  payload: {},
});

/** 常驻服务正常、数据齐全的桌面。 */
function daemon({ devices = [], photos = [], audit = [] } = {}) {
  invokeMock.mockImplementation(async (cmd) => {
    switch (daemonMethodOf(cmd) ? "daemon" : cmd) {
      case "wizard_state":
        return { show_wizard: false };
      case "service_state":
        return { state: "running" };
      case "is_test_build":
        return false;
      case "pending_shell_version":
        return "";
      case "update_failure_state":
        return { failed: false };
      case "kernel_convergence_phase":
        return "idle";
      case "set_tray_locale":
      case "notify_system":
      case "self_heal_daemon":
      case "power_hint":
      case "resident_hosting":
        return null;
      case "pair_qr_svg":
        return "<svg></svg>";
      case "daemon":
        switch (daemonMethodOf(cmd)) {
          case "status":
            return {
              version: "v0.6.0",
              pending_pairs: 0,
              photo_sources: photos.length,
              photo_count: photos.length,
              paired_devices: devices.filter((d) => d.removal === "none").length,
              disconnected_devices: 0,
              removed_devices: 0,
              library_dir: "/Users/demo/照片库",
              disk_free_bytes: 5_000_000_000,
              disk_total_bytes: 100_000_000_000,
              disk_encryption: "on",
            };
          case "devices.list":
            return { devices, last_backup_overall: null };
          case "device.watermarks":
            return { watermarks: [] };
          case "audit.list":
            return { events: audit };
          case "timeline.page":
            return { items: photos, next: null };
          case "pairing.pending":
            return { pending: [] };
          case "pairing.start":
            return { qr: "ppf://pair?node=aa&t=bb" };
          default:
            return {};
        }
      default:
        return null;
    }
  });
}

async function settle(ms = 0) {
  await vi.advanceTimersByTimeAsync(ms);
}

async function open(hash = "") {
  location.hash = hash;
  render(App);
  await settle();
}

// axe 与 fake timers 不合（内部 setTimeout 永远不触发会挂）：扫描期间用真钟。
// 扫 html 而不是 body：page-has-heading-one 这类页面级规则的判定点是 html，
// 扫 body 会把它们整批跳过（等于没测）。
async function scan(container = document.documentElement) {
  vi.useRealTimers();
  try {
    const res = await axe.run(container, {
      runOnly: {
        type: "tag",
        values: ["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa", "best-practice"],
      },
      rules: { "color-contrast": { enabled: false } },
    });
    return res.violations;
  } finally {
    vi.useFakeTimers();
  }
}
const fmt = (v) =>
  `${v.id}(${v.impact}): ` +
  v.nodes.slice(0, 3).map((n) => n.target.join(" ")).join(" | ");

beforeEach(() => {
  vi.useFakeTimers();
  invokeMock.mockReset();
  handlers.clear();
  location.hash = "";
  // 测试文档按真壳 index.html 补齐文档级属性（<html lang> 与 <title>），
  // 否则 axe 的 document-title / html-has-lang 会在每个扫描里误报。
  document.documentElement.lang = "zh-CN";
  document.title = "P-Pass";
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
  document.body.innerHTML = "";
  vi.useRealTimers();
});

// 向导单独渲染时补上 App 会提供的 main + h1，页面级规则才有意义。
function stage() {
  const main = document.createElement("main");
  const h1 = document.createElement("h1");
  h1.textContent = "P-Pass";
  const stage = document.createElement("div");
  main.append(h1, stage);
  document.body.appendChild(main);
  return stage;
}

// ---- 第 1 层：axe 扫描零 violation ----

describe("#1132 axe 扫描零 violation", () => {
  const RICH = {
    devices: [device("a", "客厅的手机"), device("b", "书房的平板")],
    photos: [photo(1), photo(2), photo(3)],
    audit: [auditEvent(1), auditEvent(2)],
  };

  // 设备页扫描前先点进改名态：改名输入框（D2）只有这时才在 DOM 里——
  // 不点进去，把 aria-label 拿掉 axe 也照样全绿，验收 6 的「label 必须出现」判不了红。
  const enterRename = {
    设备: async () => {
      await fireEvent.click(screen.getByRole("button", { name: "客厅的手机" }));
      await settle();
      expect(screen.getByRole("textbox", { name: "改名" })).toBeTruthy();
    },
  };

  for (const [name, hash] of [
    ["总览", "#/overview"],
    ["照片", "#/photos"],
    ["设备", "#/devices"],
    ["活动", "#/log"],
    ["设置", "#/settings"],
  ]) {
    it(`主界面·${name}页`, async () => {
      daemon(RICH);
      await open(hash);
      await settle();
      await enterRename[name]?.();
      expect((await scan()).map(fmt)).toEqual([]);
    });
  }

  it("向导·macOS·第 1 步", async () => {
    invokeMock.mockImplementation(async (cmd) => (cmd === "power_hint" ? { kind: "never" } : null));
    render(
      Wizard,
      {
        target: stage(),
        props: { defaultDir: "/Users/demo/Pictures/P-Pass", configuredLibraryDir: null, onDone: () => {} },
      },
    );
    await settle();
    expect((await scan()).map(fmt)).toEqual([]);
  });

  it("向导·macOS·第 2 步（电源已通过）", async () => {
    invokeMock.mockImplementation(async (cmd) => (cmd === "power_hint" ? { kind: "never" } : null));
    render(
      Wizard,
      {
        target: stage(),
        props: { defaultDir: "/Users/demo/Pictures/P-Pass", configuredLibraryDir: null, onDone: () => {} },
      },
    );
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "继续" }));
    await settle();
    expect((await scan()).map(fmt)).toEqual([]);
  });

  it("向导·macOS·第 3 步", async () => {
    invokeMock.mockImplementation(async (cmd) => (cmd === "power_hint" ? { kind: "never" } : null));
    render(
      Wizard,
      {
        target: stage(),
        props: { defaultDir: "/Users/demo/Pictures/P-Pass", configuredLibraryDir: null, onDone: () => {} },
      },
    );
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "继续" }));
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "继续" }));
    await settle();
    expect((await scan()).map(fmt)).toEqual([]);
  });

  it("向导·macOS·失败态（选目录报错）", async () => {
    invokeMock.mockImplementation(async (cmd) => {
      if (cmd === "pick_library_dir") throw new Error("no folder");
      return null;
    });
    render(
      Wizard,
      {
        target: stage(),
        props: { defaultDir: "/Users/demo/Pictures/P-Pass", configuredLibraryDir: null, onDone: () => {} },
      },
    );
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "更改…" }));
    await settle();
    expect(screen.getByRole("alert")).toBeTruthy();
    expect((await scan()).map(fmt)).toEqual([]);
  });

  it("向导·Windows·第 1 步", async () => {
    invokeMock.mockImplementation(async () => null);
    render(
      WizardWindows,
      {
        target: stage(),
        props: { defaultDir: "/Users/demo/Pictures/P-Pass", configuredLibraryDir: null, onDone: () => {} },
      },
    );
    await settle();
    expect((await scan()).map(fmt)).toEqual([]);
  });

  it("向导·Windows·第 3 步", async () => {
    invokeMock.mockImplementation(async () => null);
    render(
      WizardWindows,
      {
        target: stage(),
        props: { defaultDir: "/Users/demo/Pictures/P-Pass", configuredLibraryDir: null, onDone: () => {} },
      },
    );
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "继续" }));
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "继续" }));
    await settle();
    expect((await scan()).map(fmt)).toEqual([]);
  });

  it("向导·Windows·失败态（选目录报错）", async () => {
    invokeMock.mockImplementation(async (cmd) => {
      if (cmd === "pick_library_dir") throw new Error("no folder");
      return null;
    });
    render(
      WizardWindows,
      {
        target: stage(),
        props: { defaultDir: "/Users/demo/Pictures/P-Pass", configuredLibraryDir: null, onDone: () => {} },
      },
    );
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "更改…" }));
    await settle();
    expect(screen.getByRole("alert")).toBeTruthy();
    expect((await scan()).map(fmt)).toEqual([]);
  });

  it("配对二维码弹窗打开时（背景 inert、弹窗有名称）", async () => {
    daemon(RICH);
    await open("#/overview");
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "显示配对二维码" }));
    await settle();
    // CodeRabbit：先断言弹窗真的开了再扫——点按失效时总览本身仍全绿，会漏扫整个弹窗。
    expect(screen.getByRole("dialog", { name: "配对二维码" })).toBeTruthy();
    expect((await scan()).map(fmt)).toEqual([]);
  });
});

// ---- 第 2 层：逐项断言 ----

describe("#1132 逐项断言", () => {
  // D2：axe `label` critical 的根因。jsdom 没有 CSS，焦点样式走源码断言。
  it("D2 改名输入框有可访问名称，且不再吞掉焦点可见性", async () => {
    daemon({ devices: [device("a", "客厅的手机")] });
    await open("#/devices");
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "客厅的手机" }));
    await settle();
    expect(screen.getByRole("textbox", { name: "改名" })).toBeTruthy();
    const src = srcFile("App.svelte");
    const inputChunk = src.slice(src.indexOf("NAME-01: 改名输入框"), src.indexOf("{:else}", src.indexOf("NAME-01: 改名输入框")));
    expect(inputChunk).not.toContain("focus:outline-none");
  });

  // D3：axe `scrollable-region-focusable`——jsdom 测不出溢出，这里钉
  // 结构要求：滚动区自身可聚焦且有名称。
  it("D3 活动记录滚动区可聚焦、有名称", async () => {
    daemon({ audit: [auditEvent(1)] });
    await open("#/log");
    await settle();
    const region = screen.getByRole("region", { name: "活动记录" });
    expect(region.getAttribute("tabindex")).toBe("0");
  });

  // D4：下载中的进度条要有 progressbar 语义，状态行要能被听到。
  it("D4 下载进度条有 role 与数值，状态行在 live 区域里", async () => {
    daemon();
    runUpdate.mockImplementationOnce(({ onPhase, onProgress }) => {
      onPhase("downloading");
      onProgress(42);
      return new Promise(() => {});
    });
    checkUpdate.mockResolvedValueOnce({ version: "9.9.9" });
    await open("#/settings");
    await settle();
    const bar = screen.getByRole("progressbar", { name: "正在下载更新…" });
    expect(bar.getAttribute("aria-valuenow")).toBe("42");
    expect(bar.getAttribute("aria-valuemin")).toBe("0");
    expect(bar.getAttribute("aria-valuemax")).toBe("100");
    expect(bar.closest('[role="status"]')).toBeTruthy();
  });

  // D4：失败状态要能被听到（role=alert），并保留重试出口。
  it("D4 更新失败有 role=alert 与重试", async () => {
    daemon();
    checkUpdate.mockResolvedValueOnce({ version: "9.9.9" });
    runUpdate.mockImplementationOnce(async () => {
      throw new Error("download failed");
    });
    await open("#/settings");
    await settle();
    expect(screen.getByRole("alert").textContent).toContain("更新");
    expect(screen.getByRole("button", { name: "重试" })).toBeTruthy();
  });

  // CodeRabbit（ARIA22）：live region 要先挂载、后写内容——点「检查更新」时
  // 区域和首条消息同时插入，读屏可能不播报首条；区域常驻（空闲时零高度）才补得上。
  // CodeRabbit：App 挂载即自动检查更新（onMount → refresh → checkForUpdate(false)），
  // 桩立即返回 null 会把 updatePhase 推过 idle——把状态行改回条件挂载，本用例
  // 照样绿，判不了「先挂载、后写内容」。按住首轮 refresh 的 status（daemon_status）：
  // 检查还没开始，区域必须已挂载且为空；放行后断言同一节点收到状态文本。
  // 反证：状态行改回 `{#if updatePhase !== "idle"}` 条件挂载 ⇒ 本条红（按住期间区域缺席）。
  it("D4 更新状态区域在自动检查开始前就已挂载，同一节点随后收到状态", async () => {
    daemon();
    let release;
    const gate = new Promise((r) => (release = r));
    const base = invokeMock.getMockImplementation();
    invokeMock.mockImplementation(async (cmd, args) => {
      if (daemonMethodOf(cmd) === "status") return gate.then(() => base(cmd, args));
      return base(cmd, args);
    });
    await open("#/settings");
    await settle();
    // 侧栏服务胶囊也是 role=status，按 testid 定位更新状态区。
    const region = document.querySelector('[data-testid="update-status"]');
    expect(region?.getAttribute("role")).toBe("status");
    // 检查还没开始（updatePhase 仍是 idle）：区域已挂载但没有内容可播报。
    expect(region?.textContent.trim()).toBe("");
    release();
    await settle();
    // ARIA22：写内容的是同一个常驻节点，不是先挂载后替换。
    expect(document.querySelector('[data-testid="update-status"]')).toBe(region);
    expect(region.textContent).toContain("已是最新");
  });

  // D5：切步后焦点掉到 BODY 是卡上原发现。
  it("D5 macOS 向导：切步焦点落在新步骤标题，当前步有 aria-current", async () => {
    invokeMock.mockImplementation(async (cmd) => (cmd === "power_hint" ? { kind: "never" } : null));
    render(
      Wizard,
      {
        target: stage(),
        props: { defaultDir: "/Users/demo/Pictures/P-Pass", configuredLibraryDir: null, onDone: () => {} },
      },
    );
    await settle();
    expect(document.querySelector('[aria-current="step"]').textContent).toContain("1");
    await fireEvent.click(screen.getByRole("button", { name: "继续" }));
    await settle();
    expect(document.activeElement?.tagName).toBe("H2");
    expect(document.querySelector('[aria-current="step"]').textContent).toContain("2");
  });

  it("D5 Windows 向导：切步焦点落在新步骤标题，当前步有 aria-current", async () => {
    invokeMock.mockImplementation(async () => null);
    render(
      WizardWindows,
      {
        target: stage(),
        props: { defaultDir: "/Users/demo/Pictures/P-Pass", configuredLibraryDir: null, onDone: () => {} },
      },
    );
    await settle();
    await fireEvent.click(screen.getByRole("button", { name: "继续" }));
    await settle();
    expect(document.activeElement?.tagName).toBe("H2");
    expect(document.querySelector('[aria-current="step"]').textContent).toContain("2");
  });

  // D6：按钮名重复 ×40 的根因；大图 alt="" 的根因。照片给两张同一分钟的
  // （连拍）——名称唯一只能靠序号兜住，不能靠拍摄时间错开（CodeRabbit）。
  it("D6 缩略图名称各不相同（同一分钟连拍也如此），大图 alt 非空", async () => {
    daemon({
      photos: [photo(1), photo(2), { ...photo(3), taken_at: photo(2).taken_at }],
    });
    await open("#/photos");
    await settle();
    const thumbs = screen.getAllByRole("button", { name: /查看大图/ });
    expect(thumbs.length).toBe(3);
    const names = thumbs.map((b) => b.getAttribute("aria-label"));
    expect(new Set(names).size).toBe(3);
    await fireEvent.click(thumbs[0]);
    await settle();
    const img = screen.getByRole("img", { name: /查看大图/ });
    expect((img.getAttribute("alt") || "").length).toBeGreaterThan(0);
  });

  // D10：三行「移除」完全同名的根因。
  it("D10 移除按钮名称带设备名", async () => {
    daemon({ devices: [device("a", "客厅的手机"), device("b", "书房的平板")] });
    await open("#/devices");
    await settle();
    const removes = screen.getAllByRole("button", { name: /^移除/ });
    expect(removes.length).toBe(2);
    const names = removes.map((b) => b.getAttribute("aria-label"));
    expect(names).toContain("移除 客厅的手机");
    expect(names).toContain("移除 书房的平板");
    expect(new Set(names).size).toBe(2);
  });

  // D9 / #1924：200% 缩放与窄窗重排（WCAG 1.4.10）——设备行 flex-wrap 下，
  // 名称容器原先只带 flex-1 min-w-0（flex-basis: 0%），中间宽度下不触发
  // 换行反而被压到 ~24px，内部 whitespace-nowrap 按钮横向溢出盖住右侧 #ID。
  // 反证：把名称容器改回 flex-1 min-w-0 或去掉按钮的 max-w-full / 文字截断 ⇒ 本条红。
  it("D9 设备行名称列有最小宽度保护且名称按钮/改名框不会溢出盖住 #ID", async () => {
    daemon({ devices: [device("a", "Galaxy S24 Ultra")] });
    await open("#/devices");
    await settle();

    const nameBtn = screen.getByRole("button", { name: "Galaxy S24 Ultra" });
    const row = nameBtn.closest("li");
    expect(row).toBeTruthy();
    const rowClasses = (row.getAttribute("class") || "").split(/\s+/);
    expect(rowClasses).toContain("flex-wrap");

    // 名称容器必须带非零最小宽度与 basis 保护，迫使右侧固定列在放不下时折行，
    // 不能再退回 min-w-0 + flex-basis:0% 被挤到几十像素。
    const nameCol = nameBtn.parentElement;
    const colClasses = (nameCol.getAttribute("class") || "").split(/\s+/);
    expect(colClasses).toContain("flex-1");
    expect(colClasses).not.toContain("min-w-0");
    expect(colClasses.some((c) => /^min-w-\[/.test(c))).toBe(true);
    expect(colClasses.some((c) => /^basis-\[/.test(c))).toBe(true);

    // 按钮自身受容器宽度约束，文字由内部 truncate 截断（不把 overflow-hidden 放父级，
    // 避免裁掉按钮外圈 focus-visible:ring-3）。
    const btnClasses = (nameBtn.getAttribute("class") || "").split(/\s+/);
    expect(btnClasses).toContain("max-w-full");
    expect(btnClasses).toContain("min-w-0");
    const labelSpan = nameBtn.querySelector("span");
    expect(labelSpan).toBeTruthy();
    expect((labelSpan.getAttribute("class") || "").split(/\s+/)).toContain("truncate");
    expect(labelSpan.textContent).toBe("Galaxy S24 Ultra");

    // 点击进入改名态：输入框同样受名称列宽度约束（w-full + max-w-[260px]），不压过 #ID。
    await fireEvent.click(nameBtn);
    await settle();
    const input = screen.getByRole("textbox", { name: "改名" });
    const inputClasses = (input.getAttribute("class") || "").split(/\s+/);
    expect(inputClasses).toContain("w-full");
    expect(inputClasses).toContain("max-w-[260px]");
  });

  // CodeRabbit（Major）：大图查看器开着时来了配对申请——确认弹窗自动打开，
  // 但两个遮罩同 z-50，查看器还盖在上面又被 inert，用户看到的是一层点不动的
  // 查看器，可操作的确认弹窗反而在底下。修法：确认弹窗打开时把查看器关掉。
  // 反证：去掉 showConfirmModal = true 旁的 photoViewer = null ⇒ 本条红。
  it("配对申请到达时关掉开着的照片查看器，确认弹窗独占最上层", async () => {
    daemon({ photos: [photo(1)] });
    await open("#/photos");
    await settle();
    await fireEvent.click(screen.getAllByRole("button", { name: /查看大图/ })[0]);
    await settle();
    expect(screen.queryByRole("dialog", { name: /查看大图/ })).toBeTruthy();
    // daemon 队列里出现一条申请（事件触发 refresh，重拉 pairing.pending 后自动弹确认框）。
    const base = invokeMock.getMockImplementation();
    invokeMock.mockImplementation(async (cmd, args) => {
      if (daemonMethodOf(cmd) === "pairing.pending") {
        return {
          pending: [
            { node_id: "cc".repeat(64), known: false, name: "客厅的 iPhone", requested_at: NOW, expired: false },
          ],
        };
      }
      return base(cmd, args);
    });
    handlers.get("daemon-event")?.({ payload: { event: "pairing.pending_changed", data: {} } });
    await settle();
    expect(screen.queryByRole("dialog", { name: /查看大图/ })).toBeNull();
    const confirmPanel = screen.getByRole("dialog", { name: "客厅的 iPhone 请求加入" });
    // 独立评审阻断：查看器关、确认弹窗开落在同一轮更新里，交接后焦点必须在
    // 确认弹窗内、背景（main / 侧栏）仍带 inert——查看器的清理不得摘掉确认
    // 弹窗要用的 inert，也不得把焦点抢回缩略图（dialog.svelte 按栈接管）。
    // 反证：dialog.svelte 改回「标记时跳过已 inert 的兄弟 + 清理时无条件摘光、
    // 无条件回触发元素」⇒ 本条红（背景失去 inert、焦点落在弹窗外）。
    expect(confirmPanel.contains(document.activeElement)).toBe(true);
    expect(document.activeElement).not.toBe(document.body);
    expect(document.querySelector("main.content")?.hasAttribute("inert")).toBe(true);
    expect(document.querySelector("aside.sidebar")?.hasAttribute("inert")).toBe(true);
  });
});

// ---- D7 / D12：WCAG 公式直接算 token 对（color-contrast 在 jsdom 不可测的替代）----

function contrast(fgHex, bgHex) {
  const lum = (hex) => {
    const c = [0, 2, 4].map((i) => parseInt(hex.slice(i + 1, i + 3), 16) / 255);
    const [r, g, b] = c.map((s) =>
      s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4,
    );
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const [l1, l2] = [lum(fgHex), lum(bgHex)].sort((a, b) => b - a);
  return (l1 + 0.05) / (l2 + 0.05);
}

describe("#1132 对比度（D7 / D12）", () => {
  const value = (k) => tokens.color[k].value.replace(/#([0-9a-f]{6})[0-9a-f]{2}?/i, "#$1");

  // D7：版本号小字（11px）——去掉 opacity:0.8 后 ink-40 直接落纸底。
  it("D7 ink-40 on paper ≥ 4.5:1（去掉半透明后的小字下限）", () => {
    expect(contrast(value("ink-40"), value("paper"))).toBeGreaterThanOrEqual(4.5);
    // 修复本身：源码里 .version-footer 不再压透明度。
    const src = srcFile("App.svelte");
    const footer = src.slice(src.indexOf(".version-footer"), src.indexOf(".env-badge"));
    expect(footer).not.toContain("opacity");
  });

  // D12：焦点环从 ring/50（3.40:1，刚过线没余量）改成 ring 全量。
  it("D12 焦点环 ink on paper ≥ 3:1，且不再用 50% 透明", () => {
    expect(contrast(value("ink"), value("paper"))).toBeGreaterThanOrEqual(3);
    for (const f of [
      "lib/components/ui/button/button.svelte",
      "lib/components/ui/input/input.svelte",
      "lib/components/ui/dialog/dialog.svelte",
    ]) {
      const src = srcFile(f);
      expect(src).not.toContain("ring-ring/50");
      // CodeRabbit：宽度和颜色都钉住——只查颜色类时，整个 focus-visible:ring-3
      // 被删掉这条测试不红。反证：删掉任一文件的 focus-visible:ring-3 ⇒ 本条红。
      expect(src).toContain("focus-visible:ring-3");
      expect(src).toContain("focus-visible:ring-ring");
    }
  });

  // D7 同类（CodeRabbit）：向导/设备/活动/设置的错误码行也是 12px 半透明小字
  // ——act 压 80% 后纸底 4.03:1、act-bg 上 3.56:1，都低于 4.5。同 D7 口径：
  // 去掉半透明，act 直接落底（纸底 5.70:1、act-bg 4.86:1）。
  // CodeRabbit：按独立的类名 token 检查，不依赖类名顺序——旧断言只认
  // 「text-[12px] opacity-80」这个固定子串，写成 `opacity-80 text-[12px]` 就漏。
  // 逐个 class 属性看：凡带 text-[12px] 的元素不得再压任何透明度（12px 小字一律全量色）。
  // 反证：往任一 12px 元素的 class 里加回 opacity-80（顺序不限）⇒ 本条红。
  it("D7 同类：错误码行不再压透明度，act 在纸底 / act-bg ≥ 4.5:1", () => {
    expect(contrast(value("act"), value("paper"))).toBeGreaterThanOrEqual(4.5);
    expect(contrast(value("act"), value("act-bg"))).toBeGreaterThanOrEqual(4.5);
    for (const f of ["App.svelte", "Wizard.svelte", "WizardWindows.svelte"]) {
      for (const m of srcFile(f).matchAll(/class="([^"]*)"/g)) {
        const cls = m[1].split(/\s+/);
        expect(
          cls.includes("text-[12px]") && cls.some((c) => /^opacity-/.test(c)),
          `${f}: 12px 小字压了透明度「${m[1]}」`,
        ).toBe(false);
      }
    }
  });
});
