// macOS Overlay 标题栏配套（tauri.conf.json: titleBarStyle "Overlay"）——
// 红绿灯悬浮在窗口左上角、内容区延伸到窗口顶部，这里把侧栏/向导头部
// 标成窗口拖拽区（红绿灯右侧与下方的空白都能拖动窗口）。
//
// 为什么用 JS 动态打标而不是写进 App.svelte 模板：Tauri v2 的
// data-tauri-drag-region 是 document 级 mousedown 委托，事件触发时才
// 读 target 的属性，动态 setAttribute 同样生效；而两套 shell
// （wizard / 主界面）互斥渲染、出现时机不同，用 MutationObserver
// 等元素挂载后再打标，属性只打在元素自身——子元素（导航按钮等）
// 不带属性，交互完全不受影响（Tauri 官方语义）。
const DRAG_SELECTORS = [
  ".sidebar",
  ".sidebar .brand",
  ".sidebar nav",
  ".wizard-shell",
  ".wizard-shell header",
  ".wizard-shell h1",
];

function tagDragRegions(root) {
  for (const sel of DRAG_SELECTORS) {
    for (const el of root.querySelectorAll(sel)) {
      if (!el.hasAttribute("data-tauri-drag-region")) {
        el.setAttribute("data-tauri-drag-region", "");
      }
    }
  }
}

export function setupTitlebarDragRegions() {
  const appEl = document.getElementById("app");
  if (!appEl) return;
  tagDragRegions(appEl);
  new MutationObserver(() => tagDragRegions(appEl)).observe(appEl, {
    childList: true,
    subtree: true,
  });
}
