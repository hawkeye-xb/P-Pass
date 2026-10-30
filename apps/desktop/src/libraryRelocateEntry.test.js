// #639：设置页「更改照片库位置」恢复（DESK-48 隐藏到此结束），语义是整库搬迁：
// 手机不重扫码、不重传，原目录搬空。选位置走系统对话框（壳暂存路径，网页递不进，#1150），
// 确认后调壳的 relocate_library，由后台服务落计划、重启去搬。
// 反证：入口仍藏在注释里，或 chooseFolder 仍调只改指向的 set_library_dir ⇒ 红。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { stripSvelteComments } from "./i18nGate.helpers.js";
import { setLocale, t } from "./lib/i18n.js";

const raw = readFileSync(fileURLToPath(new URL("./App.svelte", import.meta.url)), "utf8");
const code = stripSvelteComments(raw.replace(/\r\n/g, "\n"));

describe("#639: 更改照片库位置 = 整库搬迁", () => {
  it("设置页渲染更改入口与后果说明", () => {
    expect(code).toContain("onclick={chooseFolder}");
    expect(code).toContain('t("ui.change_library")');
    expect(code).toContain('t("ui.library_change_hint")');
  });

  it("确认后走整库搬迁命令", () => {
    const choose = code.slice(code.indexOf("async function chooseFolder()"));
    const body = choose.slice(0, choose.indexOf("\n  }\n"));
    expect(body).toContain('invoke("pick_library_dir"');
    expect(body).toContain('invoke("relocate_library", { dryRun: false })');
    expect(body).not.toContain('invoke("set_library_dir")');
  });

  // 确认前先预检：确认框写明最终位置（预检给的 to），文件夹里已有别的东西就额外提示；预检被拒就不弹确认。
  // 反证：不预检直接确认，或确认框不带非空提示 ⇒ 红。
  it("确认前预检，确认框写最终位置与非空提示", () => {
    const choose = code.slice(code.indexOf("async function chooseFolder()"));
    const body = choose.slice(0, choose.indexOf("\n  }\n"));
    const dry = body.indexOf('invoke("relocate_library", { dryRun: true })');
    expect(dry).toBeGreaterThan(-1);
    expect(dry).toBeLessThan(body.indexOf("confirmDialog("));
    expect(body).toContain('t("ui.change_body", { dir: check?.to ?? dir })');
    expect(body).toMatch(/if \(check\?\.non_empty\) body\.push\(t\("ui\.change_target_not_empty"\)\)/);
  });

  it.each([
    ["zh", "照片库将搬到：/Volumes/Disk", "这个文件夹里已有其他文件，照片会和它们放在一起"],
    ["en", "The photo library will move to: /Volumes/Disk", "already has other files"],
  ])("%s：确认框文案", (lang, head, nonEmpty) => {
    setLocale(lang);
    expect(t("ui.change_body", { dir: "/Volumes/Disk" })).toContain(head);
    expect(t("ui.change_target_not_empty")).toContain(nonEmpty);
  });

  // 搬迁中整个窗口锁住：外壳 inert、导航不响应、锁定层只有标题与进度（没有按钮）。
  // 反证：去掉 inert 或 go() 不拦 ⇒ 红。
  it("搬迁中整个窗口锁住，只显示进度", () => {
    expect(code).toContain('const relocLock = $derived(status?.relocating === true);');
    expect(code).toContain('<div class="shell" inert={relocLock}>');
    const go = code.slice(code.indexOf("function go(id) {"));
    expect(go.slice(0, go.indexOf("}"))).toContain("if (relocLock) return;");
    const lock = code.slice(code.indexOf('data-testid="relocate-lock"'));
    const block = lock.slice(0, lock.indexOf("{/if}\n{/if}"));
    expect(block).toContain('t("ui.blocked_relocating")');
    expect(block).toContain('"ui.relocating_progress"');
    expect(block).not.toMatch(/<Button|onclick=/);
  });

  it("照片库卡片本体仍在：路径展示 + 打开照片库", () => {
    expect(code).toContain("status?.library_dir");
    expect(code).toContain('t("ui.open_library")');
  });

  // 旧文案说「已备份的照片不会迁移、手机要重新扫码」——与整库搬迁正好相反，不许再出现。
  it.each(["zh", "en"])("%s：说明不再说重新扫码 / 重新备份", (lang) => {
    setLocale(lang);
    for (const key of ["ui.change_body", "ui.change_saved", "ui.library_change_hint"]) {
      expect(t(key, { dir: "/x" })).not.toMatch(/都要重新扫|需重新扫码确认|请让每台手机重新扫码|不会迁移|starts empty|must scan|pair each phone again/);
    }
  });
});
