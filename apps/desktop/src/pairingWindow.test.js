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
  expect(api).toContain('forward(&app, "pairing.stop"');
});

// 反证：Rust 命令仍收 include_revoked，第二条变红（壳里设备列表会拿不到已离开的设备）。
test("设备列表参数名三处一致：include_departed", () => {
  expect(app).toContain('call("devices.list", { include_departed: true })');
  expect(api).toMatch(/fn daemon_devices_list\([\s\S]*?include_departed: bool[\s\S]*?"include_departed": include_departed/);
  expect(api).not.toContain("include_revoked");
});
