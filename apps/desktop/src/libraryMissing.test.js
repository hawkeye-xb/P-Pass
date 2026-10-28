// #1253：照片库找不到时 daemon 不再退出，`status` 报 `library_missing` + `library_dir`。
// 窗口要说明原因与路径（不说「服务没运行」，也不进首启向导），文案不提 config.toml。
// 行为在 daemon 侧有单测（crates/daemon/src/main.rs、ipc.rs）；这里钉文案与接线。
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { setLocale, t } from "./lib/i18n.js";

const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8");

describe("#1253 库找不到", () => {
  it.each(["zh", "en"])("%s：说明带路径，不提 config.toml", (lang) => {
    setLocale(lang);
    const body = t("ui.library_missing_body", { dir: "/Volumes/My Passport/P-Pass Library" });
    expect(body).toContain("/Volumes/My Passport/P-Pass Library");
    expect(body).not.toMatch(/config\.toml/);
    expect(t("ui.library_missing_title")).not.toBe("ui.library_missing_title");
  });

  // 接线：服务在线时先看 library_missing，排在正常主页内容之前。
  // 反证：删掉 `{:else if status?.library_missing}` 分支，这条变红。
  it("主页在服务在线时先判 library_missing", () => {
    const branch = app.indexOf("{:else if status?.library_missing}");
    expect(branch).toBeGreaterThan(app.indexOf("{#if !isServiceRunning(serviceState)}"));
    expect(branch).toBeLessThan(app.indexOf("{#if pendingCount > 0 && !showConfirmModal}"));
    expect(app).toContain('t("ui.library_missing_body", { dir: status.library_dir })');
  });
});
