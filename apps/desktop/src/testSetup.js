// DESK-69 (#997)：vitest 的全局替身。
//
// plugin-os 的 platform() 读的是 Tauri 注入的 window.__TAURI_OS_PLUGIN_INTERNALS__，
// jsdom 里没有。给一个默认值（macOS，与改前「不是 windows 就走 Wizard.svelte」
// 的测试口径一致）；要测别的平台的用例在自己文件里再 vi.mock 覆盖。
import { vi } from "vitest";

vi.mock("@tauri-apps/plugin-os", () => ({ platform: () => "macos" }));
