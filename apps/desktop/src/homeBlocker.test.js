// 首页提示分级 L1（docs/design/2026-09-22-home-notice-priority.md §2.1）在桌面的落地：
// 备份完全停了（服务没在跑 / 找不到照片库）时，首页结论就是这个阻断，不给完成度结论、不出现绿色。
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { homeBlocker } from "./lib/homeBlocker.js";
import { setLocale, t } from "./lib/i18n.js";

const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8");

describe("首页阻断（L1）", () => {
  it("找不到照片库：红色、要用户动手", () => {
    const b = homeBlocker("running", { library_missing: true, library_dir: "/x" });
    expect(b).toMatchObject({ id: "library_missing", tone: "act" });
  });

  it("服务没在跑是红色阻断，正在启动是琥珀等待", () => {
    for (const s of ["stopped", "unreachable", "not_configured"]) {
      expect(homeBlocker(s, null)).toMatchObject({ id: "service_down", tone: "act" });
    }
    expect(homeBlocker("starting", null)).toMatchObject({ tone: "waiting" });
  });

  // 服务不在时 status 是旧的或 null——判据先看服务状态，不会被旧 status 盖过。
  it("服务状态优先于旧的 status", () => {
    expect(homeBlocker("stopped", { library_missing: true }).id).toBe("service_down");
  });

  it("一切正常时没有阻断", () => {
    expect(homeBlocker("running", { library_missing: false })).toBeNull();
    expect(homeBlocker("running", null)).toBeNull();
  });

  it.each(["zh", "en"])("%s：阻断标题与胶囊都有文案，且不说「安全」", (lang) => {
    setLocale(lang);
    for (const s of [["running", { library_missing: true }], ["stopped", null], ["starting", null]]) {
      const b = homeBlocker(...s);
      for (const key of [b.headlineKey, b.pillKey]) {
        expect(t(key)).not.toBe(key);
        expect(t(key)).not.toMatch(/安全|safe/i);
      }
    }
  });

  // 接线：有阻断时标题换成阻断、副标题（配对数）不渲染、胶囊不再按「服务在跑」显示绿色。
  // 反证：胶囊仍用 isServiceRunning 决定绿色 → 找不到照片库时是绿的，第三条红。
  it("首页接线：标题、副标题、胶囊都跟着阻断走", () => {
    const headline = app.indexOf('data-testid="blocker-headline"');
    const normalTitle = app.indexOf('t("ui.overview_title_count"');
    expect(headline).toBeGreaterThan(0);
    expect(normalTitle).toBeGreaterThan(headline);
    const pairedCount = app.indexOf('t("ui.paired_count", { n: pairedCount })');
    expect(pairedCount).toBeGreaterThan(app.indexOf("{#if blocker}"));
    expect(app).toContain("class:ok={!blocker}");
    expect(app).not.toContain("class:ok={isServiceRunning(serviceState)}");
    expect(app).toMatch(/<Card variant="danger"[^>]*data-testid="library-missing"/);
  });

  // #639：正在搬迁是等待（琥珀），压过「找不到照片库」（搬迁中原位置可能已经不在了）。
  it("正在搬迁：琥珀等待，优先于找不到照片库", () => {
    expect(homeBlocker("running", { relocating: true, library_missing: true })).toMatchObject({
      id: "relocating",
      tone: "waiting",
    });
  });

  // #639：「更改照片库位置」恢复，走整库搬迁命令（不再是只改指向的 set_library_dir）。
  // 反证：chooseFolder 仍调 set_library_dir → 红。
  it("设置页更改位置走整库搬迁", () => {
    expect(app).toContain('data-testid="change-library"');
    const choose = app.slice(app.indexOf("async function chooseFolder"), app.indexOf("// DESK-10: 导出走桌面壳"));
    expect(choose).toContain('invoke("relocate_library", { dryRun: false })');
    expect(choose).not.toContain('invoke("set_library_dir")');
  });
});
