// UI-04b: 改名反馈必须脱离文档流（fixed 浮层），出现/消失不顶动下方内容。
//
// 反证：把 .message 的 position: fixed 改回原来的 in-flow（margin 占位），
// 下面的断言会挂——提示条重新参与布局，改名反馈出现/消失时内容位移。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

/** 剥掉注释再断言——否则解释性文字会被当成代码（photoWall.test.js 同款）。 */
function codeOf(url) {
  // 两处都是 Windows 上才会现形的坑（#297）：
  // 1. 传 URL **对象**，不传 `.pathname`——后者在 Windows 上是 `/C:/...`，
  //    readFileSync 会再拼成 `C:\C:\...`，直接 ENOENT。
  // 2. 先把 CRLF 归一成 LF：仓库里存的是 LF，但 core.autocrlf 让 Windows
  //    检出成 CRLF。下面的断言按 LF 写，不归一化就是同一份源码 Linux 过、
  //    Windows 挂——挂的是行尾，不是代码。
  return readFileSync(url, "utf8")
    .replace(/\r\n/g, "\n")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("//"))
    .join("\n");
}

describe("UI-04b 改名反馈", () => {
  const src = codeOf(new URL("./App.svelte", import.meta.url));
  const sonnerSrc = codeOf(new URL("./lib/components/ui/sonner/sonner.svelte", import.meta.url));
  const appCss = readFileSync(new URL("./app.css", import.meta.url), "utf8").replace(
    /\r\n/g,
    "\n",
  );
  it("改名成功/失败必须走官方 Sonner 通知原语，而不是手写 Message/Toast", () => {
    const rename = src.slice(src.indexOf("async function commitRename()"), src.indexOf("async function openLibrary()"));
    expect(src).toContain('import { Toaster } from "$lib/components/ui/sonner"');
    expect(src).toContain('import { toast } from "svelte-sonner"');
    expect(rename).toContain('toast.success(t("ui.rename_saved"');
    expect(rename).toContain('toast.error(t("ui.rename_failed"');
    expect(rename).not.toContain("showRenameMessage(");
  });

  it("应用只挂一个标准 Toaster，放在右上角而不侵占页面标题或设备行", () => {
    expect(src).toContain('<Toaster position="top-right" />');
    expect(src).not.toContain('<Toast {message}');
    expect(src).not.toContain("<Message message={renameMessage.message}");
  });

  it("官方 Sonner 必须映射产品三种含义 token：safe / waiting / act", () => {
    expect(sonnerSrc).toContain("richColors");
    expect(appCss).toContain("--success-bg: var(--color-safe-bg)");
    expect(appCss).toContain("--warning-bg: var(--color-waiting-bg)");
    expect(appCss).toContain("--error-bg: var(--color-act-bg)");
  });
});
