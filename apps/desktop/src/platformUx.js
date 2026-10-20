// DESK-69 (#997) / #1043：桌面前端里「按平台不同」的界面决定，全部集中在这里。
//
// #1043 起前端**不再判断平台**：关窗要不要提示、标题栏是不是 Overlay、电脑
// 睡眠由谁负责，都由 Rust 侧的平台适配器回答，经 `platform_ux` 命令下发；
// 这里只读这些字段。字段缺失或取值不认识一律报错，不许悄悄落到某个默认值上
// ——以前「不是 windows 就当 macOS」让 Linux 拿到 Finder、macOS 系统保护、
// 右键打开这类文案。
import { invoke } from "@tauri-apps/api/core";

let pending = null;

/**
 * 平台界面能力（进程内只问一次；失败了下次再问）。
 * @returns {Promise<{close_to_tray_hint: boolean, overlay_titlebar: boolean, sleep_owner: "user" | "daemon" | null}>}
 */
export function loadPlatformUx() {
  if (!pending) {
    pending = Promise.resolve(invoke("platform_ux")).catch((e) => {
      pending = null;
      throw e;
    });
  }
  return pending;
}

function unsupported(ux, what) {
  throw new Error(`platformUx.${what}: unsupported platform capabilities ${JSON.stringify(ux)}`);
}

function flag(ux, key, what) {
  const v = ux?.[key];
  return typeof v === "boolean" ? v : unsupported(ux, what);
}

/**
 * 首启向导用哪一份。两份向导是刻意拆开的（文案与 UX 各自定制，见
 * WizardWindows.svelte 顶部注释）；第 2 步的分歧就是「睡眠由谁负责」：
 * - "user"：向导请用户关掉空闲自动睡眠（Wizard.svelte）；
 * - "daemon"：daemon 自动保持唤醒，向导只说明（WizardWindows.svelte）。
 * 没有桌面向导的平台（Linux，#752）给 null，直接报错。
 * @returns {"user-sleep" | "daemon-sleep"}
 */
export function wizardVariant(ux) {
  switch (ux?.sleep_owner) {
    case "user":
      return "user-sleep";
    case "daemon":
      return "daemon-sleep";
    default:
      return unsupported(ux, "wizardVariant");
  }
}

/** 关窗（藏到托盘）时要不要提示一次「还在后台运行」。 */
export function closeToTrayHint(ux) {
  return flag(ux, "close_to_tray_hint", "closeToTrayHint");
}

/** 标题栏是否为透明 Overlay（需要前端自己放拖拽命中区）。 */
export function usesOverlayTitlebar(ux) {
  return flag(ux, "overlay_titlebar", "usesOverlayTitlebar");
}
