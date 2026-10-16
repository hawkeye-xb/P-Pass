// DESK-69 (#997)：桌面前端里「按平台不同」的界面决定，全部集中在这里。
//
// 平台只有一个来源：Tauri 官方 `@tauri-apps/plugin-os` 的 `platform()`——
// 值在编译时就定了（同 Electron 的 `process.platform`），不像 UserAgent
// 那样能被改写；也不再从 `wizard_state` 里另取一份。
//
// 每个决定都对 macos / windows / linux 显式写一支。没写到的平台直接抛错，
// 不许悄悄落到某个平台的默认值上——以前「不是 windows 就当 macOS」让
// Linux 会拿到 Finder、macOS 系统保护、右键打开这类文案。
import { platform } from "@tauri-apps/plugin-os";

/** 当前平台（plugin-os 的取值：macos / windows / linux / ios / android …）。 */
export function currentPlatform() {
  return platform();
}

function unsupported(p, what) {
  throw new Error(`platformUx.${what}: unsupported platform ${JSON.stringify(p)}`);
}

/**
 * 首启向导用哪一份。两份向导是刻意拆开的（文案与 UX 各自定制，见
 * WizardWindows.svelte 顶部注释）；Linux 还没有桌面向导（#752）。
 * @returns {"macos" | "windows"}
 */
export function wizardVariant(p) {
  switch (p) {
    case "macos":
      return "macos";
    case "windows":
      return "windows";
    default:
      return unsupported(p, "wizardVariant");
  }
}

/**
 * 关窗（藏到托盘）时要不要提示一次「还在后台运行」。
 * - macOS：点红灯不退出是系统常态，不用解释（#303 验收标准 3）。
 * - Windows：用户普遍以为点 X 就是退出（#303）。
 * - Linux：同 Windows 的习惯；GNOME 默认还没有托盘，不提示的话 App 关窗后
 *   就像「消失」了。
 */
export function closeToTrayHint(p) {
  switch (p) {
    case "macos":
      return false;
    case "windows":
    case "linux":
      return true;
    default:
      return unsupported(p, "closeToTrayHint");
  }
}

/**
 * 标题栏是否为透明 Overlay（需要前端自己放拖拽命中区）。`titleBarStyle:
 * "Overlay"` 只在 macOS 生效，Windows / Linux 是系统原生标题栏。
 */
export function usesOverlayTitlebar(p) {
  switch (p) {
    case "macos":
      return true;
    case "windows":
    case "linux":
      return false;
    default:
      return unsupported(p, "usesOverlayTitlebar");
  }
}
