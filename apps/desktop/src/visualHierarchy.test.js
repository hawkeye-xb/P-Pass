// @vitest-environment jsdom
//
// #2083 + #2084 桌面端视觉层级、可点性、降噪与向导焦点真实 DOM 行为回归：
// 挂载真实 NavItem / App / Wizard / WizardWindows 组件，断言渲染 class、
// 无障碍名、tooltip、焦点目标与 #2079 先断开再移除分支均按规范生效。
import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import HouseIcon from "@lucide/svelte/icons/house";

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
vi.mock("./lib/updateFlow.js", () => ({ runUpdate: vi.fn(async () => {}) }));

import { open as openDialog, confirm as confirmDialog } from "@tauri-apps/plugin-dialog";
import { check as checkUpdate } from "@tauri-apps/plugin-updater";
import { openUrl } from "@tauri-apps/plugin-opener";
import App from "./App.svelte";
import Wizard from "./Wizard.svelte";
import WizardWindows from "./WizardWindows.svelte";
import { NavItem } from "$lib/components/ui/nav-item";
import { daemonMethodOf } from "./lib/daemonApi.js";

const NOW = 1_800_000_000_000;

function makeDevice(ch, name, extra = {}) {
  return {
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
  };
}

function setupDaemon({ devices = [], photos = [], audit = [], testBuild = false } = {}) {
  invokeMock.mockImplementation(async (cmd) => {
    switch (daemonMethodOf(cmd) ? "daemon" : cmd) {
      case "wizard_state":
        return { show_wizard: false };
      case "service_state":
        return { state: "running" };
      case "is_test_build":
        return testBuild;
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
              disconnected_devices: devices.filter((d) => d.removal === "disconnected").length,
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

function tokensOf(el) {
  return new Set((el.getAttribute("class") || "").split(/\s+/).filter(Boolean));
}

async function openApp(hash = "") {
  location.hash = hash;
  render(App);
  await vi.advanceTimersByTimeAsync(0);
}

describe("#2083 + #2084 桌面端视觉权重、降噪、可点性与向导焦点", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    location.hash = "";
    localStorage.clear();
    localStorage.setItem("ppass.locale", "zh");
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
    invokeMock.mockReset();
    handlers.clear();
  });

  it("#2092 NavItem 选中态保留浅底、描边与加粗，不再渲染左侧竖条", () => {
    render(NavItem, { icon: HouseIcon, label: "总览", active: true });
    render(NavItem, { icon: HouseIcon, label: "照片", active: false });

    const activeBtn = screen.getByRole("button", { name: "总览" });
    const activeTokens = tokensOf(activeBtn);
    expect(activeBtn.getAttribute("aria-current")).toBe("page");
    expect(activeTokens.has("data-[active=true]:bg-paper")).toBe(true);
    expect(activeTokens.has("data-[active=true]:text-ink")).toBe(true);
    expect(activeTokens.has("data-[active=true]:font-semibold")).toBe(true);
    expect(activeTokens.has("data-[active=true]:shadow-[inset_0_0_0_1px_var(--color-border)]")).toBe(true);
    expect(activeTokens.has("max-[1079px]:data-[active=true]:shadow-[inset_0_0_0_1px_var(--color-border-strong)]")).toBe(true);
    expect(Array.from(activeTokens).some((c) => c.includes("before:"))).toBe(false);
    expect(activeTokens.has("focus-visible:ring-3")).toBe(true);

    const idleBtn = screen.getByRole("button", { name: "照片" });
    expect(idleBtn.getAttribute("aria-current")).toBeNull();
    expect(tokensOf(idleBtn).has("data-[active=false]:hover:bg-hairline/60")).toBe(true);
  });

  it("#2092 总览 0 台态突出添加第一台设备卡并附手机端下载引导，隐藏空状态与活动区", async () => {
    setupDaemon({ devices: [] });
    openUrl.mockClear();
    await openApp("#/overview");

    expect(screen.queryByTestId("overview-summary-strip")).toBeNull();
    expect(screen.queryByTestId("overview-grid")).toBeNull();
    expect(screen.queryByTestId("overview-backup-card")).toBeNull();
    expect(screen.queryByTestId("overview-activity-card")).toBeNull();

    const emptyCard = screen.getByTestId("overview-empty-add");
    expect(emptyCard.textContent).toContain("添加第一台设备");
    const qrPrimaryBtn = screen.getByRole("button", { name: "显示配对二维码" });
    expect(tokensOf(qrPrimaryBtn).has("bg-primary")).toBe(true);
    expect(screen.getByRole("button", { name: "无法扫码？复制配对码" })).toBeTruthy();

    const dlLink = screen.getByTestId("mobile-download-empty");
    expect(dlLink.textContent).toContain("还没装手机端？前往官网下载");
    await fireEvent.click(dlLink);
    await vi.advanceTimersByTimeAsync(0);
    expect(openUrl).toHaveBeenCalledWith("https://p-pass.hawkeye-xb.com");
  });

  it("#2092 总览日常态呈现 3 层视觉金字塔、摘要跳转、安静时间线与动态条数伸缩", async () => {
    let roCallback = null;
    const origRO = globalThis.ResizeObserver;
    globalThis.ResizeObserver = class {
      constructor(cb) {
        roCallback = cb;
      }
      observe() {}
      disconnect() {}
    };

    try {
      const devs = Array.from({ length: 5 }, (_, i) =>
        makeDevice(String.fromCharCode(97 + i), `设备${i + 1}`, {
          last_activity_at: NOW - i * 10_000,
          ...(i === 0 ? { row_state: "needs_attention", needs_attention: true } : {}),
        }),
      );
      const events = Array.from({ length: 8 }, (_, i) => ({
        id: `e${i}`,
        ts: NOW - (i + 1) * 60_000,
        kind: "pair.accepted",
        actor: "a".repeat(64),
        payload: {},
      }));

      setupDaemon({ devices: devs, audit: events });
      await openApp("#/overview");

      // 顶层：Hero 标题 + 右上角次级「添加设备」按钮 + 3 项摘要带
      const addBtn = screen.getByRole("button", { name: "添加设备" });
      expect(tokensOf(addBtn).has("bg-primary")).toBe(false);
      expect(tokensOf(addBtn).has("border-border-strong")).toBe(true);

      const strip = screen.getByTestId("overview-summary-strip");
      expect(strip.closest('[data-slot="card"]')).toBeNull();
      expect(strip.textContent).toContain("已配对设备 5 台");
      expect(strip.textContent).toContain("磁盘可用");
      const healthBtn = screen.getByTestId("overview-health-btn");
      expect(healthBtn.textContent).toContain("1 台设备需关注");

      // 高度较小（矮窗）：ResizeObserver 推入窄高内容区，设备与活动条数同步收紧
      roCallback?.([{ contentRect: { width: 900, height: 420 } }]);
      await vi.advanceTimersByTimeAsync(0);
      const backupCard = screen.getByTestId("overview-backup-card");
      const activityCard = screen.getByTestId("overview-activity-card");
      expect(backupCard.querySelectorAll("ul li")).toHaveLength(1);
      expect(activityCard.querySelectorAll("ul li")).toHaveLength(2);

      // 高度变大（高窗）：动态展开更多设备与活动动态，不锁死 3 条
      roCallback?.([{ contentRect: { width: 900, height: 860 } }]);
      await vi.advanceTimersByTimeAsync(0);
      expect(backupCard.querySelectorAll("ul li")).toHaveLength(5);
      expect(activityCard.querySelectorAll("ul li")).toHaveLength(8);

      // 底层安静时间线：不套白卡边框、不用 <b> 加粗、底端保留「查看全部 ›」
      expect(activityCard.closest('[data-slot="card"]')).toBeNull();
      expect(activityCard.querySelector("ul b")).toBeNull();
      expect(screen.getByRole("button", { name: /查看全部/ })).toBeTruthy();

      // 备份状态设备行显示次行并可点击直达设备页
      const firstDeviceRow = backupCard.querySelector("ul li button");
      expect(firstDeviceRow?.textContent).toContain("设备1");
      expect(firstDeviceRow?.textContent).toContain("未备份");
      await fireEvent.click(firstDeviceRow);
      await vi.advanceTimersByTimeAsync(0);
      expect(screen.getByTestId("page-devices")).toBeTruthy();

      // 切回总览，点击摘要带「1 台设备需关注」直达设备页
      await fireEvent.click(screen.getByRole("button", { name: "总览" }));
      await vi.advanceTimersByTimeAsync(0);
      await fireEvent.click(screen.getByTestId("overview-health-btn"));
      await vi.advanceTimersByTimeAsync(0);
      expect(screen.getByTestId("page-devices")).toBeTruthy();
    } finally {
      globalThis.ResizeObserver = origRO;
    }
  });

  it("#2092 总览无异常设备时摘要带显示绿点「一切正常」", async () => {
    setupDaemon({ devices: [makeDevice("a", "客厅的手机")] });
    await openApp("#/overview");

    const strip = screen.getByTestId("overview-summary-strip");
    expect(strip.textContent).toContain("一切正常");
    expect(screen.queryByTestId("overview-health-btn")).toBeNull();
    expect(strip.querySelector(".bg-safe")).toBeTruthy();
  });

  it("#2092 二维码弹窗删去 desktop-name 行、统一间距顺序并含官网下载引导", async () => {
    setupDaemon({ devices: [makeDevice("a", "客厅的手机")] });
    openUrl.mockClear();
    await openApp("#/overview");
    await fireEvent.click(screen.getByRole("button", { name: "添加设备" }));
    await vi.advanceTimersByTimeAsync(0);

    const qrDialog = screen.getByRole("dialog", { name: "配对二维码" });
    const dialogTokens = tokensOf(qrDialog);
    expect(dialogTokens.has("flex-col")).toBe(true);
    expect(dialogTokens.has("gap-[14px]")).toBe(true);
    expect(screen.queryByTestId("desktop-name")).toBeNull();
    const dialogChildTags = Array.from(qrDialog.children).map((el) => el.tagName);
    expect(dialogChildTags).toEqual(["H3", "IMG", "P", "DIV", "BUTTON", "BUTTON"]);

    const closeBtn = screen.getByRole("button", { name: "关闭" });
    const closeTokens = tokensOf(closeBtn);
    expect(closeTokens.has("bg-primary")).toBe(false);
    expect(closeTokens.has("border-border-strong")).toBe(true);

    const dlModalBtn = screen.getByTestId("mobile-download-modal");
    expect(dlModalBtn.textContent).toContain("还没装手机端？前往官网下载");
    await fireEvent.click(dlModalBtn);
    await vi.advanceTimersByTimeAsync(0);
    expect(openUrl).toHaveBeenCalledWith("https://p-pass.hawkeye-xb.com");
  });

  it("#2092 设置页删除角落版本号、版本行上移至检查更新前、行高紧凑且全部交互无回归", async () => {
    setupDaemon({ devices: [makeDevice("a", "客厅的手机")], testBuild: true });
    openUrl.mockClear();
    confirmDialog.mockClear();
    openDialog.mockResolvedValueOnce(null);
    await openApp("#/settings");

    // 角落版本号已彻底删除
    expect(document.querySelector(".version-footer")).toBeNull();
    expect(document.querySelector("footer")).toBeNull();

    const layers = screen.getByTestId("settings-layers");
    expect(tokensOf(layers).has("settings-grid")).toBe(true);
    const primaryCol = screen.getByTestId("settings-primary-col");
    expect(primaryCol.children[0].getAttribute("data-testid")).toBe("settings-library-card");
    expect(primaryCol.children[1].getAttribute("data-testid")).toBe("settings-danger-zone");
    expect(layers.children[1].getAttribute("data-testid")).toBe("about-card");

    // ① 核心区：路径、磁盘水位、打开/搬迁交互
    const libCard = screen.getByTestId("settings-library-card");
    expect(libCard.textContent).toContain("/Users/demo/照片库");
    expect(screen.getByRole("progressbar", { name: "磁盘空间" }).getAttribute("aria-valuenow")).toBe("95");
    await fireEvent.click(screen.getByRole("button", { name: "打开照片库" }));
    await vi.advanceTimersByTimeAsync(0);
    expect(invokeMock).toHaveBeenCalledWith("reveal_library");
    await fireEvent.click(screen.getByTestId("change-library"));
    await vi.advanceTimersByTimeAsync(0);
    expect(invokeMock).toHaveBeenCalledWith("pick_library_dir", {
      fromDefault: false,
      title: "更改照片库位置",
    });

    // ② 常规与支持：壳版本（含测试版徽标）与服务版本在软件更新上方，检查更新按钮紧凑
    const aboutCard = screen.getByTestId("about-card");
    const shellRow = screen.getByTestId("about-shell-version");
    expect(shellRow.textContent).toContain("v0.6.0");
    expect(screen.getByTestId("about-test-build").textContent).toBe("测试版");
    const serviceRow = screen.getByTestId("about-service-version");
    expect(serviceRow.textContent).toContain("v0.6.0");

    const checkBtn = screen.getByRole("button", { name: "检查更新" });
    expect(tokensOf(checkBtn).has("h-[30px]")).toBe(true);
    expect(tokensOf(checkBtn).has("min-h-[30px]")).toBe(true);

    // 确认 DOM 顺序：壳版本 → 服务版本 → 检查更新 → 外链
    const cardChildren = Array.from(aboutCard.children);
    const shellIdx = cardChildren.findIndex((el) => el.contains(shellRow));
    const serviceIdx = cardChildren.findIndex((el) => el.contains(serviceRow));
    const updateIdx = cardChildren.findIndex((el) => el.contains(checkBtn));
    const linkIdx = cardChildren.findIndex((el) => el.getAttribute("data-testid") === "about-link-website");
    expect(shellIdx).toBeLessThan(serviceIdx);
    expect(serviceIdx).toBeLessThan(updateIdx);
    expect(updateIdx).toBeLessThan(linkIdx);

    // 先清空挂载期自动检查记录，再点击「检查更新」，确保只测点击本身
    checkUpdate.mockClear();
    await fireEvent.click(checkBtn);
    await vi.advanceTimersByTimeAsync(0);
    expect(checkUpdate).toHaveBeenCalledTimes(1);

    await fireEvent.click(screen.getByTestId("about-link-website"));
    await vi.advanceTimersByTimeAsync(0);
    expect(openUrl).toHaveBeenCalledWith("https://p-pass.hawkeye-xb.com/zh/");

    // ③ 危险区：紧凑横排（左标题与后果 + 右红色危险按钮），容器保持中性纸卡
    const dangerZone = screen.getByTestId("settings-danger-zone");
    const dangerTokens = tokensOf(dangerZone);
    expect(dangerTokens.has("flex-row")).toBe(true);
    expect(dangerTokens.has("justify-between")).toBe(true);
    expect(dangerTokens.has("border-act")).toBe(false);
    expect(dangerTokens.has("bg-act-bg")).toBe(false);
    const stopHeading = screen.getByRole("heading", { name: "停止后台服务" });
    expect(tokensOf(stopHeading).has("text-ink")).toBe(true);
    expect(tokensOf(stopHeading).has("text-act")).toBe(false);
    expect(dangerZone.textContent).toContain("停止后备份暂停");
    const stopBtn = screen.getByRole("button", { name: "停止后台服务" });
    expect(tokensOf(stopBtn).has("text-act")).toBe(true);
    await fireEvent.click(stopBtn);
    await vi.advanceTimersByTimeAsync(0);
    expect(confirmDialog).toHaveBeenCalled();
    expect(invokeMock).toHaveBeenCalledWith("stop_daemon");
  });

  it("#2084 + #2079 设备页显示改名铅笔提示、文件夹文字按钮，并保留已配对「断开」/已断开「移除」的柔和危险权重", async () => {
    setupDaemon({
      devices: [
        makeDevice("a", "客厅的手机", { removal: "none" }),
        makeDevice("b", "卧室的手机", { removal: "disconnected" }),
      ],
    });
    await openApp("#/devices");

    // 改名按钮保持精确可访问名，同时内含 aria-hidden 铅笔图标与 group 悬停联动
    const renameBtn = screen.getByRole("button", { name: "客厅的手机" });
    expect(tokensOf(renameBtn).has("group")).toBe(true);
    expect(tokensOf(renameBtn).has("no-underline")).toBe(true);
    expect(tokensOf(renameBtn).has("hover:underline")).toBe(true);
    const pencilSvg = renameBtn.querySelector("svg");
    expect(pencilSvg).toBeTruthy();
    expect(pencilSvg.getAttribute("aria-hidden")).toBe("true");
    expect(tokensOf(pencilSvg).has("size-[13px]")).toBe(true);

    // 文件夹按钮展示文字「文件夹」且带完整 aria-label
    const pairedFolderBtn = screen.getByRole("button", { name: "打开文件夹 客厅的手机" });
    expect(pairedFolderBtn.textContent?.trim()).toBe("文件夹");
    expect(tokensOf(pairedFolderBtn).has("text-[13.5px]")).toBe(true);
    expect(tokensOf(pairedFolderBtn).has("text-ink-60")).toBe(true);
    expect(tokensOf(pairedFolderBtn).has("no-underline")).toBe(true);

    // #2079：已配对行只显示「断开」，已断开行只显示「移除」，均采用柔和危险权重
    const disconnectBtn = screen.getByRole("button", { name: "断开 客厅的手机" });
    expect(screen.queryByRole("button", { name: "移除 客厅的手机" })).toBeNull();
    const removeBtn = screen.getByRole("button", { name: "移除 卧室的手机" });
    expect(screen.queryByRole("button", { name: "断开 卧室的手机" })).toBeNull();

    for (const actionBtn of [disconnectBtn, removeBtn]) {
      const cls = tokensOf(actionBtn);
      expect(cls.has("text-[13.5px]")).toBe(true);
      expect(cls.has("font-medium")).toBe(true);
      expect(cls.has("text-ink-40")).toBe(true);
      expect(cls.has("hover:bg-act-bg")).toBe(true);
      expect(cls.has("hover:text-act")).toBe(true);
      expect(cls.has("focus-visible:bg-act-bg")).toBe(true);
      expect(cls.has("focus-visible:text-act")).toBe(true);
      expect(cls.has("text-act")).toBe(false);
      expect(cls.has("font-semibold")).toBe(false);
    }
  });

  it("#2084 总览最近活动隐藏短 ID 并将完整身份放进 tooltip，活动记录页低调等宽展示 shortId 与 tabular-nums 时间", async () => {
    const dev = makeDevice("a", "客厅的手机");
    const evt = {
      id: "e1",
      ts: NOW - 60_000,
      kind: "pair.accepted",
      actor: "a".repeat(64),
      payload: {},
    };

    setupDaemon({ devices: [dev], audit: [evt] });
    await openApp("#/overview");
    const activitySection = screen.getByTestId("overview-activity-card");
    const overviewItem = activitySection.querySelector("ul li");
    expect(overviewItem).toBeTruthy();
    expect(activitySection.querySelector("ul b")).toBeNull();
    expect(overviewItem.textContent).toContain("客厅的手机");
    expect(overviewItem.textContent).not.toContain("#aaaaaaaa");
    expect(overviewItem.getAttribute("title")).toBe("客厅的手机 · #aaaaaaaa");

    cleanup();
    setupDaemon({ devices: [dev], audit: [evt] });
    await openApp("#/log");
    const logItem = document.querySelector("main.content ul li");
    expect(logItem).toBeTruthy();
    const actorBold = logItem.querySelector("b");
    expect(actorBold?.textContent).toBe("客厅的手机");
    expect(tokensOf(actorBold).has("font-semibold")).toBe(true);
    const shortIdSpan = logItem.querySelector("span.font-mono");
    expect(shortIdSpan?.textContent).toBe("#aaaaaaaa");
    const shortTokens = tokensOf(shortIdSpan);
    expect(shortTokens.has("text-[12px]")).toBe(true);
    expect(shortTokens.has("font-normal")).toBe(true);
    expect(shortTokens.has("text-ink-40")).toBe(true);
    const timeSpan = logItem.querySelector("span.ml-auto");
    expect(tokensOf(timeSpan).has("tabular-nums")).toBe(true);
  });

  it("#2084 桌面端不再使用绿色 text-safe 文字链接，普通链接保留克制下划线，向导标题聚焦保持 tabindex=-1 与键盘焦点环", async () => {
    const dev = makeDevice("a", "客厅的手机");
    const evt = {
      id: "e1",
      ts: NOW - 60_000,
      kind: "pair.accepted",
      actor: "a".repeat(64),
      payload: {},
    };
    setupDaemon({ devices: [dev], audit: [evt] });
    await openApp("#/overview");

    const allActivityLink = screen.getByRole("button", { name: /查看全部/ });
    const linkTokens = tokensOf(allActivityLink);
    expect(linkTokens.has("text-safe")).toBe(false);
    expect(linkTokens.has("underline")).toBe(true);
    expect(linkTokens.has("decoration-border-strong")).toBe(true);

    for (const btn of document.querySelectorAll("button")) {
      expect(tokensOf(btn).has("text-safe")).toBe(false);
    }

    cleanup();
    invokeMock.mockImplementation(async (cmd) => (cmd === "power_hint" ? { kind: "never" } : null));
    render(Wizard, {
      props: {
        defaultDir: "/Users/demo/Pictures/P-Pass",
        configuredLibraryDir: "/Volumes/Backup/P-Pass",
        onDone: () => {},
      },
    });
    await vi.advanceTimersByTimeAsync(0);
    const useDefaultLink = screen.getByRole("button", { name: /回到默认位置/ });
    expect(tokensOf(useDefaultLink).has("text-safe")).toBe(false);
    expect(tokensOf(useDefaultLink).has("underline")).toBe(true);

    await fireEvent.click(screen.getByRole("button", { name: "继续" }));
    await vi.advanceTimersByTimeAsync(0);
    const macStep2Heading = document.activeElement;
    expect(macStep2Heading?.tagName).toBe("H2");
    expect(macStep2Heading?.getAttribute("tabindex")).toBe("-1");
    expect(tokensOf(macStep2Heading).has("outline-none")).toBe(true);
    expect(tokensOf(macStep2Heading).has("focus-visible:ring-3")).toBe(true);
    expect(tokensOf(macStep2Heading).has("focus-visible:ring-ring")).toBe(true);

    cleanup();
    invokeMock.mockImplementation(async () => null);
    render(WizardWindows, {
      props: {
        defaultDir: "C:\\Users\\demo\\Pictures\\P-Pass",
        configuredLibraryDir: "D:\\Photos\\P-Pass",
        onDone: () => {},
      },
    });
    await vi.advanceTimersByTimeAsync(0);
    const winDefaultLink = screen.getByRole("button", { name: /回到默认位置/ });
    expect(tokensOf(winDefaultLink).has("text-safe")).toBe(false);
    expect(tokensOf(winDefaultLink).has("underline")).toBe(true);

    await fireEvent.click(screen.getByRole("button", { name: "继续" }));
    await vi.advanceTimersByTimeAsync(0);
    const winStep2Heading = document.activeElement;
    expect(winStep2Heading?.tagName).toBe("H2");
    expect(winStep2Heading?.getAttribute("tabindex")).toBe("-1");
    expect(tokensOf(winStep2Heading).has("outline-none")).toBe(true);
    expect(tokensOf(winStep2Heading).has("focus-visible:ring-3")).toBe(true);
    expect(tokensOf(winStep2Heading).has("focus-visible:ring-ring")).toBe(true);
  });
});
