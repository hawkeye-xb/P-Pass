// DESK-14: 保持透明 Overlay 的视觉连续性；拖拽只交给两个 32px 的空 hit area。
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { isMacOSUserAgent } from "./titlebar.js";

const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8");
const css = readFileSync(new URL("./app.css", import.meta.url), "utf8");
const titlebar = readFileSync(new URL("./titlebar.js", import.meta.url), "utf8");

function expectBand(name) {
  expect(app).toContain(
    `<div class="titlebar-drag-region ${name}" aria-hidden="true"></div>`,
  );
}

describe("DESK-14 透明 Overlay 拖拽命中区", () => {
  it("主界面与首启向导各有一个空的专用 hit area", () => {
    expectBand("shell-titlebar-drag-region");
    expectBand("wizard-titlebar-drag-region");
  });

  it("仅给专用元素动态标记，不能再给 sidebar 或 wizard 容器打标", () => {
    expect(titlebar).toContain('const DRAG_SELECTOR = ".titlebar-drag-region"');
    expect(titlebar).toContain('el.setAttribute("data-tauri-drag-region", "")');
    expect(titlebar).not.toContain('".sidebar"');
    expect(titlebar).not.toContain('".wizard-shell"');
  });

  it("命中区仅在 macOS Overlay 可见，绝对定位且不改变视觉或文档流", () => {
    expect(css).toContain(".titlebar-drag-region {\n  display: none;");
    expect(css).toContain("#app.macos-overlay-titlebar .titlebar-drag-region {");
    expect(css).toContain("height: 32px;");
    expect(css).toContain("position: absolute;");
    expect(css).toContain("background: transparent;");
  });

  it("平台门只在 macOS 打开透明 hit area", () => {
    expect(isMacOSUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")).toBe(true);
    expect(isMacOSUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)")).toBe(false);
    expect(isMacOSUserAgent("Mozilla/5.0 (X11; Linux x86_64)")).toBe(false);
  });
});
