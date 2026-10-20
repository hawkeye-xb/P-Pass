// #1044 B11：低空间判定（阈值 5 GiB、回差 6 GiB、布防状态）已挪进 daemon
// 并持久化（crates/daemon/src/low_space.rs，规则测试在那边）。桌面只负责
// 把 status 带出的待展示通知弹出来、再 ack 掉。
import { describe, expect, it } from "vitest";

// 接线：规则再对，没接上也等于没有。反证：删掉 refresh 里的
// showLowSpaceNotice 调用、或壳里没注册 notify_system，下面会挂。
import { readFileSync } from "node:fs";
const lf = (s) => s.replace(/\r\n/g, "\n");
const app = lf(readFileSync(new URL("./App.svelte", import.meta.url), "utf8"));
const shell = lf(readFileSync(new URL("../src-tauri/src/lib.rs", import.meta.url), "utf8"));

describe("#413 §7 低空间通知接线", () => {
  it("每次 status 刷新都把 daemon 给的待展示通知交出去，弹完就 ack", () => {
    expect(app).toMatch(
      /status = await call\("status", \{ shell_version: version \}\);\s*\n\s*void showLowSpaceNotice\(status\.low_space_notice\);/,
    );
    expect(app).toContain('await call("low_space.ack")');
  });

  it("桌面不再自己判阈值", () => {
    expect(app).not.toMatch(/nextLowSpace|LOW_SPACE_|lowSpaceArmed/);
  });

  it("通知走壳的 notify_system，文案走 i18n 字典", () => {
    expect(app).toContain('invoke("notify_system", {');
    expect(app).toContain('t("ui.low_space_title")');
    expect(app).toContain('t("ui.low_space_body", { free: formatBytes(notice.free_bytes ?? null) })');
    expect(shell).toMatch(/fn notify_system\(title: String, body: String\)/);
    expect(shell).toMatch(/generate_handler!\[[\s\S]*notify_system[\s\S]*\]/);
  });
});
