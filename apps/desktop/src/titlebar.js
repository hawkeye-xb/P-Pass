// macOS Overlay 的拖拽目标是专用、透明的顶部 hit area，而不是业务容器。
// Tauri 只认直接命中的 data-tauri-drag-region；把属性限定在空元素本身，
// 导航、表单、链接和滚动自然保持原交互。
//
// DESK-69 (#997)：「哪个平台是 Overlay」不再嗅探 UserAgent（能被改写），
// 改问 platformUx.js。#1043 起答案来自 Rust 侧平台适配器（`platform_ux`）。
import { loadPlatformUx, usesOverlayTitlebar } from "./platformUx.js";

const DRAG_SELECTOR = ".titlebar-drag-region";

function tagDragRegions(root) {
  for (const el of root.querySelectorAll(DRAG_SELECTOR)) {
    if (!el.hasAttribute("data-tauri-drag-region")) {
      el.setAttribute("data-tauri-drag-region", "");
    }
  }
}

export async function setupTitlebarDragRegions(uxPromise = loadPlatformUx()) {
  let ux;
  try {
    ux = await uxPromise;
  } catch (e) {
    // 问不到就按系统原生标题栏处理：窗口照样能拖（系统标题栏），只是
    // macOS Overlay 下少了假标题栏——不能因此让整个界面起不来。
    console.warn("[titlebar] platform_ux unavailable:", e);
    return;
  }
  const appEl = document.getElementById("app");
  if (!appEl) return;
  if (!usesOverlayTitlebar(ux)) return;
  appEl.classList.add("macos-overlay-titlebar");
  tagDragRegions(appEl);
  new MutationObserver(() => tagDragRegions(appEl)).observe(appEl, {
    childList: true,
    subtree: true,
  });
}
