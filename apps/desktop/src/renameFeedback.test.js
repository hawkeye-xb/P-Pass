// UI-04b: 改名反馈必须脱离文档流（fixed 浮层），出现/消失不顶动下方内容。
//
// 反证：把 .message 的 position: fixed 改回原来的 in-flow（margin 占位），
// 下面的断言会挂——提示条重新参与布局，改名反馈出现/消失时内容位移。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

/** 剥掉注释再断言——否则解释性文字会被当成代码（photoWall.test.js 同款）。 */
function codeOf(path) {
  return readFileSync(path, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("//"))
    .join("\n");
}

describe("UI-04b 改名反馈浮层", () => {
  const src = codeOf(new URL("./App.svelte", import.meta.url).pathname);
  // UI-04b：瞬时反馈的视觉与状态语义由 Toast 组件独占，页面只接线。
  const toastSrc = codeOf(new URL("./lib/components/ui/toast/toast.svelte", import.meta.url).pathname);

  const pStart = toastSrc.indexOf("<p");
  const pTag = toastSrc.slice(pStart, toastSrc.indexOf(">", pStart) + 1);

  it("瞬时反馈必须走语义明确的 Toast 组件，而不是复用 Notice", () => {
    expect(src).toContain('import { Toast } from "$lib/components/ui/toast"');
    expect(src).toContain('<Toast {message} onClose={() => (message = "")} />');
  });

  it("Toast 必须 fixed 定位——脱离文档流，不占布局", () => {
    expect(pTag).toMatch(/class="[^"]*\bfixed\b[^"]*"/);
    // 反证：旧实现用 margin 占位（margin: 0 0 18px）把内容顶下去。
    expect(pTag).not.toMatch(/\bm-\[?0[^"]*18px/);
  });

  it("Toast 必须内容定宽、深色高对比且带状态语义，不能退回宽大的黄色提示条", () => {
    expect(pTag).toMatch(/class="[^"]*\bw-fit\b[^"]*"/);
    expect(pTag).toMatch(/class="[^"]*max-w-\[min\(90vw,360px\)\][^"]*"/);
    expect(pTag).toMatch(/class="[^"]*\bbg-ink\b[^"]*"/);
    expect(pTag).toMatch(/class="[^"]*\btext-paper\b[^"]*"/);
    expect(pTag).not.toMatch(/\bbg-waiting-bg\b/);
    expect(pTag).toContain('role="status"');
    expect(pTag).toContain('aria-live="polite"');
  });

  it("浮层必须高于模态背板（Toast z-[60] > Dialog 组件遮罩 z-50），模态打开时提示仍可见", () => {
    expect(pTag).toMatch(/class="[^"]*\bz-\[60\][^"]*"/);
    const dialogSrc = codeOf(new URL("./lib/components/ui/dialog/dialog.svelte", import.meta.url).pathname);
    expect(dialogSrc).toMatch(/class="[^"]*\bz-50\b[^"]*"/);
  });

  it("改名成功/失败反馈仍走 flashMessage——机制复用，不另起炉灶", () => {
    const rename = src.slice(src.indexOf("async function commitRename()"), src.indexOf("async function openLibrary()"));
    expect(rename).toContain('flashMessage(t("ui.rename_saved"');
    expect(rename).toContain('flashMessage(t("ui.rename_failed"');
  });
});
