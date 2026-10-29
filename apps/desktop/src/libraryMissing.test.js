// #1253：照片库找不到时 daemon 不再退出，`status` 报 `library_missing` + `library_dir`。
// 窗口要说明原因与路径（不说「服务没运行」，也不进首启向导），文案不提 config.toml。
// 行为在 daemon 侧有单测（crates/daemon/src/main.rs、ipc.rs）；这里钉文案与接线。
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { setLocale, t } from "./lib/i18n.js";
import { createLibraryAlert, recheckLibrary } from "./lib/libraryMissing.js";

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

  // 强提示只在状态变化时发：每次 refresh 都 sync，不能每 3 秒把窗口拽到前台一次。
  // 反证：去掉 `next === active` 判断 → 调用 4 次，红。
  it("窗口置前 / 程序坞跳动只在进入与离开时各发一次", () => {
    const invoke = vi.fn(() => Promise.resolve());
    const alert = createLibraryAlert(invoke, () => "zh");
    alert.sync(undefined);
    alert.sync(true);
    alert.sync(true);
    alert.sync(true);
    alert.sync(false);
    alert.sync(undefined);
    expect(invoke.mock.calls).toEqual([
      ["set_library_alert", { active: true, lang: "zh" }],
      ["set_library_alert", { active: false, lang: "zh" }],
    ]);
  });

  it("重新检查：库回来了是 restarting，还不在如实说 still_missing", async () => {
    const call = vi.fn();
    call.mockResolvedValueOnce({ found: true });
    expect(await recheckLibrary(call)).toBe("restarting");
    call.mockResolvedValueOnce({ found: false });
    expect(await recheckLibrary(call)).toBe("still_missing");
    expect(call).toHaveBeenCalledWith("library.recheck", {});
  });

  it.each(["zh", "en"])("%s：按钮、仍找不到、系统通知都有文案，正文不再说「自动恢复」", (lang) => {
    setLocale(lang);
    for (const key of [
      "ui.library_missing_recheck",
      "ui.library_missing_still",
      "ui.library_missing_notice_title",
      "ui.library_missing_notice_body",
    ]) {
      expect(t(key)).not.toBe(key);
    }
    expect(t("ui.library_missing_body", { dir: "/x" })).not.toMatch(/自动恢复|automatically/);
  });

  // 接线：卡片上有「重新检查」，refresh 每次把 library_missing 交给强提示。
  it("卡片有重新检查按钮，refresh 同步强提示", () => {
    expect(app).toContain('data-testid="library-recheck"');
    expect(app).toContain("libraryAlert.sync(status.library_missing);");
  });

  // 10-29 定稿：「仍然找不到」改为 toast，阻断卡片不变、卡片里不再常驻这一行。
  // 反证：恢复卡片里的 `{#if libraryStillMissing}` 那行 → 红。
  it("重新检查仍找不到：走 toast，不在卡片里常驻", () => {
    expect(app).toContain('flashMessage(t("ui.library_missing_still"), "warning")');
    const card = app.slice(app.indexOf('data-testid="library-missing"'), app.indexOf("{:else}", app.indexOf('data-testid="library-missing"')));
    expect(card).not.toContain("ui.library_missing_still");
  });
});
