// I18N-03 (#492) 门禁：桌面端用户可见文案只许从 assets/i18n/{en,zh}.json 取。
//
// 1. 源码里（src/**/*.{svelte,js,ts}，排除 *.test.js，剔除注释）出现 CJK
//    字符即红——中文只许留在注释、测试和字典里。
// 2. 源码里引用到的每个字典 key（任何 "ui.…" / "err.…" / "diag.…" 字面量，
//    不只 t("…") 里的——NAV 数组、pending.js 的 key 都是先存成数据再 t()）
//    在 en/zh 两份 JSON 里都必须存在。
// 3. 剥注释的 helper 自己也有单测：它若把代码误当注释吞掉，门禁就会漏报。
//
// 反证（PR 里跑过）：往任一组件模板里加一个中文字面量，第 1 条必须红；还原复绿。
import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { cjkLines, stripJsComments, stripSvelteComments } from "./i18nGate.helpers.js";
import enDict from "../../../assets/i18n/en.json";
import zhDict from "../../../assets/i18n/zh.json";

const SRC = fileURLToPath(new URL(".", import.meta.url));

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

const sources = walk(SRC)
  .filter((p) => /\.(svelte|js|ts)$/.test(p) && !p.endsWith(".test.js"))
  .map((p) => {
    const raw = readFileSync(p, "utf8").replace(/\r\n/g, "\n");
    const code = p.endsWith(".svelte") ? stripSvelteComments(raw) : stripJsComments(raw);
    return { file: relative(SRC, p), code };
  });

describe("注释剥离 helper（门禁的前提：不能把代码当注释吞掉）", () => {
  it("字符串里的 // 不是注释", () => {
    const out = stripJsComments('const u = "https://example.com/中"; // 注释');
    expect(out).toContain('"https://example.com/中"');
    expect(out).not.toContain("注释");
  });

  it("块注释、行注释里的中文被剥掉，行号不变", () => {
    const out = stripJsComments("/* 甲\n乙 */\nconst a = 1; // 丙\n");
    expect(cjkLines(out)).toEqual([]);
    expect(out.split("\n")).toHaveLength(4);
  });

  it("模板字符串（含嵌套 ${}）里的中文照样算代码", () => {
    const out = stripJsComments("const s = `a ${x ? `中${y}` : 'b'} 文`; // 注");
    expect(out).toContain("中");
    expect(out).toContain("文");
    expect(out).not.toContain("注");
  });

  it("正则字面量不被当成注释起点，除号也不被当成正则", () => {
    const re = stripJsComments('const r = /\\/\\/中/; const s = "文";');
    expect(re).toContain("中");
    expect(re).toContain('"文"');
    const div = stripJsComments('const d = a / b; const s = "中"; // x / y');
    expect(div).toContain('"中"');
  });

  it("Svelte：HTML 注释被剥掉，{/if} 之后的模板文本仍被扫描", () => {
    const src = '<script>\n  // 注释\n</script>\n{#if a}x{/if}\n<!-- 注释 -->\n<p>中文</p>\n';
    const hits = cjkLines(stripSvelteComments(src));
    expect(hits.map((h) => h.text)).toEqual(["<p>中文</p>"]);
    expect(hits[0].line).toBe(6);
  });

  it("Svelte：{…} 表达式里的注释被剥、字符串保留；<style> 注释被剥", () => {
    const src = '<p title={a ? "中" : b /* 注 */}>x</p>\n<style>/* 样式注释 */ p{}</style>';
    const out = stripSvelteComments(src);
    expect(out).toContain('"中"');
    expect(out).not.toContain("注");
    expect(out).not.toContain("样式注释");
  });
});

describe("门禁：桌面端源码里没有写死的中文", () => {
  it("扫描到了源码（防止路径写错导致空扫描永远绿）", () => {
    const files = sources.map((s) => s.file);
    expect(files).toContain("App.svelte");
    expect(files).toContain("Wizard.svelte");
    expect(files).toContain("WizardWindows.svelte");
    expect(files).toContain(join("lib", "connection.js"));
  });

  it("剔除注释后，src/**/*.{svelte,js,ts} 不含 CJK 字符", () => {
    const hits = sources.flatMap(({ file, code }) =>
      cjkLines(code).map((h) => `${file}:${h.line}: ${h.text}`),
    );
    expect(hits, "用户可见文案要进 assets/i18n/{en,zh}.json，用 t() 取").toEqual([]);
  });
});

describe("门禁：桌面端引用的每个字典 key 在 en/zh 里都存在", () => {
  const KEY_LITERAL = /["'`]((?:ui|err|diag)\.[a-z_.]+)["'`]/g;
  const referenced = new Map();
  for (const { file, code } of sources) {
    for (const m of code.matchAll(KEY_LITERAL)) {
      if (!referenced.has(m[1])) referenced.set(m[1], file);
    }
  }

  it("确实收集到了 key（防止正则写错导致空集永远绿）", () => {
    expect(referenced.size).toBeGreaterThan(150);
    expect(referenced.has("ui.nav_overview")).toBe(true);
    expect(referenced.has("ui.weekday_sun")).toBe(true);
  });

  it("每个 key 两种语言都有非空译文", () => {
    const missing = [];
    for (const [key, file] of referenced) {
      for (const [lang, dict] of [
        ["en", enDict],
        ["zh", zhDict],
      ]) {
        if (typeof dict[key] !== "string" || dict[key] === "") missing.push(`${lang}: ${key} (${file})`);
      }
    }
    expect(missing).toEqual([]);
  });

  it("en 的 ui.* 文案里没有汉字", () => {
    // 只看汉字：存量里有几条英文沿用了「」，那是文案评审线的事。
    const HAN = new RegExp("[\\u4e00-\\u9fff]");
    const zhInEn = Object.entries(enDict)
      .filter(([k, v]) => k.startsWith("ui.") && HAN.test(v))
      .map(([k]) => k);
    expect(zhInEn).toEqual([]);
  });
});
