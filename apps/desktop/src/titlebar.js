// macOS Overlay 的拖拽目标是专用、透明的顶部 hit area，而不是业务容器。
// Tauri 只认直接命中的 data-tauri-drag-region；把属性限定在空元素本身，
// 导航、表单、链接和滚动自然保持原交互。
const DRAG_SELECTOR = ".titlebar-drag-region";

export function isMacOSUserAgent(userAgent) {
  return /\bMacintosh\b|\bMac OS X\b/.test(userAgent ?? "");
}

function tagDragRegions(root) {
  for (const el of root.querySelectorAll(DRAG_SELECTOR)) {
    if (!el.hasAttribute("data-tauri-drag-region")) {
      el.setAttribute("data-tauri-drag-region", "");
    }
  }
}

export function setupTitlebarDragRegions() {
  const appEl = document.getElementById("app");
  if (!appEl) return;
  if (!isMacOSUserAgent(navigator.userAgent)) return;
  appEl.classList.add("macos-overlay-titlebar");
  tagDragRegions(appEl);
  new MutationObserver(() => tagDragRegions(appEl)).observe(appEl, {
    childList: true,
    subtree: true,
  });
}
