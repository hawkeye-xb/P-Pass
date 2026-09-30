// #550：诊断包入口从设置页收进托盘菜单。
//
// 托盘点击在 CI 里没法模拟，这里钉住前端这半边的接线：
// - 订阅了 Rust 发来的 `export-logs-requested`，收到后走的仍是原来那条
//   exportLogs（同一个 export_logs_bundle、同一套成功/失败 toast）；
// - 设置页不再有导出入口，被删的两个字典 key 前端也不再引用。
// Rust 那半边（托盘项存在、事件名与这里一致）由 src-tauri 的
// `tray_export_logs_item_is_wired_to_the_frontend` 覆盖。
//
// 反证：删掉 onMount 里的 listen，或把设置页那一行加回来，对应断言必须红。
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";

const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8").replace(
  /\r\n/g,
  "\n",
);

describe("#550 托盘导出诊断包", () => {
  it("订阅托盘事件，收到后调原来的 exportLogs，卸载时退订", () => {
    expect(app).toContain('listen("export-logs-requested", exportLogs)');
    expect(app).toContain("unlistenExportLogs?.();");
  });

  it("exportLogs 仍调 export_logs_bundle，成功与失败都有提示", () => {
    const body = app.match(/async function exportLogs\(\) \{[\s\S]*?\n  \}\n/)?.[0] ?? "";
    expect(body).toContain('invoke("export_logs_bundle")');
    expect(body).toContain('t("ui.logs_exported"');
    expect(body).toContain('t("ui.export_failed"');
  });

  it("设置页不再有导出入口", () => {
    expect(app).not.toContain("ui.export_logs_prompt");
    expect(app).not.toContain('t("ui.export_logs")');
    expect(app).not.toContain("onclick={exportLogs}");
  });
});
