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
  // DESK-15：.message/.message-close 的视觉定义已从 App.svelte 挪进
  // Notice 组件（Tailwind class，不是原始 CSS），下面两条断言跟着挪过去。
  const noticeSrc = codeOf(new URL("./lib/components/ui/notice/notice.svelte", import.meta.url).pathname);

  const pStart = noticeSrc.indexOf("<p");
  const pTag = noticeSrc.slice(pStart, noticeSrc.indexOf(">", pStart) + 1);

  it("Notice 必须 fixed 定位——脱离文档流，不占布局", () => {
    expect(pTag).toMatch(/class="[^"]*\bfixed\b[^"]*"/);
    // 反证：旧实现用 margin 占位（margin: 0 0 18px）把内容顶下去。
    expect(pTag).not.toMatch(/\bm-\[?0[^"]*18px/);
  });

  it("浮层必须高于模态背板（Notice z-[60] > Dialog 组件遮罩 z-50），模态打开时提示仍可见", () => {
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
