// @vitest-environment jsdom
//
// #1516：弹窗键盘焦点（WAI-ARIA 模态对话框）。直接挂 dialog.svelte，不经 App。钉住：
// 1. 打开时焦点进弹窗第一个可聚焦元素；弹窗里没有可聚焦元素就聚焦面板本身（tabindex=-1）。
//    反证：去掉 $effect 里的 focus() 调用 ⇒ 本条红。
// 2. Tab 在最后一个元素上回到第一个，Shift+Tab 在第一个上到最后一个，焦点不出弹窗。
//    反证：去掉 onKeydown 里 Tab 分支 ⇒ 本条红（jsdom 不做原生 Tab 移动，焦点停在原处）。
// 3. 关闭后焦点回到打开前的元素；该元素已不在 DOM（或打开时本无焦点）就回
//    main 兜底（tabindex=-1），不落 body（#1132 验收 1）。
//    反证：去掉 $effect 清理函数里的 opener.focus() 与 main 兜底 ⇒ 本条红。
import { cleanup, render } from "@testing-library/svelte";
import { createRawSnippet } from "svelte";
import { afterEach, describe, expect, it, vi } from "vitest";
import Dialog from "./dialog.svelte";

const body = (html) => createRawSnippet(() => ({ render: () => `<div>${html}</div>` }));
const tab = (shiftKey = false) =>
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", shiftKey, bubbles: true, cancelable: true }));
// svelte:window 的 onkeydown 挂在 window 上；document 上冒泡的事件会到达 window。

afterEach(() => {
  cleanup();
  document.body.innerHTML = "";
});

function opener() {
  const b = document.createElement("button");
  b.textContent = "打开";
  document.body.appendChild(b);
  b.focus();
  return b;
}

describe("dialog 焦点管理", () => {
  it("打开时焦点进第一个可聚焦元素；没有就聚焦面板", async () => {
    opener();
    const { unmount } = render(Dialog, {
      open: true,
      children: body('<button id="a">甲</button><button id="b">乙</button>'),
    });
    await Promise.resolve();
    expect(document.activeElement?.id).toBe("a");
    unmount();

    opener();
    render(Dialog, { open: true, children: body("<p>只有文字</p>") });
    await Promise.resolve();
    expect(document.activeElement?.getAttribute("role")).toBe("dialog");
    expect(document.activeElement?.getAttribute("tabindex")).toBe("-1");
  });

  it("Tab / Shift+Tab 在弹窗内循环", async () => {
    opener();
    render(Dialog, {
      open: true,
      children: body('<button id="a">甲</button><button id="b">乙</button>'),
    });
    await Promise.resolve();
    const a = document.getElementById("a");
    const b = document.getElementById("b");
    b.focus();
    tab();
    expect(document.activeElement).toBe(a);
    tab(true);
    expect(document.activeElement).toBe(b);
  });

  // #1132 D1（WAI-ARIA APG Dialog 模式）：模态打开期间背景不可聚焦——
  // 靠 HTML 标准 inert（Tab/点按/读屏都到不了），关闭后解除。
  // 反证：去掉 $effect 里的背景 inert 分支 ⇒ 本条红（背景不再带 inert 属性）。
  it("打开时背景被 inert，关闭后解除；弹窗自身不 inert", async () => {
    const o = opener();
    const { rerender } = render(Dialog, {
      open: true,
      children: body('<button id="a">甲</button>'),
    });
    await Promise.resolve();
    // 背景里的触发按钮带 inert；弹窗面板与内部控件不带。
    expect(o.getAttribute("inert")).toBe("");
    const panel = document.querySelector('[role="dialog"]');
    expect(panel.getAttribute("inert")).toBe(null);
    expect(document.getElementById("a").closest('[role="dialog"]')).toBe(panel);
    // CodeRabbit：遮罩子树整棵 inert 时这条也红——内部控件的祖先链上不许有 inert。
    expect(document.getElementById("a").closest("[inert]")).toBe(null);
    // 关闭：解除背景 inert，焦点回到触发按钮（另一用例已钉）。
    await rerender({ open: false });
    expect(o.getAttribute("inert")).toBe(null);
  });

  // #1132 D1：不能关闭的弹窗（没传 onClose）——Esc 不关闭，焦点仍被限制在弹窗内。
  // 反证：把 Esc 分支改成无 onClose 也调用 onClose/关面板 ⇒ 本条红（面板消失）。
  it("没有 onClose 的弹窗：Esc 不关闭，焦点留在弹窗内", async () => {
    opener();
    render(Dialog, {
      open: true,
      children: body('<button id="a">甲</button><button id="b">乙</button>'),
    });
    await Promise.resolve();
    document.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    );
    await Promise.resolve();
    // 面板还在（没有 onClose 可关），焦点没有被 Esc 弹出弹窗。
    expect(document.querySelector('[role="dialog"]')).toBeTruthy();
    expect(["a", "b"]).toContain(document.activeElement?.id);
  });

  // #1132 D1（验收 1）：传了 onClose 的弹窗，Esc 触发关闭。
  // 反证：去掉 onKeydown 里 Escape 分支 ⇒ 本条红（onClose 不被调用）。
  it("传了 onClose 的弹窗：Esc 触发关闭", async () => {
    opener();
    const onClose = vi.fn();
    render(Dialog, {
      open: true,
      onClose,
      children: body('<button id="a">甲</button>'),
    });
    await Promise.resolve();
    document.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    );
    await Promise.resolve();
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("关闭后焦点回到打开前的元素；元素已移除时回 main 兜底，不落 body", async () => {
    const o = opener();
    const { rerender } = render(Dialog, { open: true, children: body('<button id="a">甲</button>') });
    await Promise.resolve();
    expect(document.activeElement?.id).toBe("a");
    await rerender({ open: false });
    expect(document.activeElement).toBe(o);

    // #1132 验收 1：触发元素已被移除时回到一个明确的兜底元素，而不是 body
    // （「待确认加入」打开时触发按钮即被移除——旧实现关窗后焦点落在 body）。
    const main = document.createElement("main");
    main.setAttribute("tabindex", "-1");
    document.body.appendChild(main);
    const o2 = opener();
    const r2 = render(Dialog, { open: true, children: body('<button id="c">丙</button>') });
    await Promise.resolve();
    o2.remove();
    await r2.rerender({ open: false });
    expect(document.activeElement).toBe(main);
  });
});
