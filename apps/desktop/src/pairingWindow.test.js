// #1122：二维码关闭 = 配对窗口关闭；#1117：设备列表参数是 include_departed。
// 壳与后台之间经具名命令转发（#1120），参数名在 JS、Rust 命令、后台三处必须一致。
import { test, expect } from "vitest";
import { readFileSync } from "node:fs";
import { DAEMON_COMMANDS } from "./lib/daemonApi.js";

const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8");
const api = readFileSync(new URL("../src-tauri/src/daemon_api.rs", import.meta.url), "utf8");

function body(src, name) {
  const at = src.indexOf(`function ${name}(`);
  expect(at, name).toBeGreaterThan(-1);
  return src.slice(at, src.indexOf("\n  }", at));
}

// 反证：closePairModal 不调 pairing.stop，第一条变红。
test("关掉二维码弹窗就关闭配对窗口", () => {
  expect(body(app, "closePairModal")).toContain('call("pairing.stop")');
  expect(DAEMON_COMMANDS["pairing.stop"]).toBe("daemon_pairing_stop");
  expect(api).toContain('forward(app, "pairing.stop"');
});

// 反证：Rust 命令仍收 include_revoked，第二条变红（壳里设备列表会拿不到已离开的设备）。
test("设备列表参数名三处一致：include_departed", () => {
  expect(app).toContain('call("devices.list", { include_departed: true })');
  expect(api).toMatch(/fn daemon_devices_list(?:<[^>]*>)?\([\s\S]*?include_departed: bool[\s\S]*?"include_departed": include_departed/);
  expect(api).not.toContain("include_revoked");
});

// #1122 / #1150：诊断包由用户选择保存位置——保存对话框由壳弹，网页不再能给路径；
// 取消得到 null、什么都不做。反证：退回网页弹框并传 `out`，这条变红。
test("导出诊断包的保存位置由壳的系统对话框给，网页不传路径", () => {
  const body = app.slice(app.indexOf("async function exportLogs()"), app.indexOf("async function onHiddenToTray()"));
  expect(body).not.toContain("saveDialog");
  expect(body).toContain('invoke("export_logs_bundle")');
  expect(body).toMatch(/if \(!r\) return;/);
  const lib = readFileSync(new URL("../src-tauri/src/lib.rs", import.meta.url), "utf8");
  expect(lib).toMatch(/async fn export_logs_bundle\(\s*app: tauri::AppHandle,\s*title: Option<String>,?\s*\)/);
  expect(lib).toContain("blocking_save_file()");
  expect(lib).not.toContain('library.join("ppf-logs.zip")');
});

// 导出、换壳重启在壳里已是 async（不卡窗口），等待期间必须防重入。
// 反证：去掉 exportingLogs 守卫，或把 relaunching 挪回 invoke 之后 → 红。
test("导出诊断包与重启 App 等待期间不重入", () => {
  const exp = app.slice(app.indexOf("async function exportLogs()"), app.indexOf("async function onHiddenToTray()"));
  expect(exp).toMatch(/if \(exportingLogs\) return;\s*exportingLogs = true;/);
  expect(exp).toMatch(/finally \{\s*exportingLogs = false;/);
  const rel = app.slice(app.indexOf("async function relaunchShellNow()"));
  expect(rel.indexOf('updatePhase = "relaunching"')).toBeLessThan(rel.indexOf('invoke("relaunch_shell")'));
});
