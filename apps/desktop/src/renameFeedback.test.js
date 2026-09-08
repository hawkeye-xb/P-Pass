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

  it(".message 必须 position: fixed——脱离文档流，不占布局", () => {
    const css = src.slice(src.indexOf(".message {"), src.indexOf(".message-close"));
    expect(css).toContain("position: fixed");
    // 反证：旧实现用 margin 占位（margin: 0 0 18px）把内容顶下去。
    expect(css).not.toMatch(/margin:\s*0\s+0\s+18px/);
  });

  it("浮层必须高于模态背板（z-index 60 > modal-backdrop 50），模态打开时提示仍可见", () => {
    const css = src.slice(src.indexOf(".message {"), src.indexOf(".message-close"));
    expect(css).toContain("z-index: 60");
    const backdrop = src.slice(src.indexOf(".modal-backdrop {"), src.indexOf(".modal {"));
    expect(backdrop).toContain("z-index: 50");
  });

  it("改名成功/失败反馈仍走 flashMessage——机制复用，不另起炉灶", () => {
    const rename = src.slice(src.indexOf("async function commitRename()"), src.indexOf("async function openLibrary()"));
    expect(rename).toContain('flashMessage(t("ui.rename_saved"');
    expect(rename).toContain('flashMessage(t("ui.rename_failed"');
  });
});
