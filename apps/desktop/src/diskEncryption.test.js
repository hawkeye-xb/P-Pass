// W-4：磁盘加密提示的接线。判定在 platform（bitlocker_verdict / filevault_verdict，
// 单测在那边）；界面只在 status.disk_encryption === "off" 时显示一行现状。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
const lf = (s) => s.replace(/\r\n/g, "\n");
const app = lf(readFileSync(new URL("./App.svelte", import.meta.url), "utf8"));
const zh = JSON.parse(readFileSync(new URL("../../../assets/i18n/zh.json", import.meta.url), "utf8"));
const en = JSON.parse(readFileSync(new URL("../../../assets/i18n/en.json", import.meta.url), "utf8"));

describe("W-4 磁盘加密提示", () => {
  it("只有确认未开启（off）才显示；unknown / on 不提示", () => {
    expect(app).toContain('{#if status?.disk_encryption === "off"}');
    expect(app).not.toMatch(/disk_encryption === "unknown"/);
  });

  it("文案走 i18n，中英都有", () => {
    for (const k of ["ui.disk_encryption", "ui.disk_encryption_off"]) {
      expect(app).toContain(`t("${k}")`);
      expect(zh[k]).toBeTruthy();
      expect(en[k]).toBeTruthy();
    }
  });
});
