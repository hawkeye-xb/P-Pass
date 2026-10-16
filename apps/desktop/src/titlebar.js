// macOS Overlay 的拖拽目标是专用、透明的顶部 hit area，而不是业务容器。
// Tauri 只认直接命中的 data-tauri-drag-region；把属性限定在空元素本身，
// 导航、表单、链接和滚动自然保持原交互。
//
// DESK-69 (#997)：「哪个平台是 Overlay」不再嗅探 UserAgent（能被改写），
// 改问 platformUx.js——平台来源统一为 plugin-os。
import { currentPlatform, usesOverlayTitlebar } from "./platformUx.js";

const DRAG_SELECTOR = ".titlebar-drag-region";

function tagDragRegions(root) {
  for (const el of root.querySelectorAll(DRAG_SELECTOR)) {
    if (!el.hasAttribute("data-tauri-drag-region")) {
      el.setAttribute("data-tauri-drag-region", "");
    }
  }
}

export function setupTitlebarDragRegions(platform = currentPlatform()) {
  const appEl = document.getElementById("app");
  if (!appEl) return;
  if (!usesOverlayTitlebar(platform)) return;
  appEl.classList.add("macos-overlay-titlebar");
  tagDragRegions(appEl);
  new MutationObserver(() => tagDragRegions(appEl)).observe(appEl, {
    childList: true,
    subtree: true,
  });
}
