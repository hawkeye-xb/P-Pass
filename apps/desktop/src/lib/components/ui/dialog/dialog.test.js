// @vitest-environment jsdom
//
// #1516：弹窗键盘焦点（WAI-ARIA 模态对话框）。直接挂 dialog.svelte，不经 App。钉住：
// 1. 打开时焦点进弹窗第一个可聚焦元素；弹窗里没有可聚焦元素就聚焦面板本身（tabindex=-1）。
//    反证：去掉 $effect 里的 focus() 调用 ⇒ 本条红。
// 2. Tab 在最后一个元素上回到第一个，Shift+Tab 在第一个上到最后一个，焦点不出弹窗。
//    反证：去掉 onKeydown 里 Tab 分支 ⇒ 本条红（jsdom 不做原生 Tab 移动，焦点停在原处）。
// 3. 关闭后焦点回到打开前的元素；该元素已不在 DOM 就不动。
//    反证：去掉 $effect 清理函数里的 opener.focus() ⇒ 本条红。
import { cleanup, render } from "@testing-library/svelte";
import { createRawSnippet } from "svelte";
import { afterEach, describe, expect, it } from "vitest";
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

  it("关闭后焦点回到打开前的元素；元素已不在 DOM 就跳过", async () => {
    const o = opener();
    const { rerender } = render(Dialog, { open: true, children: body('<button id="a">甲</button>') });
    await Promise.resolve();
    expect(document.activeElement?.id).toBe("a");
    await rerender({ open: false });
    expect(document.activeElement).toBe(o);

    const o2 = opener();
    const r2 = render(Dialog, { open: true, children: body('<button id="c">丙</button>') });
    await Promise.resolve();
    o2.remove();
    await r2.rerender({ open: false });
    expect(document.activeElement).toBe(document.body);
  });
});
