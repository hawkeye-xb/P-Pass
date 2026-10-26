// @vitest-environment node
// 白屏回归（refs #1120）：正式包开了 freezePrototype，打包后的前端必须在原型冻结
// 的页面里也能跑起来。这里把前端真实打包一次，放进 Object.prototype 已冻结的
// jsdom 里按模块语义（严格模式）执行，任何加载期报错都算失败。
// 反证：把 npm qrcode 装回来并在 App.svelte 里 import → 这条红（toString 只读）。
import { test, expect } from "vitest";
import { build } from "vite";
import { JSDOM } from "jsdom";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

test("打包后的前端在 freezePrototype 下能加载并渲染", async () => {
  const out = mkdtempSync(join(tmpdir(), "ppf-frozen-"));
  try {
    await build({ root, logLevel: "silent", build: { outDir: out, emptyOutDir: true } });
    const js = readdirSync(join(out, "assets")).find((f) => f.endsWith(".js"));
    const code = readFileSync(join(out, "assets", js), "utf8");

    const dom = new JSDOM('<!doctype html><body><div id="app"></div></body>', {
      url: "http://tauri.localhost/",
      runScripts: "outside-only",
      pretendToBeVisual: true,
    });
    const w = dom.window;
    const errors = [];
    w.addEventListener("error", (e) => errors.push(String(e.error ?? e.message)));
    w.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
    w.__TAURI_INTERNALS__ = {
      invoke: () => new Promise(() => {}), // 永不返回：只验加载与首帧，不让拒绝漏进测试进程
      transformCallback: () => 0,
      metadata: { currentWindow: { label: "main" }, currentWebview: { label: "main" } },
    };
    // 与 Tauri scripts/freeze_prototype.js 一致：只冻结 Object.prototype。
    w.eval("Object.freeze(Object.prototype);");
    try {
      w.eval('"use strict";\n' + code);
    } catch (e) {
      errors.push(String(e));
    }
    await new Promise((r) => setTimeout(r, 50));
    expect(errors).toEqual([]);
    expect(w.document.getElementById("app").innerHTML.length).toBeGreaterThan(0);
    w.close();
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
}, 120_000);
